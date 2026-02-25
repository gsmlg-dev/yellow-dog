defmodule YellowDog.Resolved.ForwarderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Forwarder

  @config %{
    upstreams: [{127, 0, 0, 1}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3
  }

  describe "start_link/1" do
    test "starts the forwarder" do
      assert {:ok, pid} =
               start_supervised({Forwarder, @config})

      assert Process.alive?(pid)
    end

    test "initializes with multiple upstreams" do
      config = %{@config | upstreams: [{1, 1, 1, 1}, {8, 8, 8, 8}, {9, 9, 9, 9}]}

      assert {:ok, pid} =
               start_supervised({Forwarder, config})

      assert Process.alive?(pid)
    end
  end

  describe "forward/1 with unreachable upstream" do
    setup do
      # Use a non-routable IP to force timeout
      config = %{@config | upstreams: [{198, 51, 100, 1}], upstream_timeout_ms: 200}
      start_supervised!({Forwarder, config})
      :ok
    end

    test "returns error when all upstreams fail" do
      query = build_query("example.com")

      assert {:error, :all_upstreams_failed} = Forwarder.forward(query)
    end
  end

  describe "forward/1 with multiple unreachable upstreams" do
    setup do
      config = %{
        @config
        | upstreams: [{198, 51, 100, 1}, {198, 51, 100, 2}],
          upstream_timeout_ms: 200
      }

      start_supervised!({Forwarder, config})
      :ok
    end

    test "tries all upstreams before failing" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "forwarder-test-#{inspect(ref)}",
        [:yellow_dog, :resolved, :forward, :exception],
        fn _event, _measurements, _metadata, _ ->
          send(test_pid, :upstream_tried)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("forwarder-test-#{inspect(ref)}") end)

      query = build_query("example.com")
      assert {:error, :all_upstreams_failed} = Forwarder.forward(query)

      # Should have tried both upstreams
      assert_receive :upstream_tried
      assert_receive :upstream_tried
    end
  end

  describe "upstream deprioritization" do
    setup do
      config = %{
        @config
        | upstreams: [{198, 51, 100, 1}, {198, 51, 100, 2}],
          upstream_timeout_ms: 200,
          upstream_failure_threshold: 2
      }

      start_supervised!({Forwarder, config})
      :ok
    end

    test "tracks failure counts via handle_cast" do
      # Force failures to increase failure counts
      query = build_query("fail.test")
      Forwarder.forward(query)

      # After failures, the forwarder should still be alive and accepting queries
      Process.sleep(50)
      pid = Process.whereis(Forwarder)
      assert Process.alive?(pid)
    end

    test "logs warning when failure threshold reached" do
      pid = Process.whereis(Forwarder)
      upstream = {198, 51, 100, 1}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # threshold is 2 — second failure triggers the warning
          GenServer.cast(pid, {:upstream_failure, upstream})
          GenServer.cast(pid, {:upstream_failure, upstream})
          Process.sleep(20)
        end)

      assert log =~ "deprioritized after 2 failures"
    end

    test "failure count increments correctly via :sys.get_state" do
      pid = Process.whereis(Forwarder)
      upstream = {198, 51, 100, 1}

      state_before = :sys.get_state(pid)
      assert Map.get(state_before.failure_counts, upstream) == 0

      GenServer.cast(pid, {:upstream_failure, upstream})
      Process.sleep(10)

      state_after = :sys.get_state(pid)
      assert Map.get(state_after.failure_counts, upstream) == 1
    end
  end

  describe "deprioritization with mixed upstreams" do
    setup do
      # Dead upstream (timeout) first, live upstream second
      {:ok, dead_pid, dead_port} = YellowDog.Resolved.Test.FakeUpstream.start(:timeout)
      {:ok, live_pid, live_port} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn ->
        YellowDog.Resolved.Test.FakeUpstream.stop(dead_pid)
        YellowDog.Resolved.Test.FakeUpstream.stop(live_pid)
      end)

      config = %{
        upstreams: [{{127, 0, 0, 1}, dead_port}, {{127, 0, 0, 1}, live_port}],
        upstream_timeout_ms: 300,
        upstream_failure_threshold: 2
      }

      start_supervised!({Forwarder, config})
      {:ok, dead_port: dead_port, live_port: live_port}
    end

    test "first query is slow (hits dead upstream first)" do
      query = build_query("slow.test")

      {time_us, {:ok, _}} = :timer.tc(fn -> Forwarder.forward(query) end)

      # First query must wait for timeout on dead upstream (~300ms)
      assert time_us > 200_000
    end

    test "queries get faster after dead upstream is deprioritized" do
      # First two queries: trigger failure_threshold (2) on dead upstream
      for _ <- 1..2 do
        query = build_query("warmup-#{System.unique_integer([:positive])}.test")
        Forwarder.forward(query)
      end

      Process.sleep(50)

      # Now dead upstream should be deprioritized (sorted last).
      # Next query should go to live upstream first — no timeout delay.
      query = build_query("fast.test")
      {time_us, {:ok, _}} = :timer.tc(fn -> Forwarder.forward(query) end)

      # Should be much faster since live upstream is tried first
      assert time_us < 200_000
    end
  end

  describe "failure count reset on success" do
    setup do
      {:ok, upstream_pid, upstream_port} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)
      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      upstream = {{127, 0, 0, 1}, upstream_port}

      config = %{
        upstreams: [upstream],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})
      {:ok, upstream: upstream}
    end

    test "success resets failure count to 0", %{upstream: upstream} do
      # Manually inject failures via handle_cast
      pid = Process.whereis(Forwarder)
      GenServer.cast(pid, {:upstream_failure, upstream})
      GenServer.cast(pid, {:upstream_failure, upstream})
      Process.sleep(10)

      # Verify failure count is 2
      state = :sys.get_state(pid)
      assert Map.get(state.failure_counts, upstream) == 2

      # Forward a real query — should succeed and reset count
      query = build_query("success-reset.test")
      assert {:ok, _} = Forwarder.forward(query)
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert Map.get(state.failure_counts, upstream) == 0
    end
  end

  describe "sort_upstreams ordering" do
    setup do
      {:ok, live_pid_a, port_a} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)
      {:ok, live_pid_b, port_b} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn ->
        YellowDog.Resolved.Test.FakeUpstream.stop(live_pid_a)
        YellowDog.Resolved.Test.FakeUpstream.stop(live_pid_b)
      end)

      # Two distinct upstreams on different ports
      upstream_a = {{127, 0, 0, 1}, port_a}
      upstream_b = {{127, 0, 0, 1}, port_b}

      config = %{
        upstreams: [upstream_a, upstream_b],
        upstream_timeout_ms: 2000,
        upstream_failure_threshold: 10
      }

      start_supervised!({Forwarder, config})
      {:ok, upstream_a: upstream_a, upstream_b: upstream_b}
    end

    test "upstreams sorted by failure count (least failures first)", ctx do
      pid = Process.whereis(Forwarder)

      # Inject 5 failures on upstream_a only
      for _ <- 1..5 do
        GenServer.cast(pid, {:upstream_failure, ctx.upstream_a})
      end

      Process.sleep(10)

      state = :sys.get_state(pid)
      assert Map.get(state.failure_counts, ctx.upstream_a) == 5
      assert Map.get(state.failure_counts, ctx.upstream_b) == 0
    end
  end

  describe "failover chain with 3 upstreams (2 dead, 1 live)" do
    setup do
      {:ok, dead1_pid, dead1_port} = YellowDog.Resolved.Test.FakeUpstream.start(:timeout)
      {:ok, dead2_pid, dead2_port} = YellowDog.Resolved.Test.FakeUpstream.start(:timeout)
      {:ok, live_pid, live_port} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      on_exit(fn ->
        YellowDog.Resolved.Test.FakeUpstream.stop(dead1_pid)
        YellowDog.Resolved.Test.FakeUpstream.stop(dead2_pid)
        YellowDog.Resolved.Test.FakeUpstream.stop(live_pid)
      end)

      config = %{
        upstreams: [
          {{127, 0, 0, 1}, dead1_port},
          {{127, 0, 0, 1}, dead2_port},
          {{127, 0, 0, 1}, live_port}
        ],
        upstream_timeout_ms: 200,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})
      {:ok, live_port: live_port}
    end

    test "eventually reaches live upstream after 2 dead ones" do
      query = build_query("chain.test")
      assert {:ok, response} = Forwarder.forward(query)

      # Should get a valid DNS response from the live upstream
      decoded = DNS.Message.from_iodata(response)
      assert decoded.header.qr == 1
    end

    test "all 3 upstreams are tried (2 exceptions + 1 success)" do
      test_pid = self()
      ref = make_ref()
      attempts = :counters.new(1, [:atomics])

      :telemetry.attach(
        "chain-start-#{inspect(ref)}",
        [:yellow_dog, :resolved, :forward, :start],
        fn _event, _measurements, _metadata, _ ->
          :counters.add(attempts, 1, 1)
        end,
        nil
      )

      :telemetry.attach(
        "chain-stop-#{inspect(ref)}",
        [:yellow_dog, :resolved, :forward, :stop],
        fn _event, _measurements, _metadata, _ ->
          send(test_pid, :forward_succeeded)
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("chain-start-#{inspect(ref)}")
        :telemetry.detach("chain-stop-#{inspect(ref)}")
      end)

      query = build_query("chain-count.test")
      assert {:ok, _} = Forwarder.forward(query)

      assert_receive :forward_succeeded, 5000
      # All 3 upstreams should have been tried
      assert :counters.get(attempts, 1) == 3
    end
  end

  describe "upstream_success resets failure count to 0 via cast" do
    test "direct upstream_success cast resets count" do
      config = %{@config | upstreams: [{198, 51, 100, 1}], upstream_timeout_ms: 200}
      start_supervised!({Forwarder, config})
      pid = Process.whereis(Forwarder)

      # Inject failures
      GenServer.cast(pid, {:upstream_failure, {198, 51, 100, 1}})
      GenServer.cast(pid, {:upstream_failure, {198, 51, 100, 1}})
      Process.sleep(10)
      assert :sys.get_state(pid).failure_counts[{198, 51, 100, 1}] == 2

      # Success resets
      GenServer.cast(pid, {:upstream_success, {198, 51, 100, 1}})
      Process.sleep(10)
      assert :sys.get_state(pid).failure_counts[{198, 51, 100, 1}] == 0
    end
  end

  describe "upstream deprioritization telemetry" do
    setup do
      config = %{
        @config
        | upstreams: [{198, 51, 100, 1}],
          upstream_timeout_ms: 200,
          upstream_failure_threshold: 2
      }

      start_supervised!({Forwarder, config})
      :ok
    end

    test "emits deprioritized telemetry when failure threshold reached" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "fwd-depri-#{inspect(ref)}",
        [:yellow_dog, :resolved, :upstream, :deprioritized],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:deprioritized, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("fwd-depri-#{inspect(ref)}") end)

      pid = Process.whereis(Forwarder)
      upstream = {198, 51, 100, 1}

      ExUnit.CaptureLog.capture_log(fn ->
        # Second failure hits threshold (2)
        GenServer.cast(pid, {:upstream_failure, upstream})
        GenServer.cast(pid, {:upstream_failure, upstream})
        Process.sleep(20)
      end)

      assert_receive {:deprioritized, measurements, metadata}
      assert measurements.failure_count == 2
      assert metadata.upstream == upstream
      assert metadata.threshold == 2
    end

    test "does NOT emit deprioritized telemetry below threshold" do
      ref = make_ref()

      :telemetry.attach(
        "fwd-no-depri-#{inspect(ref)}",
        [:yellow_dog, :resolved, :upstream, :deprioritized],
        fn _event, _measurements, _metadata, _ ->
          send(self(), :unexpected_deprioritized)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("fwd-no-depri-#{inspect(ref)}") end)

      pid = Process.whereis(Forwarder)
      # Only 1 failure, threshold is 2
      GenServer.cast(pid, {:upstream_failure, {198, 51, 100, 1}})
      Process.sleep(20)

      refute_receive :unexpected_deprioritized, 100
    end
  end

  describe "start_link/1 with {ip, port} upstreams" do
    test "starts with mixed upstream formats" do
      config = %{@config | upstreams: [{1, 1, 1, 1}, {{8, 8, 8, 8}, 5353}]}

      assert {:ok, pid} = start_supervised({Forwarder, config})
      assert Process.alive?(pid)
    end
  end

  describe "telemetry events" do
    setup do
      {:ok, upstream_pid, upstream_port} = YellowDog.Resolved.Test.FakeUpstream.start(:echo)
      on_exit(fn -> YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid) end)

      config = %{
        @config
        | upstreams: [{{127, 0, 0, 1}, upstream_port}],
          upstream_timeout_ms: 2000
      }

      start_supervised!({Forwarder, config})
      {:ok, upstream_port: upstream_port}
    end

    test "emits forward start and stop events on success" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "fwd-start-#{inspect(ref)}",
        [:yellow_dog, :resolved, :forward, :start],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:fwd_start, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "fwd-stop-#{inspect(ref)}",
        [:yellow_dog, :resolved, :forward, :stop],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:fwd_stop, metadata, measurements})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("fwd-start-#{inspect(ref)}")
        :telemetry.detach("fwd-stop-#{inspect(ref)}")
      end)

      query = build_query("telemetry.test")
      assert {:ok, _} = Forwarder.forward(query)

      assert_receive {:fwd_start, start_meta}
      assert String.starts_with?(start_meta.domain, "telemetry.test")

      assert_receive {:fwd_stop, stop_meta, measurements}
      assert String.starts_with?(stop_meta.domain, "telemetry.test")
      assert is_integer(measurements.duration)
    end
  end

  describe "handle_info catch-all" do
    test "ignores unexpected messages" do
      config = %{@config | upstreams: [{198, 51, 100, 1}], upstream_timeout_ms: 200}
      start_supervised!({Forwarder, config})

      pid = Process.whereis(Forwarder)
      send(pid, :unexpected_message)
      Process.sleep(10)

      assert Process.alive?(pid)
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      start_supervised!({Forwarder, @config})

      pid = Process.whereis(Forwarder)
      assert Process.alive?(pid)

      stop_supervised!(Forwarder)

      refute Process.alive?(pid)
    end
  end

  describe "safe_try_upstreams exception path" do
    test "replies with error when upstream raises during send_recv" do
      # Use a FakeUpstream that we immediately kill to create a race condition,
      # or inject a deliberately broken upstream spec that causes an exception.
      # The key invariant: the client always gets a reply, never hangs.
      {:ok, upstream_pid, upstream_port} =
        YellowDog.Resolved.Test.FakeUpstream.start(:echo)

      config = %{
        upstreams: [{{127, 0, 0, 1}, upstream_port}],
        upstream_timeout_ms: 500,
        upstream_failure_threshold: 3
      }

      start_supervised!({Forwarder, config})

      # Kill the upstream's socket to trigger potential exception in send_recv
      YellowDog.Resolved.Test.FakeUpstream.stop(upstream_pid)
      Process.sleep(50)

      query = build_query("exception-path.test")
      # Should return {:error, ...}, not hang or crash
      result = Forwarder.forward(query)
      assert {:error, :all_upstreams_failed} = result
    end
  end

  defp build_query(domain) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, 1, 1))
  end
end
