defmodule YellowDog.Netman.Control.ResolvedTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias YellowDog.Netman.Control.Resolved, as: ResolvedControl
  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, LinkDns, QueryLogger}
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @config %{
    listen: {127, 0, 0, 1},
    port: 53,
    upstreams: [{1, 1, 1, 1}],
    search_domains: ["managed.example"],
    upstream_timeout_ms: 3_000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 100,
      min_ttl_s: 1,
      max_ttl_s: 3_600,
      negative_ttl_s: 30,
      sweep_interval_s: 3_600
    },
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    rate_limit: %{burst: 50, rate: 20},
    intercept_rules: []
  }

  setup %{tmp_dir: tmp_dir} do
    previous_config_path = Application.fetch_env(:yellow_dog_resolved, :config_path)
    Application.put_env(:yellow_dog_resolved, :config_path, Path.join(tmp_dir, "resolved.toml"))

    on_exit(fn ->
      case previous_config_path do
        {:ok, config_path} ->
          Application.put_env(:yellow_dog_resolved, :config_path, config_path)

        :error ->
          Application.delete_env(:yellow_dog_resolved, :config_path)
      end
    end)

    start_supervised!({Config, @config})
    start_supervised!({Counters, []})
    start_supervised!({Cache, @config.cache})
    start_supervised!({Forwarder, @config})
    start_supervised!({LinkDns, []})
    start_supervised!({QueryLogger, buffer_size: 10})
    :ok
  end

  test "projects managed and per-link upstreams and search domains into typed results" do
    :ok =
      LinkDns.set_link_dns("eth0", %{
        servers: [{9, 9, 9, 9}],
        search: ["link.example"],
        priority: 50
      })

    assert {:ok, upstreams} =
             ResolvedControl.dispatch("netman.resolved.upstreams.list", %{})

    assert upstreams["items"] == [
             %{"address" => "1.1.1.1", "source" => "managed"},
             %{"address" => "9.9.9.9", "source" => "static"}
           ]

    assert {:ok, config_revision} =
             ResolvedControl.current("netman.resolved.config.update", %{})

    assert upstreams["config_revision"] == config_revision

    assert_valid_result("netman.resolved.upstreams.list", upstreams)

    assert {:ok, domains} =
             ResolvedControl.dispatch("netman.resolved.search_domains.list", %{})

    assert domains["items"] == [
             %{"domain" => "link.example", "routing_only" => false},
             %{"domain" => "managed.example", "routing_only" => false}
           ]

    assert_valid_result("netman.resolved.search_domains.list", domains)
  end

  test "projects explicit per-link DNS state without inventing server provenance" do
    :ok =
      LinkDns.set_link_dns("eth0", %{
        servers: [{9, 9, 9, 9}],
        search: ["link.example"],
        priority: 50
      })

    assert {:ok, result} =
             ResolvedControl.dispatch("netman.resolved.link_dns.list", %{"limit" => 10})

    assert result["items"] == [
             %{
               "link_id" => "eth0",
               "servers" => ["9.9.9.9"],
               "search_domains" => ["link.example"],
               "priority" => 50
             }
           ]

    refute Map.has_key?(hd(result["items"]), "source")
    assert_valid_result("netman.resolved.link_dns.list", result)
  end

  test "returns bounded recent resolver queries through the typed result" do
    QueryLogger.handle_event(
      [:yellow_dog, :resolved, :query, :stop],
      %{duration: 25},
      %{domain: "example.test", type: :a, source: :cache},
      %{pid: Process.whereis(QueryLogger)}
    )

    _barrier = :sys.get_state(QueryLogger)

    assert {:ok, result} =
             ResolvedControl.dispatch("netman.resolved.queries.list", %{"limit" => 1})

    assert [query] = result["items"]
    assert query["domain"] == "example.test"
    assert query["type"] == "a"
    assert query["source"] == "cache"
    assert is_integer(query["duration_us"])
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(query["timestamp"])
    assert_valid_result("netman.resolved.queries.list", result)
  end

  test "projects live cache entries and cache hit/miss counters" do
    response = %DNS.Message{
      anlist: [DNS.Message.Record.new("cached.example", :a, :in, 300, {192, 0, 2, 10})]
    }

    Cache.store("cached.example", :a, response, 300)
    _barrier = :sys.get_state(Cache)

    assert {:ok, cache} = ResolvedControl.dispatch("netman.resolved.cache.get", %{})

    assert [entry] = cache["entries"]
    assert entry["domain"] == "cached.example"
    assert entry["address"] == "192.0.2.10"
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(entry["expires_at"])

    assert {:ok, cache_revision} =
             ResolvedControl.current("netman.resolved.cache.flush", %{})

    assert cache["revision"] == cache_revision
    assert_valid_result("netman.resolved.cache.get", cache)

    assert {:hit, _, _} = Cache.lookup("cached.example", :a)
    assert :miss = Cache.lookup("missing.example", :a)

    assert {:ok, %{"hits" => hits, "misses" => misses} = counters} =
             ResolvedControl.dispatch("netman.resolved.counters.get", %{})

    assert hits >= 1
    assert misses >= 1
    assert_valid_result("netman.resolved.counters.get", counters)
  end

  test "updates, rolls back, and flushes with canonical owner revisions" do
    assert {:ok, initial_revision} =
             ResolvedControl.current("netman.resolved.config.update", %{})

    update = %{"upstreams" => ["8.8.8.8"], "search_domains" => ["new.example"]}

    assert {:ok, applied} =
             ResolvedControl.dispatch(
               "netman.resolved.config.update",
               update,
               mutation_context(initial_revision, 1)
             )

    assert applied["state"] == "applied"
    assert applied["version"] == 1
    assert applied["previous_version"] == nil
    assert applied["previous_revision"] == nil
    applied_revision = applied["applied_revision"]
    assert_valid_result("netman.resolved.config.update", applied)

    assert {:error, %Error{code: :conflict}} =
             ResolvedControl.dispatch(
               "netman.resolved.config.update",
               update,
               mutation_context(initial_revision, 2)
             )

    assert {:ok, rolled_back} =
             ResolvedControl.dispatch(
               "netman.resolved.config.rollback",
               %{"target_revision" => initial_revision},
               mutation_context(applied_revision, 2)
             )

    assert rolled_back["state"] == "applied"
    assert rolled_back["version"] == 2
    assert rolled_back["applied_revision"] == initial_revision
    assert rolled_back["previous_version"] == 1
    assert rolled_back["previous_revision"] == applied_revision
    assert_valid_result("netman.resolved.config.rollback", rolled_back)

    Cache.store("flush.example", :a, %{}, 300)
    _barrier = :sys.get_state(Cache)
    assert {:ok, cache_revision} = ResolvedControl.current("netman.resolved.cache.flush", %{})

    assert {:ok, %{"cleared_entries" => 1} = result} =
             ResolvedControl.dispatch(
               "netman.resolved.cache.flush",
               %{},
               mutation_context(cache_revision, nil)
             )

    assert_valid_result("netman.resolved.cache.flush", result)
  end

  test "runtime adapter apply and restore use the resolver's durable revision history" do
    assert {:ok, initial_revision} =
             ResolvedControl.current("netman.resolved.config.update", %{})

    payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["adapter.example"]}

    assert :ok = ResolvedControl.apply_config("netman.resolved.config.update", payload)
    assert {:ok, applied_revision} = ResolvedControl.current("netman.resolved.config.update", %{})
    refute applied_revision == initial_revision

    assert :ok = ResolvedControl.apply_config("netman.resolved.config.update", payload)
    assert :ok = ResolvedControl.restore_config(initial_revision)

    assert {:ok, ^initial_revision} =
             ResolvedControl.current("netman.resolved.config.rollback", %{})

    assert :ok = ResolvedControl.apply_config("netman.resolved.config.update", payload)

    assert :ok =
             ResolvedControl.apply_config(
               "netman.resolved.config.rollback",
               %{"target_revision" => initial_revision}
             )

    assert {:ok, ^initial_revision} =
             ResolvedControl.current("netman.resolved.config.rollback", %{})
  end

  test "returns stable errors for unsupported operations and missing rollback revisions" do
    assert {:error, %Error{code: :unsupported}} =
             ResolvedControl.dispatch("netman.resolved.unknown.get", %{})

    assert {:ok, revision} =
             ResolvedControl.current("netman.resolved.config.rollback", %{})

    assert {:error, %Error{code: :not_found}} =
             ResolvedControl.dispatch(
               "netman.resolved.config.rollback",
               %{"target_revision" => String.duplicate("f", 64)},
               mutation_context(revision, 1)
             )
  end

  test "persists resolver state only in the isolated test directory", %{tmp_dir: tmp_dir} do
    assert {:ok, revision} =
             ResolvedControl.current("netman.resolved.config.update", %{})

    assert {:ok, _result} =
             ResolvedControl.dispatch(
               "netman.resolved.config.update",
               %{"upstreams" => ["8.8.4.4"], "search_domains" => ["isolated.example"]},
               mutation_context(revision, 1)
             )

    assert File.regular?(Path.join(tmp_dir, "resolved-state.json"))

    refute File.exists?(Path.expand("../../config/resolved-state.json", __DIR__))
  end

  defp mutation_context(revision, version) do
    %{
      expected_revision: revision,
      current_revision: revision,
      precondition: {:revision, revision},
      config_version: version
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = NetmanOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end
end
