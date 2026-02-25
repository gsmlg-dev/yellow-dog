defmodule YellowDog.Resolved.ListenerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Listener}

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  @config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 200,
    upstream_failure_threshold: 3,
    intercept_rules: [
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
    ],
    cache: @cache_config,
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    config_path: ""
  }

  describe "listener_spec/1" do
    test "returns a valid child spec map" do
      spec = Listener.listener_spec(@config)

      assert spec.id == Listener
      assert spec.type == :supervisor
      assert {Abyss, :start_link, [opts]} = spec.start
      assert Keyword.get(opts, :handler_module) == Listener
      assert Keyword.get(opts, :port) == 0
      assert Keyword.get(opts, :transport_options) == [ip: {127, 0, 0, 1}]
    end

    test "uses Broadcast transport module" do
      spec = Listener.listener_spec(@config)
      {_, _, [opts]} = spec.start

      assert Keyword.get(opts, :num_listeners) == 1
      assert Keyword.get(opts, :transport_module) == Abyss.Transport.UDP.Broadcast
    end

    test "uses configured listen IP and port" do
      config = %{@config | listen: {0, 0, 0, 0}, port: 5353}
      spec = Listener.listener_spec(config)
      {_, _, [opts]} = spec.start

      assert Keyword.get(opts, :transport_options) == [ip: {0, 0, 0, 0}]
      assert Keyword.get(opts, :port) == 5353
    end
  end

  describe "handle_data/2 with intercepted query" do
    setup do
      start_supervised!({Config, @config})
      start_supervised!({Cache, @cache_config})

      # Open a UDP socket to receive responses from the listener
      {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(recv_socket) end)

      # Open a "server" socket that the listener will use to send responses
      {:ok, send_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(send_socket) end)

      {:ok, recv_port} = :inet.port(recv_socket)

      state = %{socket: send_socket}

      {:ok, state: state, recv_socket: recv_socket, recv_port: recv_port}
    end

    test "responds to valid intercepted DNS query", ctx do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, raw}, ctx.state)

      assert {:continue, _state} = result

      # Read the response from the receive socket
      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      # Parse the response and verify it's a valid DNS response
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == query.header.id
    end

    test "responds with FORMERR for malformed data", ctx do
      # Send garbage that is at least 12 bytes but not valid DNS
      garbage = <<42::16, 0::80, 0xFF, 0xFF, 0xFF, 0xFF>>

      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, garbage}, ctx.state)

      assert {:continue, _state} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      # FORMERR rcode
      assert response.header.rcode == DNS.Message.RCode.form_err()
    end

    test "responds with FORMERR for short packet (4 bytes)", ctx do
      # Less than 12 bytes — too short for DNS header but has txn_id
      short = <<1, 2, 3, 4>>

      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, short}, ctx.state)

      assert {:continue, _state} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      # txn_id extracted from first 2 bytes: <<1, 2>> = 0x0102 = 258
      assert response.header.id == 258
    end

    test "responds with FORMERR for 1-byte packet", ctx do
      # Only 1 byte — can't extract txn_id, falls through to catch-all
      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, <<0xAB>>}, ctx.state)

      assert {:continue, _state} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      # txn_id defaults to 0 for sub-2-byte packets
      assert response.header.id == 0
    end

    test "responds with FORMERR for empty packet", ctx do
      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, <<>>}, ctx.state)

      assert {:continue, _state} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == 0
    end

    test "responds with FORMERR for exactly 2-byte packet", ctx do
      # Exactly 2 bytes — can extract txn_id but not a valid DNS header
      client_ip = {127, 0, 0, 1}
      result = Listener.handle_data({client_ip, ctx.recv_port, <<0x12, 0x34>>}, ctx.state)

      assert {:continue, _state} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == 0x1234
    end

    test "preserves transaction ID in response", ctx do
      query = build_query("app.local.dev", 1)
      query = DNS.Message.update_header_attr(query, :id, 12345)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      <<txn_id::16, _rest::binary>> = response_binary
      assert txn_id == 12345
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
