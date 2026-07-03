defmodule Abyss.ListenerPoolScalerTest do
  use ExUnit.Case, async: false

  alias Abyss.ListenerPoolScaler
  alias Abyss.Server

  @response_time_event [:abyss, :metrics, :response_time]

  defmodule ScalerTestHandler do
    use Abyss.Handler

    @impl true
    def handle_data(_data, state), do: {:close, state}
  end

  defmodule OtherHandler do
    use Abyss.Handler

    @impl true
    def handle_data(_data, state), do: {:close, state}
  end

  defp start_server(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          handler_module: ScalerTestHandler,
          port: 0,
          num_listeners: 2,
          dynamic_listeners: true,
          min_listeners: 1,
          max_listeners: 10
        ],
        overrides
      )

    start_supervised!({Abyss, opts})
  end

  defp active_listeners(server) do
    server
    |> Server.listener_pool_pid()
    |> Supervisor.count_children()
    |> Map.fetch!(:active)
  end

  defp add_fake_connections(server, count) do
    conn_sup = Server.connection_sup_pid(server)

    for _ <- 1..count do
      {:ok, _pid} = DynamicSupervisor.start_child(conn_sup, {Agent, fn -> 0 end})
    end

    :ok
  end

  describe "supervision tree wiring" do
    test "scaler is started when dynamic_listeners is enabled" do
      server = start_server()

      assert is_pid(Server.listener_pool_scaler_pid(server))
    end

    test "scaler is not started when dynamic_listeners is disabled" do
      server = start_server(dynamic_listeners: false)

      assert Server.listener_pool_scaler_pid(server) == nil
    end

    test "scaler is not started in broadcast mode" do
      server =
        start_server(
          transport_module: Abyss.Transport.UDP.Broadcast,
          dynamic_listeners: true
        )

      assert Server.listener_pool_scaler_pid(server) == nil
    end

    test "detaches its telemetry handler when the server stops" do
      handler_count = fn ->
        @response_time_event |> :telemetry.list_handlers() |> length()
      end

      before_count = handler_count.()
      server = start_server()
      assert handler_count.() == before_count + 1

      Abyss.stop(server)
      assert handler_count.() == before_count
    end
  end

  describe "scaling behavior" do
    test "scales down toward min_listeners when idle" do
      server = start_server(num_listeners: 6)
      scaler = Server.listener_pool_scaler_pid(server)
      assert active_listeners(server) == 6

      # Idle: optimal = 1, scale-down capped at 3 per check
      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 3

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 1

      # At min — no further scaling
      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 1
    end

    test "scales up under connection load" do
      server = start_server(num_listeners: 2)
      scaler = Server.listener_pool_scaler_pid(server)
      assert active_listeners(server) == 2

      # 500 connections at the default 100ms baseline -> optimal 5
      add_fake_connections(server, 500)

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 5
    end

    test "scales up to at most max_listeners" do
      server = start_server(num_listeners: 2, max_listeners: 3)
      scaler = Server.listener_pool_scaler_pid(server)

      # 1000 connections -> optimal 10, clamped to max_listeners 3
      add_fake_connections(server, 1000)

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 3

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 3
    end

    test "does not scale while the pool is suspended" do
      server = start_server(num_listeners: 2)
      scaler = Server.listener_pool_scaler_pid(server)

      assert :ok = Abyss.suspend(server)
      assert active_listeners(server) == 0

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      assert active_listeners(server) == 0
    end

    test "emits scale telemetry events with actual counts" do
      test_pid = self()
      handler_id = "scaler-test-#{inspect(self())}"

      :telemetry.attach_many(
        handler_id,
        [
          [:abyss, :listener_pool, :scale_up],
          [:abyss, :listener_pool, :scale_down]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:scale_event, event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      server = start_server(num_listeners: 6)
      scaler = Server.listener_pool_scaler_pid(server)

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)

      assert_receive {:scale_event, [:abyss, :listener_pool, :scale_down], measurements, metadata}

      assert measurements.listeners_removed == 3
      assert measurements.new_total == 3
      assert metadata.previous_count == 6
      assert metadata.optimal == 1
    end
  end

  describe "response time metrics" do
    test "handle_response_time accumulates events from the matching handler only" do
      counters = :counters.new(2, [:write_concurrency])
      config = %{handler_module: ScalerTestHandler, counters: counters}

      ListenerPoolScaler.handle_response_time(
        @response_time_event,
        %{response_time: 40},
        %{handler: ScalerTestHandler},
        config
      )

      ListenerPoolScaler.handle_response_time(
        @response_time_event,
        %{response_time: 99},
        %{handler: OtherHandler},
        config
      )

      ListenerPoolScaler.handle_response_time(
        @response_time_event,
        %{response_time: 99},
        %{},
        config
      )

      assert :counters.get(counters, 1) == 40
      assert :counters.get(counters, 2) == 1
    end

    test "slow responses raise the optimal listener count" do
      server = start_server(num_listeners: 2)
      scaler = Server.listener_pool_scaler_pid(server)

      # 300 connections at 100ms -> optimal 3; at 200ms -> optimal 6
      add_fake_connections(server, 300)

      # Feed slow response times through the real telemetry event
      for _ <- 1..10 do
        Abyss.Telemetry.track_response_sent(200, %{handler: ScalerTestHandler})
      end

      assert :ok = ListenerPoolScaler.check_and_scale(scaler)
      # Scale-up capped at 5 per check: 2 + 5 = 7, optimal 6 -> min(6 - 2, 5) = 4
      assert active_listeners(server) == 6
    end
  end

  describe "calculate_optimal_listeners/2" do
    test "calculates optimal listeners based on current connections" do
      # 1000 connections, 100ms avg: base=10, factor=1
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 100.0) == 10

      # 5000 connections, 100ms avg: base=50, factor=1
      assert Abyss.ServerConfig.calculate_optimal_listeners(5000, 100.0) == 50

      # 1000 connections, 200ms avg (slower): base=10, factor=2
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 200.0) == 20

      # 100 connections, 50ms avg (faster): base=1, factor=0.5, min 1
      assert Abyss.ServerConfig.calculate_optimal_listeners(100, 50.0) == 1
    end

    test "always returns at least 1 listener" do
      assert Abyss.ServerConfig.calculate_optimal_listeners(0, 100.0) == 1
      assert Abyss.ServerConfig.calculate_optimal_listeners(100, 10.0) == 1
    end

    test "handles high processing times" do
      # base=10, factor=5
      assert Abyss.ServerConfig.calculate_optimal_listeners(1000, 500.0) == 50
    end
  end
end
