defmodule Skir.RPCResourceLimitsTest do
  use ExUnit.Case, async: true

  alias Skir.RPC.{RpcError, Service, ServiceClient}

  defp method(number \\ 1),
    do: %Skir.Method{name: "Echo", number: number, doc: "", request: :int64, response: :int64}

  test "compact and JSON method IDs reject huge numbers without reflecting them" do
    digits = String.duplicate("9", 100_000)

    for body <- ["Echo:" <> digits <> "::0", ~s({"method":#{digits},"request":0})] do
      response = Service.handle_request(Service.new(), body)
      assert response.status_code == 400
      assert byte_size(response.data) < 128
    end
  end

  test "JSON method IDs reject huge numbers without reflecting them" do
    body = ~s({"method":#{String.duplicate("9", 100_000)},"request":0})
    response = Service.handle_request(Service.new(), body)
    assert response.status_code == 400
    assert byte_size(response.data) < 128
  end

  test "both request forms enforce uint32 method IDs and retain boundary dispatch" do
    service =
      Enum.reduce([0, 0xFFFFFFFF], Service.new(), fn number, service ->
        Service.add_method(service, method(number), fn request, _ -> {:ok, request} end)
      end)

    for number <- [0, 0xFFFFFFFF] do
      for body <- ["Echo:#{number}::42", ~s({"method":#{number},"request":42})] do
        assert %{status_code: 200, data: "42"} = Service.handle_request(service, body)
      end
    end

    for number <- [-1, 0x100000000, 99_999_999_999] do
      for body <- ["Echo:#{number}::42", ~s({"method":#{number},"request":42})] do
        assert %{status_code: 400, data: data} = Service.handle_request(service, body)
        refute data =~ "method not found"
        assert byte_size(data) < 128
      end
    end
  end

  test "bounded JSON number parsing still supports int64 requests, escaped fields and nested values" do
    service = Service.add_method(Service.new(), method(), fn request, _ -> {:ok, request} end)

    for request <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807] do
      body = ~s({"method":1,"request":#{request}})
      assert %{status_code: 200} = Service.handle_request(service, body)
    end

    body = ~S({"meth\u006fd":1,"request":42,"unused":{"method":4294967296}})
    assert %{status_code: 200, data: "42"} = Service.handle_request(service, body)
    assert %{status_code: 400} = Service.handle_request(service, ~s({"method":1,"request":42}x))
  end

  test "large text/plain error bodies from custom transports are clipped without retaining the body" do
    body = String.duplicate("x", 8_388_608)

    transport = fn _, _, _, _, _ ->
      {:ok, %{status: 500, headers: [{"content-type", "text/plain"}], body: body}}
    end

    client = ServiceClient.new!("http://example.test/rpc", transport: transport)

    assert {:error, %RpcError{status_code: 500, message: message}} =
             ServiceClient.invoke(client, method(), 1)

    assert byte_size(message) < 2048
    assert message == "HTTP status 500: " <> String.duplicate("x", 1024) <> "... (truncated)"
    assert :binary.referenced_byte_size(message) < 2048
  end

  test "JSON envelopes retain finite float64 integer literals up to the largest decimal width" do
    float_method = %{method() | request: :float64, response: :float64}
    service = Service.add_method(Service.new(), float_method, fn request, _ -> {:ok, request} end)

    for digits <- ["1000000000000000000000", "-1" <> String.duplicate("0", 308)] do
      compact = Service.handle_request(service, "Echo:1::" <> digits)
      envelope = Service.handle_request(service, ~s({"method":1,"request":#{digits}}))
      assert compact.status_code == 200
      assert envelope.status_code == 200
      assert envelope.data == compact.data
    end

    digits = "-1" <> String.duplicate("0", 309)

    assert %{status_code: 400} =
             Service.handle_request(service, ~s({"method":1,"request":#{digits}}))
  end

  test "clipped text errors retain complete UTF-8 characters" do
    transport = fn _, _, _, _, _ ->
      {:ok,
       %{
         status: 500,
         headers: [{"content-type", "text/plain"}],
         body: String.duplicate("x", 1023) <> "☃" <> String.duplicate("x", 1024)
       }}
    end

    client = ServiceClient.new!("http://example.test/rpc", transport: transport)
    assert {:error, %RpcError{message: message}} = ServiceClient.invoke(client, method(), 1)
    assert String.valid?(message)
    assert message == "HTTP status 500: " <> String.duplicate("x", 1023) <> "... (truncated)"
  end
end
