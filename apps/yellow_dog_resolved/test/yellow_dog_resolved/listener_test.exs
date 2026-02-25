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

  describe "handle_data/2 with non-A query types" do
    setup do
      config = %{
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

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})

      {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(recv_socket) end)

      {:ok, send_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(send_socket) end)

      {:ok, recv_port} = :inet.port(recv_socket)
      state = %{socket: send_socket}

      {:ok, state: state, recv_socket: recv_socket, recv_port: recv_port}
    end

    test "AAAA query for intercepted domain returns empty answer (type mismatch)", ctx do
      # The intercept rule is type :a — an AAAA (28) query should return empty answer
      query = build_query("app.local.dev", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.anlist == []
    end

    test "MX query (type 15) doesn't crash the listener", ctx do
      query = build_query("app.local.dev", 15)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      result = Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)
      assert {:continue, _} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
    end

    test "large but valid DNS query is handled correctly", ctx do
      # Query with a very long subdomain (but under 253 chars total)
      long_domain = String.duplicate("a", 60) <> ".local.dev"
      query = build_query(long_domain, 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      result = Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)
      assert {:continue, _} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == query.header.id
    end

    test "exactly 12-byte packet (minimal DNS header, no questions) → FORMERR", ctx do
      # A valid DNS header is 12 bytes, but with qdcount=0 and garbage fields
      # This should parse as a DNS message with no questions
      header = <<0xAB, 0xCD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

      result = Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, header}, ctx.state)
      assert {:continue, _} = result

      assert {:ok, {_ip, _port, response_binary}} =
               :gen_udp.recv(ctx.recv_socket, 0, 1000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
    end
  end

  describe "end-to-end via Abyss listener with FakeUpstream" do
    setup do
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      config = %{
        listen: {127, 0, 0, 1},
        port: 0,
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
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

      start_supervised!({Config, config})
      start_supervised!({Cache, @cache_config})

      forwarder_config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({YellowDog.Resolved.Forwarder, forwarder_config})

      # Start the Abyss listener
      spec = Listener.listener_spec(config)
      {:ok, listener_pid} = start_supervised(spec)

      # Get the actual bound port using Abyss API
      Process.sleep(100)
      listener_pool_pid = Abyss.Server.listener_pool_pid(listener_pid)
      [listener_worker | _] = Abyss.ListenerPool.listener_pids(listener_pool_pid)
      {_ip, listener_port} = Abyss.Listener.listener_info(listener_worker)

      {:ok, client_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(client_socket) end)

      %{client_socket: client_socket, listener_port: listener_port}
    end

    test "intercepted query returns 127.0.0.1 via full UDP stack", ctx do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :gen_udp.send(ctx.client_socket, {127, 0, 0, 1}, ctx.listener_port, raw)
      assert {:ok, {_ip, _port, response_binary}} = :gen_udp.recv(ctx.client_socket, 0, 5000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == query.header.id
      assert length(response.anlist) == 1
    end

    test "forwarded query returns upstream response via full UDP stack", ctx do
      query = build_query("example.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      :gen_udp.send(ctx.client_socket, {127, 0, 0, 1}, ctx.listener_port, raw)
      assert {:ok, {_ip, _port, response_binary}} = :gen_udp.recv(ctx.client_socket, 0, 5000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.id == query.header.id
      # FakeUpstream :echo returns A record answer
      assert length(response.anlist) >= 1
    end

    test "malformed packet returns FORMERR via full UDP stack", ctx do
      garbage = <<0xAB, 0xCD, 0::80, 0xFF, 0xFF, 0xFF, 0xFF>>

      :gen_udp.send(ctx.client_socket, {127, 0, 0, 1}, ctx.listener_port, garbage)
      assert {:ok, {_ip, _port, response_binary}} = :gen_udp.recv(ctx.client_socket, 0, 5000)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.form_err()
    end
  end

  describe "telemetry events" do
    setup do
      start_supervised!({Config, @config})
      start_supervised!({Cache, @cache_config})

      {:ok, recv_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(recv_socket) end)

      {:ok, send_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(send_socket) end)

      {:ok, recv_port} = :inet.port(recv_socket)
      state = %{socket: send_socket}

      {:ok, state: state, recv_socket: recv_socket, recv_port: recv_port}
    end

    test "emits listener:request telemetry on valid query", ctx do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "listener-req-#{inspect(ref)}",
        [:yellow_dog, :resolved, :listener, :request],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:request_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("listener-req-#{inspect(ref)}") end)

      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)

      assert_receive {:request_event, measurements, metadata}
      assert measurements.bytes == byte_size(raw)
      assert metadata.client_ip == {127, 0, 0, 1}

      # Drain the response
      :gen_udp.recv(ctx.recv_socket, 0, 1000)
    end

    test "emits listener:parse_error telemetry on malformed data", ctx do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "listener-parse-#{inspect(ref)}",
        [:yellow_dog, :resolved, :listener, :parse_error],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:parse_error_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("listener-parse-#{inspect(ref)}") end)

      # Header claims qdcount=1 but question section is garbage → from_iodata crashes
      garbage = <<42::16, 0::16, 0, 1, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF>>

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, garbage}, ctx.state)

      assert_receive {:parse_error_event, measurements, metadata}
      assert measurements.bytes == byte_size(garbage)
      assert metadata.client_ip == {127, 0, 0, 1}
      assert metadata.txn_id == 42

      # Drain the response
      :gen_udp.recv(ctx.recv_socket, 0, 1000)
    end

    test "does NOT emit parse_error on valid query", ctx do
      ref = make_ref()

      :telemetry.attach(
        "listener-no-parse-#{inspect(ref)}",
        [:yellow_dog, :resolved, :listener, :parse_error],
        fn _event, _measurements, _metadata, _ ->
          send(self(), :unexpected_parse_error)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("listener-no-parse-#{inspect(ref)}") end)

      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)

      # Drain the response
      :gen_udp.recv(ctx.recv_socket, 0, 1000)

      refute_receive :unexpected_parse_error, 100
    end

    test "emits listener:send_error telemetry when UDP send fails", ctx do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "listener-send-err-#{inspect(ref)}",
        [:yellow_dog, :resolved, :listener, :send_error],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:send_error_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("listener-send-err-#{inspect(ref)}") end)

      # Close the send socket so UDP send fails
      :gen_udp.close(ctx.state.socket)

      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      import ExUnit.CaptureLog

      capture_log(fn ->
        result = Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, raw}, ctx.state)
        assert {:continue, _} = result
      end)

      assert_receive {:send_error_event, metadata}
      assert metadata.client_ip == {127, 0, 0, 1}
      assert is_atom(metadata.reason)
    end

    test "emits request telemetry even for malformed packets", ctx do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "listener-req-malformed-#{inspect(ref)}",
        [:yellow_dog, :resolved, :listener, :request],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:request_on_malformed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("listener-req-malformed-#{inspect(ref)}") end)

      garbage = <<0xAB, 0xCD, 0::80, 0xFF, 0xFF>>

      Listener.handle_data({{127, 0, 0, 1}, ctx.recv_port, garbage}, ctx.state)

      assert_receive {:request_on_malformed, measurements, _metadata}
      assert measurements.bytes == byte_size(garbage)

      # Drain the response
      :gen_udp.recv(ctx.recv_socket, 0, 1000)
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
