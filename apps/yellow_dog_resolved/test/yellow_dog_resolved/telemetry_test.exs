defmodule YellowDog.Resolved.TelemetryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Router}

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

  setup do
    start_supervised!({Config, @config})
    start_supervised!({Cache, @cache_config})

    {:ok, test_pid: self()}
  end

  defp attach_telemetry(event_name, test_pid) do
    ref = make_ref()
    handler_id = "test-#{inspect(ref)}-#{Enum.join(event_name, "-")}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  describe "cache telemetry events" do
    test "emits [:yellow_dog, :resolved, :cache, :store] on store" do
      attach_telemetry([:yellow_dog, :resolved, :cache, :store], self())

      Cache.store("telemetry.test", :a, "data", 300)
      Process.sleep(10)

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :cache, :store], %{},
                      %{domain: "telemetry.test", type: :a, ttl: _}}
    end

    test "emits [:yellow_dog, :resolved, :cache, :hit] on cache hit" do
      attach_telemetry([:yellow_dog, :resolved, :cache, :hit], self())

      Cache.store("hit.test", :a, "data", 300)
      Process.sleep(10)

      Cache.lookup("hit.test", :a)

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :cache, :hit], %{},
                      %{domain: "hit.test", type: :a}}
    end

    test "emits [:yellow_dog, :resolved, :cache, :miss] on cache miss" do
      attach_telemetry([:yellow_dog, :resolved, :cache, :miss], self())

      Cache.lookup("miss.test", :a)

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :cache, :miss], _,
                      %{domain: "miss.test", type: :a}}
    end

    test "emits [:yellow_dog, :resolved, :cache, :flush] on flush" do
      attach_telemetry([:yellow_dog, :resolved, :cache, :flush], self())

      Cache.store("flush.test", :a, "data", 300)
      Process.sleep(10)

      Cache.flush()

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :cache, :flush], %{},
                      %{pattern: nil, count: _}}
    end
  end

  describe "query telemetry events" do
    test "emits [:yellow_dog, :resolved, :query, :start] and :stop on intercept" do
      attach_telemetry([:yellow_dog, :resolved, :query, :start], self())
      attach_telemetry([:yellow_dog, :resolved, :query, :stop], self())

      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      Router.resolve(query, raw)

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :query, :start], %{},
                      %{domain: _, type: _}}

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :query, :stop], %{duration: _},
                      %{domain: _, type: _, source: :intercept}}
    end

    test "emits :exception event on error" do
      attach_telemetry([:yellow_dog, :resolved, :query, :exception], self())

      query = build_query("external.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # No forwarder started — will trigger catch clause
      Router.resolve(query, raw)

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :query, :exception],
                      %{duration: _}, %{reason: _}}
    end
  end

  describe "management telemetry events" do
    test "emits command event for cache_stats" do
      attach_telemetry(
        [:yellow_dog, :resolved, :management, :command],
        self()
      )

      YellowDog.Resolved.Management.Handler.handle_command(%{
        "type" => "cache_stats",
        "id" => "tel-001"
      })

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :management, :command], %{},
                      %{type: :cache_stats}}
    end

    test "emits command event for cache_flush" do
      attach_telemetry(
        [:yellow_dog, :resolved, :management, :command],
        self()
      )

      YellowDog.Resolved.Management.Handler.handle_command(%{
        "type" => "cache_flush",
        "id" => "tel-002",
        "data" => %{"pattern" => nil}
      })

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :management, :command], %{},
                      %{type: :cache_flush}}
    end

    test "emits command event for ping" do
      attach_telemetry(
        [:yellow_dog, :resolved, :management, :command],
        self()
      )

      YellowDog.Resolved.Management.Handler.handle_command(%{
        "type" => "ping",
        "id" => "tel-003",
        "data" => %{}
      })

      assert_receive {:telemetry_event, [:yellow_dog, :resolved, :management, :command], %{},
                      %{type: :ping}}
    end
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end
end
