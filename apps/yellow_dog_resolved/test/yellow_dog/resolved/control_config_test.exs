defmodule YellowDog.Resolved.ControlConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved
  alias YellowDog.Resolved.Config

  @base_config %{
    listen: {127, 0, 0, 1},
    port: 53,
    upstreams: [{1, 1, 1, 1}],
    search_domains: ["initial.example"],
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

  setup do
    persistence_dir =
      Path.join(
        System.tmp_dir!(),
        "resolved-config-#{System.unique_integer([:positive, :monotonic])}"
      )

    config_path = Path.join(persistence_dir, "resolved.toml")
    state_path = Path.join(persistence_dir, "resolved-state.json")

    File.mkdir_p!(persistence_dir)

    File.write!(config_path, """
    [resolved]
    upstreams = ["1.1.1.1"]
    search_domains = ["initial.example"]
    """)

    Application.put_env(:yellow_dog_resolved, :config_path, config_path)

    on_exit(fn ->
      Application.delete_env(:yellow_dog_resolved, :config_path)
      File.rm_rf!(persistence_dir)
    end)

    {:ok, config_path: config_path, state_path: state_path}
  end

  test "updates canonical managed config and rolls back to an immutable prior revision" do
    start_config(runtime_apply: fn _new, _old -> :ok end)

    assert {:ok, initial_revision} = Resolved.config_revision()

    assert {:ok, first} =
             Resolved.update_config(
               %{
                 "upstreams" => ["9.9.9.9", "2001:4860:4860::8888"],
                 "search_domains" => ["corp.example"]
               },
               expected_revision: initial_revision,
               version: 1
             )

    assert first.previous_revision == initial_revision
    assert first.previous_version == nil
    assert Config.get(:upstreams) == [{9, 9, 9, 9}, {8193, 18528, 18528, 0, 0, 0, 0, 34952}]
    assert Config.get(:search_domains) == ["corp.example"]

    assert {:ok, second} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => ["branch.example"]},
               expected_revision: first.revision,
               version: 2
             )

    assert second.previous_revision == first.revision
    assert second.previous_version == 1

    assert {:ok, rolled_back} =
             Resolved.rollback_config(first.revision,
               expected_revision: second.revision,
               version: 3
             )

    assert rolled_back.revision == first.revision
    assert rolled_back.previous_revision == second.revision
    assert rolled_back.previous_version == 2
    assert Config.get(:upstreams) == [{9, 9, 9, 9}, {8193, 18528, 18528, 0, 0, 0, 0, 34952}]
    assert Config.get(:search_domains) == ["corp.example"]
  end

  test "rejects invalid DNS endpoints, search domains, stale revisions, and missing history" do
    start_config(runtime_apply: fn _new, _old -> :ok end)
    assert {:ok, revision} = Resolved.config_revision()

    for invalid <- [
          %{"upstreams" => ["1.1.1.1:53"], "search_domains" => []},
          %{"upstreams" => ["not-an-ip"], "search_domains" => []},
          %{"upstreams" => ["1.1.1.1"], "search_domains" => ["bad domain"]},
          %{"upstreams" => [], "search_domains" => [String.duplicate("a", 64) <> ".test"]}
        ] do
      assert {:error, :invalid_config} =
               Resolved.update_config(invalid, expected_revision: revision, version: 1)
    end

    assert {:error, {:conflict, ^revision}} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => []},
               expected_revision: String.duplicate("a", 64),
               version: 1
             )

    assert {:error, :revision_not_found} =
             Resolved.rollback_config(String.duplicate("f", 64),
               expected_revision: revision,
               version: 1
             )
  end

  test "does not apply runtime state when persistence fails" do
    test_pid = self()

    start_config(
      persist: fn _new, _old -> {:error, :disk_full} end,
      runtime_apply: fn _new, _old ->
        send(test_pid, :runtime_applied)
        :ok
      end
    )

    assert {:ok, revision} = Resolved.config_revision()

    assert {:error, {:write_failed, :disk_full}} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => []},
               expected_revision: revision,
               version: 1
             )

    assert Config.get(:upstreams) == @base_config.upstreams
    refute_receive :runtime_applied
  end

  test "restores the prior persisted and runtime config after a partial apply failure" do
    test_pid = self()

    runtime_apply = fn config, _old ->
      send(test_pid, {:runtime_apply, config.upstreams})
      if config.upstreams == [{8, 8, 8, 8}], do: {:error, :reload_failed}, else: :ok
    end

    start_config(runtime_apply: runtime_apply)
    assert {:ok, revision} = Resolved.config_revision()

    assert {:error, {:apply_failed, :reload_failed}} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => []},
               expected_revision: revision,
               version: 1
             )

    assert_receive {:runtime_apply, [{8, 8, 8, 8}]}
    assert_receive {:runtime_apply, [{1, 1, 1, 1}]}
    assert Config.get(:upstreams) == @base_config.upstreams
    assert {:ok, ^revision} = Resolved.config_revision()
  end

  test "reports rollback failure while retaining the prior authoritative config" do
    start_config(runtime_apply: fn _config, _old -> {:error, :reload_failed} end)
    assert {:ok, revision} = Resolved.config_revision()

    assert {:error, {:rollback_failed, :reload_failed}} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => []},
               expected_revision: revision,
               version: 1
             )

    assert Config.get(:upstreams) == @base_config.upstreams
    assert {:ok, ^revision} = Resolved.config_revision()
  end

  test "default persistence restores current config and rollback history after restart", %{
    config_path: config_path,
    state_path: state_path
  } do
    start_config(runtime_apply: fn _new, _old -> :ok end)
    assert {:ok, initial_revision} = Resolved.config_revision()

    assert {:ok, first} =
             Resolved.update_config(
               %{"upstreams" => ["9.9.9.9"], "search_domains" => ["corp.example"]},
               expected_revision: initial_revision,
               version: 1
             )

    assert {:ok, second} =
             Resolved.update_config(
               %{"upstreams" => ["8.8.8.8"], "search_domains" => ["branch.example"]},
               expected_revision: first.revision,
               version: 2
             )

    assert Path.dirname(state_path) == Path.dirname(config_path)
    assert File.regular?(state_path)
    assert Path.wildcard(Path.join(Path.dirname(state_path), ".resolved-state.json.*.tmp")) == []

    stop_supervised(Config)

    loaded = Config.load()
    assert loaded.upstreams == [{8, 8, 8, 8}]
    assert loaded.search_domains == ["branch.example"]

    start_config(runtime_apply: fn _new, _old -> :ok end)

    assert {:ok, second.revision} == Resolved.config_revision()
    assert Config.get(:upstreams) == [{8, 8, 8, 8}]
    assert Config.get(:search_domains) == ["branch.example"]

    assert {:ok, rolled_back} =
             Resolved.rollback_config(first.revision,
               expected_revision: second.revision,
               version: 3
             )

    assert rolled_back.revision == first.revision
    assert Config.get(:upstreams) == [{9, 9, 9, 9}]
    assert Config.get(:search_domains) == ["corp.example"]
  end

  test "durable revision history remains bounded across restart", %{state_path: state_path} do
    start_config(runtime_apply: fn _new, _old -> :ok end)
    assert {:ok, initial_revision} = Resolved.config_revision()

    {latest_revision, revisions} =
      Enum.reduce(1..40, {initial_revision, [initial_revision]}, fn index,
                                                                    {current_revision, revisions} ->
        assert {:ok, result} =
                 Resolved.update_config(
                   %{
                     "upstreams" => ["192.0.2.#{index}"],
                     "search_domains" => ["site-#{index}.example"]
                   },
                   expected_revision: current_revision,
                   version: index
                 )

        {result.revision, revisions ++ [result.revision]}
      end)

    assert {:ok, persisted} = state_path |> File.read!() |> Jason.decode()
    assert length(persisted["history"]) == 32

    stop_supervised(Config)
    start_config(runtime_apply: fn _new, _old -> :ok end)

    assert {:ok, ^latest_revision} = Resolved.config_revision()
    assert length(:sys.get_state(Config).history_order) == 32

    evicted_revision = Enum.at(revisions, 1)
    retained_revision = Enum.at(revisions, -2)

    assert {:error, :revision_not_found} =
             Resolved.rollback_config(evicted_revision,
               expected_revision: latest_revision,
               version: 41
             )

    assert {:ok, %{revision: ^retained_revision}} =
             Resolved.rollback_config(retained_revision,
               expected_revision: latest_revision,
               version: 41
             )
  end

  test "durable history preserves search domains accepted from static config" do
    static_config = %{@base_config | search_domains: ["Mixed.Example."]}
    start_supervised!({Config, {static_config, runtime_apply: fn _new, _old -> :ok end}})
    assert {:ok, static_revision} = Resolved.config_revision()

    assert {:ok, managed} =
             Resolved.update_config(
               %{"upstreams" => ["9.9.9.9"], "search_domains" => ["corp.example"]},
               expected_revision: static_revision,
               version: 1
             )

    managed_revision = managed.revision

    stop_supervised(Config)
    start_supervised!({Config, {static_config, runtime_apply: fn _new, _old -> :ok end}})

    assert {:ok, ^managed_revision} = Resolved.config_revision()

    assert {:ok, %{revision: ^static_revision}} =
             Resolved.rollback_config(static_revision,
               expected_revision: managed_revision,
               version: 2
             )

    assert Config.get(:search_domains) == ["Mixed.Example."]
  end

  defp start_config(opts) do
    start_supervised!({Config, {@base_config, opts}})
  end
end
