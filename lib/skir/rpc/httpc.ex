defmodule Skir.RPC.HTTPClient.Httpc do
  @moduledoc false
  @behaviour Skir.RPC.HTTPClient

  @max_header_bytes 10_240
  @default_max_response_bytes 4_194_304

  @spec request(:get | :post, String.t(), [{String.t(), String.t()}], binary(), keyword()) ::
          {:ok, %{status: integer(), headers: [{String.t(), String.t()}], body: binary()}}
          | {:error, term()}
  def request(method, url, headers, body, opts) when method in [:get, :post] do
    limit = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "max_response_bytes must be a positive integer")

    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout
    connect_timeout = Keyword.get(opts, :connect_timeout, min(timeout, 10_000))
    do_request(method, URI.parse(url), headers, body, limit, connect_timeout, deadline, 5)
  rescue
    error -> {:error, error}
  catch
    :throw, reason -> {:error, reason}
    kind, value -> {:error, {kind, value}}
  end

  def request(method, _url, _headers, _body, _opts), do: {:error, {:unsupported_method, method}}

  defp do_request(method, uri, headers, body, limit, connect_timeout, deadline, redirects) do
    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
      do: raise(ArgumentError, "invalid HTTP URL")

    transport = if uri.scheme == "https", do: :ssl, else: :gen_tcp

    socket_opts = [
      :binary,
      active: false,
      packet: :http_bin,
      packet_size: @max_header_bytes,
      buffer: 16_384
    ]

    socket_opts =
      if String.contains?(uri.host, ":"), do: [:inet6 | socket_opts], else: socket_opts

    socket_opts =
      if transport == :ssl do
        {:ok, _} = Application.ensure_all_started(:ssl)
        socket_opts ++ ssl_options()
      else
        socket_opts
      end

    # :httpc streaming excludes error responses, and early OTP 27 has no
    # max_body_size option. Read bounded bodies with OTP's HTTP packet parser.
    result =
      with {:ok, socket} <-
             transport.connect(
               String.to_charlist(uri.host),
               uri.port,
               socket_opts,
               min(connect_timeout, remaining(deadline))
             ) do
        try do
          :ok =
            setopts(transport, socket,
              send_timeout: remaining(deadline),
              send_timeout_close: true
            )

          case transport.send(socket, request_data(method, uri, headers, body)) do
            :ok -> :ok
            {:error, reason} -> throw(reason)
          end

          {status, response_headers} = response_headers(transport, socket, deadline, 0)
          :ok = setopts(transport, socket, packet: :raw)

          response_body =
            response_body(transport, socket, status, response_headers, limit, deadline)

          {:ok, %{status: status, headers: response_headers, body: response_body}}
        after
          close(transport, socket)
        end
      end

    case result do
      {:ok, %{status: status, headers: response_headers}}
      when status in [301, 302, 303, 307, 308] ->
        location =
          Enum.find_value(response_headers, fn {key, value} -> if key == "location", do: value end)

        if location do
          if redirects == 0, do: throw(:too_many_redirects)
          next_uri = URI.merge(uri, String.trim(location))

          next_headers =
            if {uri.scheme, String.downcase(uri.host), uri.port} ==
                 {next_uri.scheme, String.downcase(next_uri.host || ""), next_uri.port} do
              headers
            else
              Enum.reject(headers, fn {key, _} ->
                String.downcase(key) in [
                  "authorization",
                  "proxy-authorization",
                  "cookie",
                  "origin",
                  "referer"
                ]
              end)
            end

          {next_method, next_body} =
            if method == :post and status in [301, 302, 303], do: {:get, ""}, else: {method, body}

          do_request(
            next_method,
            next_uri,
            next_headers,
            next_body,
            limit,
            connect_timeout,
            deadline,
            redirects - 1
          )
        else
          result
        end

      _ ->
        result
    end
  end

  defp request_data(method, uri, headers, body) do
    query =
      if uri.query do
        "?" <>
          URI.encode(
            uri.query,
            &(URI.char_unreserved?(&1) or Enum.member?(~c"!$&'()*+,;=:@/?%", &1))
          )
      else
        ""
      end

    path = if uri.path in [nil, ""], do: "/", else: uri.path

    target =
      URI.encode(path, &(URI.char_unreserved?(&1) or Enum.member?(~c"!$&'()*+,;=:@/%", &1))) <>
        query

    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host

    host =
      if uri.port == if(uri.scheme == "https", do: 443, else: 80),
        do: host,
        else: "#{host}:#{uri.port}"

    headers =
      Enum.reject(headers, fn {key, _} ->
        String.downcase(key) in [
          "host",
          "content-length",
          "transfer-encoding",
          "connection"
        ] or (method == :post and String.downcase(key) == "content-type")
      end)

    headers = [{"host", host}, {"connection", "close"} | headers]

    headers =
      if method == :post,
        do: [
          {"content-type", "text/plain; charset=utf-8"},
          {"content-length", Integer.to_string(byte_size(body))} | headers
        ],
        else: headers

    lines =
      Enum.map(headers, fn {key, value} ->
        if String.contains?(key <> value, ["\r", "\n"]),
          do: raise(ArgumentError, "invalid HTTP header")

        [key, ": ", value, "\r\n"]
      end)

    [
      if(method == :post, do: "POST", else: "GET"),
      " ",
      target,
      " HTTP/1.1\r\n",
      lines,
      "\r\n",
      body
    ]
  end

  defp response_headers(transport, socket, deadline, interim) when interim < 5 do
    case recv(transport, socket, 0, deadline) do
      {:http_response, _, status, _} ->
        headers = read_headers(transport, socket, deadline, [], 0)

        if status < 200,
          do: response_headers(transport, socket, deadline, interim + 1),
          else: {status, headers}

      _ ->
        throw(:invalid_http_response)
    end
  end

  defp response_headers(_, _, _, _), do: throw(:invalid_http_response)

  defp read_headers(transport, socket, deadline, headers, bytes) do
    case recv(transport, socket, 0, deadline) do
      :http_eoh ->
        Enum.reverse(headers)

      {:http_header, _, key, _, value} ->
        header = {String.downcase(to_string(key)), to_string(value)}
        bytes = bytes + byte_size(elem(header, 0)) + byte_size(elem(header, 1)) + 4
        if bytes > @max_header_bytes, do: throw(:headers_too_large)
        read_headers(transport, socket, deadline, [header | headers], bytes)

      _ ->
        throw(:invalid_http_response)
    end
  end

  defp response_body(_, _, status, _, _, _) when status in [204, 304], do: ""

  defp response_body(transport, socket, _, headers, limit, deadline) do
    cond do
      header(headers, "transfer-encoding") == "chunked" ->
        read_chunks(transport, socket, limit, deadline, "")

      header(headers, "transfer-encoding") not in [nil, "identity"] ->
        throw(:invalid_http_response)

      length = header(headers, "content-length") ->
        size = parse_size(length, 10)
        if size > limit, do: throw(:response_too_large)
        if size == 0, do: "", else: recv(transport, socket, size, deadline)

      true ->
        read_to_close(transport, socket, limit, deadline, "")
    end
  end

  defp read_chunks(transport, socket, limit, deadline, body) do
    :ok = setopts(transport, socket, packet: :line)
    line = recv(transport, socket, 0, deadline)
    size = line |> String.split(";", parts: 2) |> hd() |> String.trim() |> parse_size(16)
    if byte_size(body) + size > limit, do: throw(:response_too_large)

    if size == 0 do
      read_trailers(transport, socket, deadline, 0)
      body
    else
      :ok = setopts(transport, socket, packet: :raw)
      chunk = recv(transport, socket, size, deadline)
      unless recv(transport, socket, 2, deadline) == "\r\n", do: throw(:invalid_http_response)
      read_chunks(transport, socket, limit, deadline, <<body::binary, chunk::binary>>)
    end
  end

  defp read_trailers(transport, socket, deadline, bytes) do
    line = recv(transport, socket, 0, deadline)
    bytes = bytes + byte_size(line)
    if bytes > @max_header_bytes, do: throw(:headers_too_large)
    if line != "\r\n", do: read_trailers(transport, socket, deadline, bytes)
  end

  defp read_to_close(transport, socket, limit, deadline, body) do
    case transport.recv(socket, 0, remaining(deadline)) do
      {:ok, chunk} ->
        if byte_size(body) + byte_size(chunk) > limit, do: throw(:response_too_large)
        read_to_close(transport, socket, limit, deadline, <<body::binary, chunk::binary>>)

      {:error, :closed} ->
        body

      {:error, reason} ->
        throw(reason)
    end
  end

  defp parse_size(value, base) do
    value = String.trim(value)
    if byte_size(value) > 20, do: throw(:response_too_large)
    pattern = if base == 16, do: ~r/^[0-9a-fA-F]+$/, else: ~r/^[0-9]+$/
    unless Regex.match?(pattern, value), do: throw(:invalid_http_response)
    String.to_integer(value, base)
  end

  defp header(headers, key),
    do:
      headers
      |> Enum.find_value(fn {name, value} ->
        if name == key, do: value |> String.trim() |> String.downcase()
      end)

  defp recv(transport, socket, size, deadline) do
    case transport.recv(socket, size, remaining(deadline)) do
      {:ok, data} -> data
      {:error, reason} -> throw(reason)
    end
  end

  # Discard pending writes so cleanup cannot outlive the request deadline.
  # SSL close_notify can wait for pending writes even with a zero close timeout.
  defp close(:ssl, socket), do: spawn(fn -> :ssl.close(socket, 0) end)

  defp close(:gen_tcp, socket) do
    :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end

  defp setopts(:ssl, socket, opts), do: :ssl.setopts(socket, opts)
  defp setopts(:gen_tcp, socket, opts), do: :inet.setopts(socket, opts)
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    timeout = deadline - now()
    if timeout <= 0, do: throw(:timeout)
    timeout
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
