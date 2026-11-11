defmodule YellowDog.Resolved.ManagementTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters, RateLimiter}
  alias YellowDog.Resolved.Management.{Client, Handler}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [{8, 8, 8, 8}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 1000,
      min_ttl_s: 5,
      max_ttl_s: 3600,
      negative_ttl_s: 30,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: []
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
    start_supervised!({RateLimiter, @test_config})
    :ok
  end

  describe "handle_command/1" do
    test "cache_flush with null pattern flushes all" do
      Cache.store("test.com", :a, %{data: "test"}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-001",
          "data" => %{"pattern" => nil}
        })

      assert result["type"] == "cache_flush_result"
      assert result["id"] == "req-001"
      assert result["data"]["flushed"] >= 1
    end

    test "cache_flush with domain pattern" do
      Cache.store("sub.example.com", :a, %{}, 300)
      Cache.store("other.com", :a, %{}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-002",
          "data" => %{"pattern" => "*.example.com"}
        })

      assert result["type"] == "cache_flush_result"
      assert result["data"]["flushed"] >= 1
    end

    test "cache_stats returns statistics" do
      Cache.store("test.com", :a, %{}, 300)
      Process.sleep(10)
      Cache.lookup("test.com", :a)
      Cache.lookup("miss.com", :a)

      result =
        Handler.handle_command(%{
          "type" => "cache_stats",
          "id" => "req-003",
          "data" => %{}
        })

      assert result["type"] == "cache_stats_result"
      assert result["id"] == "req-003"
      assert is_integer(result["data"]["entries"])
      assert is_integer(result["data"]["hits"])
      assert is_integer(result["data"]["misses"])
    end

    test "ping returns pong with stats" do
      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-004",
          "data" => %{"server_time" => 1_706_000_000}
        })

      assert result["type"] == "pong"
      assert result["id"] == "req-004"
      assert is_integer(result["data"]["uptime_s"])
      assert result["data"]["uptime_s"] >= 0
      assert is_integer(result["data"]["queries_total"])
      assert is_integer(result["data"]["queries_intercepted"])
      assert is_integer(result["data"]["queries_cached"])
      assert is_integer(result["data"]["queries_forwarded"])
      assert is_integer(result["data"]["queries_error"])
      assert is_integer(result["data"]["queries_rate_limited"])
    end

    test "ping works without data field" do
      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-no-data"
        })

      assert result["type"] == "pong"
      assert result["id"] == "req-no-data"
      assert is_integer(result["data"]["queries_total"])
    end

    test "uptime_s is bounded by BEAM wall-clock age" do
      # The resolver started after (or at the same time as) the BEAM, so its
      # uptime must be <= the BEAM's own wall_clock total.
      {beam_uptime_ms, _} = :erlang.statistics(:wall_clock)
      beam_uptime_s = div(beam_uptime_ms, 1000)

      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-uptime",
          "data" => %{}
        })

      assert result["data"]["uptime_s"] <= beam_uptime_s
    end

    test "ping queries_total equals sum of routing counters" do
      Counters.reset()

      Counters.increment(:intercepted)
      Counters.increment(:intercepted)
      Counters.increment(:cached)

      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-005",
          "data" => %{"server_time" => 1_706_000_000}
        })

      data = result["data"]

      assert data["queries_total"] ==
               data["queries_intercepted"] + data["queries_cached"] + data["queries_forwarded"] +
                 data["queries_error"] + data["queries_rate_limited"]

      assert data["queries_intercepted"] == 2
      assert data["queries_cached"] == 1
      assert data["queries_forwarded"] == 0
      assert data["queries_error"] == 0
      assert data["queries_rate_limited"] == 0
      assert data["queries_total"] == 3
    end

    test "ping queries_total includes rate_limited queries" do
      Counters.reset()

      Counters.increment(:intercepted)
      Counters.increment(:rate_limited)
      Counters.increment(:rate_limited)

      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "req-rate-total",
          "data" => %{}
        })

      data = result["data"]
      assert data["queries_total"] == 3
      assert data["queries_rate_limited"] == 2
      assert data["queries_intercepted"] == 1
    end

    test "cache_flush with exact domain pattern" do
      Cache.store("target.example.com", :a, %{}, 300)
      Cache.store("keep.example.com", :a, %{}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-006",
          "data" => %{"pattern" => "target.example.com"}
        })

      assert result["type"] == "cache_flush_result"
      assert result["data"]["flushed"] >= 1

      # Only the targeted domain should be flushed
      assert :miss = Cache.lookup("target.example.com", :a)
      assert {:hit, _, _} = Cache.lookup("keep.example.com", :a)
    end

    test "cache_flush telemetry is emitted" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :management, :command]
        ])

      Handler.handle_command(%{
        "type" => "cache_flush",
        "id" => "req-007",
        "data" => %{"pattern" => nil}
      })

      assert_received {[:yellow_dog, :resolved, :management, :command], ^ref, %{},
                       %{type: :cache_flush}}
    end

    test "cache_flush without data field flushes all (no pattern)" do
      Cache.store("test.com", :a, %{data: "test"}, 300)
      Process.sleep(10)

      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-no-data-flush"
        })

      assert result["type"] == "cache_flush_result"
      assert result["id"] == "req-no-data-flush"
      assert is_integer(result["data"]["flushed"])
    end

    test "cache_flush with null data field does not crash" do
      # JSON clients may send {"data": null} instead of {"data": {}}
      result =
        Handler.handle_command(%{
          "type" => "cache_flush",
          "id" => "req-null-data",
          "data" => nil
        })

      assert result["type"] == "cache_flush_result"
      assert is_integer(result["data"]["flushed"])
    end

    test "unknown command returns nil" do
      assert nil == Handler.handle_command(%{"type" => "unknown"})
    end

    test "malformed command without type returns nil" do
      assert nil == Handler.handle_command(%{"no_type" => "bad"})
    end

    test "counters_reset resets counters and returns previous values" do
      Counters.reset()
      Counters.increment(:intercepted)
      Counters.increment(:forwarded)
      Counters.increment(:forwarded)

      result =
        Handler.handle_command(%{
          "type" => "counters_reset",
          "id" => "req-010"
        })

      assert result["type"] == "counters_reset_result"
      assert result["id"] == "req-010"
      assert result["data"]["previous_intercepted"] == 1
      assert result["data"]["previous_forwarded"] == 2
      assert result["data"]["previous_total"] == 3
      assert result["data"]["previous_error"] == 0
      assert result["data"]["previous_rate_limited"] == 0

      # Counters should now be zero
      assert Counters.get().total == 0
    end
  end

  describe "Client connection failure handling" do
    test "unreachable endpoint notifies parent with :management_down and stops" do
      parent = self()

      {:ok, pid} =
        GenServer.start_link(Client, %{
          endpoint: "ws://127.0.0.1:1/ws",
          instance_id: :crypto.strong_rand_bytes(16),
          parent: parent,
          ws_config: %{}
        })

      ref = Process.monitor(pid)

      # Connection to port 1 is immediately refused; the client must notify the
      # parent and stop with :normal rather than crashing.
      assert_receive {:management_down, _reason}, 2000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    test "partial upgrade, heartbeat control frames and server close use the WebSocket transport" do
      parent = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          request = receive_headers(socket, "")
          [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

          accept =
            :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

          :ok =
            :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n")

          send(parent, :partial_upgrade)

          receive do
            :finish_upgrade -> :ok
          after
            2_000 -> flunk("upgrade continuation was not requested")
          end

          :ok =
            :gen_tcp.send(
              socket,
              "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
            )

          {1, connected} = receive_frame(socket)
          send(parent, {:connected_message, Jason.decode!(connected)})
          {9, ""} = receive_frame(socket)
          :ok = :gen_tcp.send(socket, <<0x8A, 0, 0x89, 5, "probe">>)
          {10, "probe"} = receive_frame(socket)
          send(parent, :heartbeat_exchanged)

          receive do
            :close -> :ok
          after
            2_000 -> flunk("close was not requested")
          end

          :ok = :gen_tcp.send(socket, <<0x88, 2, 1000::16>>)
          assert {8, <<1000::16>>} = receive_frame(socket)
          :gen_tcp.close(socket)
        end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        if Process.alive?(server.pid), do: Process.exit(server.pid, :kill)
      end)

      {:ok, pid} =
        GenServer.start_link(Client, %{
          endpoint: "ws://127.0.0.1:#{port}/ws",
          instance_id: :crypto.strong_rand_bytes(16),
          parent: self(),
          ws_config: %{}
        })

      monitor = Process.monitor(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive :partial_upgrade, 2_000
      refute :sys.get_state(pid).connected
      send(server.pid, :finish_upgrade)
      assert_receive {:connected_message, %{"type" => "connected"}}, 2_000
      previous_pong = System.monotonic_time(:millisecond) - 1_000
      :sys.replace_state(pid, &%{&1 | last_pong_at: previous_pong})
      send(pid, :heartbeat)
      assert_receive :heartbeat_exchanged, 2_000
      assert :sys.get_state(pid).last_pong_at > previous_pong
      send(server.pid, :close)
      assert_receive {:management_down, {:ws_closed, {1000, ""}}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      Task.await(server, 2_000)
    end

    defp receive_headers(socket, bytes) do
      if String.contains?(bytes, "\r\n\r\n") do
        bytes
      else
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        receive_headers(socket, bytes <> chunk)
      end
    end

    defp receive_frame(socket) do
      {:ok, <<_fin::1, _rsv::3, opcode::4, 1::1, length::7>>} = :gen_tcp.recv(socket, 2, 2_000)

      length =
        if length == 126 do
          {:ok, <<size::16>>} = :gen_tcp.recv(socket, 2, 2_000)
          size
        else
          length
        end

      {:ok, mask} = :gen_tcp.recv(socket, 4, 2_000)
      payload = if length == 0, do: <<>>, else: elem(:gen_tcp.recv(socket, length, 2_000), 1)

      unmasked =
        for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)), into: <<>> do
          <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>
        end

      {opcode, unmasked}
    end
  end

  describe "heartbeat watchdog" do
    # Starts a TCP listener that accepts the connection but never speaks HTTP,
    # giving us a live GenServer in the pre-upgrade state with full state access.
    defp start_client_with_silent_tcp(parent) do
      {:ok, listen_sock} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen_sock)

      {:ok, server} =
        Task.start(fn ->
          {:ok, _sock} = :gen_tcp.accept(listen_sock, 5000)
          Process.sleep(:infinity)
        end)

      on_exit(fn ->
        :gen_tcp.close(listen_sock)
        if Process.alive?(server), do: Process.exit(server, :kill)
      end)

      {:ok, pid} =
        GenServer.start_link(Client, %{
          endpoint: "ws://127.0.0.1:#{port}/ws",
          instance_id: :crypto.strong_rand_bytes(16),
          parent: parent,
          ws_config: %{heartbeat_interval_s: 30}
        })

      # Give :connect time to fire and TCP handshake to complete.
      Process.sleep(50)
      {pid, listen_sock}
    end

    test "sends :management_down(:heartbeat_timeout) when pong is overdue" do
      {pid, listen_sock} = start_client_with_silent_tcp(self())
      ref = Process.monitor(pid)

      # Inject: connected=true, last_pong_at far in the past (beyond 2× heartbeat)
      :sys.replace_state(pid, fn state ->
        %{state | connected: true, last_pong_at: System.monotonic_time(:millisecond) - 100_000}
      end)

      send(pid, :heartbeat)

      assert_receive {:management_down, :heartbeat_timeout}, 1000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      :gen_tcp.close(listen_sock)
    end
  end

  describe "connected_event/1" do
    test "builds correct connected event structure" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.connected_event(instance_id)

      assert event["type"] == "connected"
      assert is_binary(event["id"])
      assert event["data"]["version"] == "0.1.0"
      assert is_binary(event["data"]["instance_id"])
      assert is_binary(event["data"]["hostname"])
      assert is_list(event["data"]["upstreams"])
      assert is_integer(event["data"]["intercept_rule_count"])
      assert is_integer(event["data"]["cache_max_entries"])
    end

    test "connected event instance_id is hex-encoded" do
      instance_id = :crypto.strong_rand_bytes(16)
      event = Handler.connected_event(instance_id)

      hex = event["data"]["instance_id"]
      assert String.length(hex) == 32
      # Should be valid hex
      assert {:ok, _} = Base.decode16(hex, case: :lower)
    end
  end
end
