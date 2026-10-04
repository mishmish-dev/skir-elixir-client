defmodule Skir.RPC.HTTPClient do
  @moduledoc """
  Transport behaviour used by `Skir.RPC.ServiceClient`.

  Implement this behaviour to use Finch, Req, Tesla, Mint, or another HTTP
  stack. The built-in adapter uses OTP `:httpc`.
  """

  @type header :: {String.t(), String.t()}
  @type response :: %{status: integer(), headers: [header()], body: binary()}

  @doc "Sends an HTTP request and returns the status, headers, and binary body, or a transport error."
  @callback request(:get | :post, String.t(), [header()], binary(), keyword()) ::
              {:ok, response()} | {:error, term()}
end
