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

  defp build_query(domain) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, 1, 1))
  end
end
