defmodule YellowDog.Management.HTTPSProxyTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias YellowDog.Management.{Repo, Settings}
  alias YellowDog.ManagementUI.{Endpoint, TrustedProxy}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    names = ["YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN", "YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP"]
    previous_env = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    original_config =
      for {key, value} <- :ets.tab2list(Endpoint),
          is_atom(key),
          key != :__config__,
          do: {key, value}

    on_exit(fn ->
      Endpoint.config_change([{Endpoint, original_config}], [])

      Enum.each(previous_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    %{original_config: original_config}
  end

  test "forwarding trusts actual peer identity, not forwarded or rewritten client IP", context do
    configure_https(context)
    conn = proxy_conn("/management")
    rewritten = TrustedProxy.call(conn, [])
    assert rewritten.scheme == :https
    assert rewritten.port == 443
    assert rewritten.host == "management.example"
    assert rewritten.remote_ip == conn.remote_ip

    {adapter, payload} = conn.adapter
    peer_data = %{Plug.Conn.get_peer_data(conn) | address: {192, 0, 2, 5}}

    forged =
      %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer_data)}}
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> put_req_header("x-forwarded-host", "attacker.example")

    assert forged.remote_ip == {127, 0, 0, 1}
    unchanged = TrustedProxy.call(forged, [])
    assert unchanged.scheme == :http
    assert unchanged.port == 4270
    assert unchanged.host == "management.example"

    System.delete_env("YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP")
    configure_endpoint(context)
    assert TrustedProxy.call(conn, []).scheme == :http
  end

  test "configured HTTPS Origin upgrades and joins a real LiveView behind an HTTP proxy",
       context do
    configure_https(context)
    assert Endpoint.url() == "https://management.example"
    conn = Endpoint.call(proxy_conn("/management"), Endpoint.init([]))
    assert conn.status == 200
    assert conn.scheme == :https
    assert conn.port == 443

    {socket, status, document, csrf} = websocket(conn, "https://management.example")
    assert status =~ "101 Switching Protocols"
    topic = "lv:" <> attribute(document, "[data-phx-main]", "id")

    join = [
      "1",
      "1",
      topic,
      "phx_join",
      %{
        "url" => "https://management.example/management",
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0},
        "session" => attribute(document, "[data-phx-main]", "data-phx-session"),
        "static" => attribute(document, "[data-phx-main]", "data-phx-static")
      }
    ]

    send_frame(socket, Jason.encode!(join))
    assert ["1", "1", ^topic, "phx_reply", response] = receive_frame(socket)
    assert response["status"] == "ok"
    assert is_map(response["response"]["rendered"])
  end

  test "foreign host, scheme and port Origins remain rejected with trusted forwarding", context do
    configure_https(context)
    conn = Endpoint.call(proxy_conn("/management"), Endpoint.init([]))

    for origin <- [
          "https://attacker.example",
          "http://management.example",
          "https://management.example:8443"
        ] do
      {_socket, status, _document, _csrf} = websocket(conn, origin)
      assert status =~ "403 Forbidden"
    end
  end

  test "default loopback mode keeps connection matching and ignores forwarded scheme", context do
    configure_endpoint(context)
    assert Endpoint.config(:check_origin) == :conn
    conn = Endpoint.call(proxy_conn("/management"), Endpoint.init([]))
    assert conn.scheme == :http
    assert conn.port == 4270
    {_socket, status, _document, _csrf} = websocket(conn, "http://management.example:4270")
    assert status =~ "101 Switching Protocols"
    {_socket, status, _document, _csrf} = websocket(conn, "https://management.example")
    assert status =~ "403 Forbidden"
  end

  defp configure_https(context) do
    System.put_env("YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN", "https://management.example")
    System.put_env("YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP", "127.0.0.1")
    configure_endpoint(context)
  end

  defp configure_endpoint(context) do
    settings = Keyword.take(Settings.endpoint(), [:url, :check_origin, :trusted_proxy_ip])
    config = Keyword.merge(context.original_config, settings)
    Endpoint.config_change([{Endpoint, config}], [])
  end

  defp proxy_conn(path) do
    Plug.Test.conn(:get, "http://management.example:4270" <> path)
    |> put_private(:phoenix_endpoint, Endpoint)
    |> put_req_header("x-forwarded-proto", "https")
    |> put_req_header("x-forwarded-port", "443")
  end

  defp websocket(conn, origin) do
    document = LazyHTML.from_document(conn.resp_body)
    csrf = attribute(document, "meta[name='csrf-token']", "content")

    server =
      start_supervised!({Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: 0},
        id: make_ref()
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])

    on_exit(fn -> :gen_tcp.close(socket) end)
    cookie = conn.resp_cookies["_yellow_dog_management"].value
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET /live/websocket?vsn=2.0.0&_csrf_token=",
      URI.encode_www_form(csrf),
      " HTTP/1.1\r\nHost: management.example:4270\r\n",
      "Upgrade: websocket\r\nConnection: Upgrade\r\n",
      "Sec-WebSocket-Key: ",
      key,
      "\r\nSec-WebSocket-Version: 13\r\nOrigin: ",
      origin,
      "\r\nX-Forwarded-Proto: https\r\nX-Forwarded-Port: 443\r\n",
      "Cookie: _yellow_dog_management=",
      cookie,
      "\r\n\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, status} = :gen_tcp.recv(socket, 0, 5_000)
    read_headers(socket)
    :ok = :inet.setopts(socket, packet: :raw)
    {socket, status, document, csrf}
  end

  defp read_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _header} -> read_headers(socket)
      other -> flunk("WebSocket header read failed: #{inspect(other)}")
    end
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp send_frame(socket, payload) do
    length = byte_size(payload)
    header = if length < 126, do: <<0x81, 0x80 + length>>, else: <<0x81, 0xFE, length::16>>
    mask = :crypto.strong_rand_bytes(4)

    masked =
      for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
        <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>
      end

    :ok = :gen_tcp.send(socket, [header, mask, masked])
  end

  defp receive_frame(socket) do
    {:ok, <<0x81, length>>} = :gen_tcp.recv(socket, 2, 5_000)

    length =
      case length do
        126 ->
          {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2, 5_000)
          length

        127 ->
          {:ok, <<length::64>>} = :gen_tcp.recv(socket, 8, 5_000)
          length

        length ->
          length
      end

    {:ok, payload} = :gen_tcp.recv(socket, length, 5_000)
    Jason.decode!(payload)
  end
end
