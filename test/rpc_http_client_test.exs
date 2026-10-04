defmodule Skir.RPCHTTPClientTest do
  use ExUnit.Case, async: true

  alias Skir.RPC.HTTPClient.Httpc

  defp server(reply) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    pid =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 2000) do
          try do
            {:ok, request} = :gen_tcp.recv(socket, 0, 2000)
            send(parent, {:http_request, request})
            reply.(socket)
          after
            :gen_tcp.close(socket)
          end
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}/rpc"
  end

  defp request(url, opts \\ []),
    do: Httpc.request(:post, url, [], "Echo:1::0", Keyword.merge([timeout: 500], opts))

  test "response limits stop incomplete oversized success and error bodies while receiving" do
    for status <- [200, 500], framing <- [:length, :chunked, :close] do
      url =
        server(fn socket ->
          framing_header =
            case framing do
              :length -> "content-length: 9\r\n"
              :chunked -> "transfer-encoding: chunked\r\n"
              :close -> ""
            end

          prefix =
            case framing do
              :length -> ""
              :chunked -> "4\r\nxxxx\r\n5\r\n"
              :close -> "123456789"
            end

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} Result\r\ncontent-type: text/plain\r\n" <>
                framing_header <> "\r\n" <> prefix
            )

          :gen_tcp.recv(socket, 0, 1500)
        end)

      assert {:error, :response_too_large} = request(url, max_response_bytes: 8)
    end
  end

  test "content-length, chunked and connection-close bodies accept the exact limit" do
    for {framing, body} <- [
          {"content-length: 8\r\n", "12345678"},
          {"transfer-encoding: chunked\r\n",
           "4\r\n1234\r\n4\r\n5678\r\n0\r\nx-trailer: yes\r\n\r\n"},
          {"", "12345678"}
        ] do
      url =
        server(fn socket ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 500 Result\r\ncontent-type: text/plain\r\n" <> framing <> "\r\n" <> body
          )
        end)

      assert {:ok, %{status: 500, body: "12345678", headers: headers}} =
               request(url, max_response_bytes: 8)

      assert {"content-type", "text/plain"} in headers
    end
  end

  test "the default response limit covers HTTP errors" do
    url =
      server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 500 Result\r\ncontent-length: 4194305\r\n\r\n")
        :gen_tcp.recv(socket, 0, 1500)
      end)

    assert {:error, :response_too_large} = request(url)
  end

  test "GET requests preserve the current query escaping" do
    url =
      server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\n" <> ~s("ok"))
      end)

    assert {:ok, %{status: 200, body: ~s("ok")}} =
             Httpc.request(:get, url <> ~s(?Echo:1::"a%20b"), [], "", timeout: 500)

    assert_receive {:http_request, request}
    assert request =~ "GET /rpc?Echo:1::%22a%20b%22 HTTP/1.1"
  end

  test "invalid response-size options fail before connecting" do
    for limit <- [0, -1, nil, :infinity, "8"] do
      assert {:error, %ArgumentError{}} =
               request("http://127.0.0.1:1/rpc", max_response_bytes: limit)
    end
  end

  test "the request deadline bounds blocked sends" do
    url =
      server(fn socket ->
        :inet.setopts(socket, recbuf: 1024)

        receive do
          :finish -> :ok
        after
          1500 -> :ok
        end
      end)

    task =
      Task.async(fn ->
        Httpc.request(:post, url, [], String.duplicate("x", 4_194_000), timeout: 100)
      end)

    assert {:ok, {:error, :timeout}} = Task.yield(task, 600) || Task.shutdown(task, :brutal_kill)
  end

  test "the request deadline also bounds already buffered chunks" do
    url =
      server(fn socket ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 500 Result\r\ntransfer-encoding: chunked\r\n\r\n" <>
            String.duplicate("1\r\nx\r\n", 200_000) <> "0\r\n\r\n"
        )
      end)

    assert {:error, :timeout} = request(url, timeout: 20)
  end

  test "transfer-encoding accepts optional whitespace and mixed case" do
    url =
      server(fn socket ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nTransfer-Encoding:  Chunked \t\r\n\r\n1\r\n0\r\n0\r\n\r\n"
        )
      end)

    assert {:ok, %{body: "0"}} = request(url)
  end

  test "empty and interim responses preserve HTTP framing" do
    for response <- [
          "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n",
          "HTTP/1.1 204 No Content\r\n\r\n",
          "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        ] do
      url = server(fn socket -> :gen_tcp.send(socket, response) end)
      assert {:ok, %{body: ""}} = request(url)
    end
  end

  test "redirects retain POST for 307/308 and switch to GET for 301/302/303" do
    for status <- [301, 302, 303, 307, 308] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)
      parent = self()

      pid =
        spawn(fn ->
          for hop <- [1, 2] do
            with {:ok, socket} <- :gen_tcp.accept(listener, 1000) do
              {:ok, data} = :gen_tcp.recv(socket, 0, 1000)
              if hop == 2, do: send(parent, {:redirect_request, status, data})

              response =
                if hop == 1 do
                  "HTTP/1.1 #{status} Redirect\r\nLocation: /RPC/Target\r\nContent-Length: 0\r\n\r\n"
                else
                  "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n0"
                end

              :gen_tcp.send(socket, response)
              :gen_tcp.close(socket)
            end
          end
        end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      assert {:ok, %{status: 200, body: "0"}} = request("http://127.0.0.1:#{port}/rpc")
      assert_receive {:redirect_request, ^status, data}
      expected_method = if status in [307, 308], do: "POST", else: "GET"
      assert String.starts_with?(data, expected_method <> " /RPC/Target HTTP/1.1")
    end
  end
end
