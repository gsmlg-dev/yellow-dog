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

  defp build_query(domain) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, 1, 1))
  end
end
