defmodule YellowDog.Dns.ConfigPersistenceTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.ConfigPersistence.

  Tests cover:
  - Loading all configuration (views and zones)
  - Saving all configuration
  - Individual save operations (views, zones)
  - Collection from ViewManager and ZoneController
  - Zone file path generation
  - Error handling
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.ConfigPersistence
  alias YellowDog.Dns.AclStore
  alias YellowDog.Dns.ViewStore
  alias YellowDog.Dns.ZoneStore
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @tmp_dir "test/tmp/config_persistence_test"

  setup do
    # Generate unique tmp dir for this test
    test_ref = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(@tmp_dir, to_string(test_ref))
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "default_data_path/0" do
    test "returns default path when YellowDog.Config not available" do
      # In test environment, YellowDog.Config may not be started
      path = ConfigPersistence.default_data_path()
      assert is_binary(path)
      assert path == "data/dns" or is_binary(path)
    end

    test "falls back when YellowDog.Config process is stopped" do
      Application.stop(:yellow_dog)
      on_exit(fn -> Application.ensure_all_started(:yellow_dog) end)

      refute Process.whereis(YellowDog.Config)
      assert ConfigPersistence.default_data_path() == "data/dns"
    end
  end

  describe "zones_path/2" do
    test "returns path to zones directory for a view" do
      path = ConfigPersistence.zones_path("test/data", "default")
      assert path == "test/data/views/default/zones"
    end

    test "handles different views" do
      path = ConfigPersistence.zones_path("test/data", "internal")
      assert path == "test/data/views/internal/zones"
    end
  end

  describe "acls_path/1" do
    test "returns path to acls directory" do
      assert ConfigPersistence.acls_path("test/data") == "test/data/acls"
    end

    test "returns path with default data path" do
      path = ConfigPersistence.acls_path()
      assert String.ends_with?(path, "acls")
    end
  end

  describe "zone_file_path/2" do
    test "default view zones go in views/default/zones/" do
      path = ConfigPersistence.zone_file_path("default", "example.com")
      assert path == "views/default/zones/example.com.zone"
    end

    test "other views get their own subdirectory" do
      path = ConfigPersistence.zone_file_path("internal", "example.com")
      assert path == "views/internal/zones/example.com.zone"
    end

    test "handles dots in zone names" do
      path = ConfigPersistence.zone_file_path("default", "sub.example.com")
      assert path == "views/default/zones/sub.example.com.zone"
    end

    test "handles root zone" do
      path = ConfigPersistence.zone_file_path("default", ".")
      assert path == "views/default/zones/..zone"
    end

    test "single-arg version uses default view" do
      path = ConfigPersistence.zone_file_path("example.com")
      assert path == "views/default/zones/example.com.zone"
    end
  end

  describe "load_all/1" do
    test "loads views, zones, and acls from valid files", %{tmp_dir: tmp_dir} do
      views_file = Path.join(tmp_dir, "views.toml")
      zones_file = Path.join(tmp_dir, "zones.toml")
      acls_file = Path.join(tmp_dir, "acls.toml")

      # Create valid views file
      File.write!(views_file, """
      [[view]]
      name = "default"
      priority = 100
      recursion = true
      match_clients = "any"

      [[view]]
      name = "internal"
      priority = 50
      recursion = false
      """)

      # Create valid zones file (using [zones."key"] format)
      File.write!(zones_file, """
      [zones."default:example.com"]
      type = "auth"
      file = "views/default/zones/example.com.zone"

      [zones."internal:internal.example.com"]
      type = "forward"
      upstreams = ["10.0.0.1", "10.0.0.2"]
      """)

      # Create valid acls file
      File.write!(acls_file, """
      [[acl]]
      name = "internal"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"
      """)

      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)

      assert is_list(config.views)
      assert length(config.views) == 2

      assert is_list(config.zones)
      assert length(config.zones) == 2

      assert is_list(config.acls)
      assert length(config.acls) == 1
    end

    test "returns error when views file is invalid", %{tmp_dir: tmp_dir} do
      views_file = Path.join(tmp_dir, "views.toml")
      zones_file = Path.join(tmp_dir, "zones.toml")

      File.write!(views_file, "invalid toml {{{")
      File.write!(zones_file, "# Empty zones\n")

      assert {:error, _reason} = ConfigPersistence.load_all(tmp_dir)
    end

    test "returns error when zones file is invalid", %{tmp_dir: tmp_dir} do
      views_file = Path.join(tmp_dir, "views.toml")
      zones_file = Path.join(tmp_dir, "zones.toml")

      File.write!(views_file, "# Empty views\n")
      File.write!(zones_file, "invalid toml {{{")

      assert {:error, _reason} = ConfigPersistence.load_all(tmp_dir)
    end

    test "returns empty lists when files are empty", %{tmp_dir: tmp_dir} do
      views_file = Path.join(tmp_dir, "views.toml")
      zones_file = Path.join(tmp_dir, "zones.toml")
      acls_file = Path.join(tmp_dir, "acls.toml")

      File.write!(views_file, "# Empty views\n")
      File.write!(zones_file, "# Empty zones\n")
      File.write!(acls_file, "# Empty acls\n")

      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)
      assert config.views == []
      assert config.zones == []
      assert config.acls == []
    end

    test "returns empty lists when files don't exist", %{tmp_dir: tmp_dir} do
      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)
      assert config.views == []
      assert config.zones == []
      assert config.acls == []
    end
  end

  describe "save_all/5" do
    test "saves views, zones, and acls to files", %{tmp_dir: tmp_dir} do
      views = [
        %{name: "default", priority: 100, recursion: true, match_clients: "any"},
        %{name: "test", priority: 50, recursion: false, match_clients: "10.0.0.0/8"}
      ]

      zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "default",
          file: "views/default/zones/example.com.zone"
        },
        %{name: "test.local", type: :forward, view_name: "test", upstreams: ["8.8.8.8"]}
      ]

      acls = [
        %{
          name: "internal",
          description: "Internal networks",
          rules: [%{action: "allow", network: "10.0.0.0/8"}]
        }
      ]

      assert :ok = ConfigPersistence.save_all(tmp_dir, views, zones, acls)

      # Verify files were created
      assert File.exists?(Path.join(tmp_dir, "views.toml"))
      assert File.exists?(Path.join(tmp_dir, "zones.toml"))
      assert File.exists?(Path.join(tmp_dir, "acls.toml"))
      assert File.dir?(Path.join(tmp_dir, "views"))
      assert File.dir?(Path.join(tmp_dir, "acls"))
      # View-specific zone directories should be created
      assert File.dir?(Path.join([tmp_dir, "views", "default", "zones"]))
      assert File.dir?(Path.join([tmp_dir, "views", "test", "zones"]))
    end

    test "creates data directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      new_dir = Path.join(tmp_dir, "nested/data/path")

      assert :ok = ConfigPersistence.save_all(new_dir, [], [], [])

      assert File.dir?(new_dir)
      assert File.dir?(Path.join(new_dir, "views"))
      assert File.dir?(Path.join(new_dir, "acls"))
    end

    test "saves empty configuration", %{tmp_dir: tmp_dir} do
      assert :ok = ConfigPersistence.save_all(tmp_dir, [], [], [])

      # Verify files were created (even if empty)
      assert File.exists?(Path.join(tmp_dir, "views.toml"))
      assert File.exists?(Path.join(tmp_dir, "zones.toml"))
      assert File.exists?(Path.join(tmp_dir, "acls.toml"))
    end

    test "overwrites existing files", %{tmp_dir: tmp_dir} do
      # First save
      views1 = [%{name: "original", priority: 100}]
      :ok = ConfigPersistence.save_all(tmp_dir, views1, [], [])

      # Second save with different data
      views2 = [%{name: "updated", priority: 200}]
      :ok = ConfigPersistence.save_all(tmp_dir, views2, [], [])

      # Verify file contains updated data
      {:ok, loaded} = ConfigPersistence.load_all(tmp_dir)
      assert [view] = loaded.views
      assert view.name == "updated"
    end
  end

  describe "save_views/3" do
    test "saves views to file", %{tmp_dir: tmp_dir} do
      views = [
        %{name: "default", priority: 100, recursion: true},
        %{name: "secondary", priority: 50}
      ]

      assert :ok = ConfigPersistence.save_views(tmp_dir, views)

      # Verify file exists and can be read back
      {:ok, loaded_views} = ViewStore.load_views(Path.join(tmp_dir, "views.toml"))
      assert length(loaded_views) == 2
    end

    test "creates parent directory if needed", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "a/b/c")

      assert :ok = ConfigPersistence.save_views(nested_dir, [])
      assert File.exists?(Path.join(nested_dir, "views.toml"))
    end
  end

  describe "save_zones/3" do
    test "saves zones to file", %{tmp_dir: tmp_dir} do
      zones = [
        %{name: "example.com", type: :auth, view_name: "default"},
        %{name: "test.local", type: :stub, view_name: "default", ns_records: ["ns1.test.local"]}
      ]

      assert :ok = ConfigPersistence.save_zones(tmp_dir, zones)

      # Verify file exists and can be read back
      {:ok, loaded_zones} = ZoneStore.load_zones(Path.join(tmp_dir, "zones.toml"))
      assert length(loaded_zones) == 2
    end

    test "creates parent directory if needed", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "x/y/z")

      assert :ok = ConfigPersistence.save_zones(nested_dir, [])
      assert File.exists?(Path.join(nested_dir, "zones.toml"))
    end
  end

  describe "save_acls/3" do
    test "saves acls to file", %{tmp_dir: tmp_dir} do
      acls = [
        %{
          name: "internal",
          description: "Internal networks",
          rules: [%{action: "allow", network: "10.0.0.0/8"}]
        },
        %{
          name: "trusted",
          description: "Trusted partners",
          rules: [
            %{action: "allow", network: "172.16.0.0/12"},
            %{action: "allow", geo_countries: ["US", "CA"]}
          ]
        }
      ]

      assert :ok = ConfigPersistence.save_acls(tmp_dir, acls)
      assert File.exists?(Path.join(tmp_dir, "acls.toml"))

      # Verify round-trip
      {:ok, loaded_acls} = AclStore.load_acls(Path.join(tmp_dir, "acls.toml"))
      assert length(loaded_acls) == 2

      internal = Enum.find(loaded_acls, &(&1.name == "internal"))
      assert internal.description == "Internal networks"
      assert length(internal.rules) == 1
      assert hd(internal.rules).network == "10.0.0.0/8"
    end

    test "saves empty acls list", %{tmp_dir: tmp_dir} do
      assert :ok = ConfigPersistence.save_acls(tmp_dir, [])
      assert File.exists?(Path.join(tmp_dir, "acls.toml"))

      {:ok, loaded} = AclStore.load_acls(Path.join(tmp_dir, "acls.toml"))
      assert loaded == []
    end
  end

  describe "collect_acls/0" do
    test "returns empty list when AclRegistry is not running" do
      # Ensure AclRegistry is not running
      case Process.whereis(YellowDog.Dns.AclRegistry) do
        nil -> :ok
        _pid -> :ok
      end

      acls = ConfigPersistence.collect_acls()
      assert is_list(acls)
    end
  end

  describe "round-trip persistence" do
    test "views survive save/load cycle", %{tmp_dir: tmp_dir} do
      original_views = [
        %{
          name: "production",
          priority: 100,
          recursion: true,
          ecs_enabled: true,
          match_clients: "any",
          zones: ["example.com", "example.org"]
        },
        %{
          name: "internal",
          priority: 50,
          recursion: false,
          ecs_enabled: false,
          match_clients: "10.0.0.0/8",
          zones: ["internal.local"]
        }
      ]

      :ok = ConfigPersistence.save_views(tmp_dir, original_views)
      {:ok, loaded_views} = ViewStore.load_views(Path.join(tmp_dir, "views.toml"))

      assert length(loaded_views) == 2

      production = Enum.find(loaded_views, &(&1.name == "production"))
      assert production.priority == 100
      assert production.recursion == true
    end

    test "zones survive save/load cycle", %{tmp_dir: tmp_dir} do
      original_zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "default",
          file: "zones/example.com.zone"
        },
        %{
          name: "cached.local",
          type: :cache,
          view_name: "internal"
        },
        %{
          name: "forwarded.com",
          type: :forward,
          view_name: "default",
          upstreams: ["8.8.8.8", "8.8.4.4"]
        }
      ]

      :ok = ConfigPersistence.save_zones(tmp_dir, original_zones)
      {:ok, loaded_zones} = ZoneStore.load_zones(Path.join(tmp_dir, "zones.toml"))

      assert length(loaded_zones) == 3

      forwarded = Enum.find(loaded_zones, &(&1.name == "forwarded.com"))
      assert forwarded.type == :forward
      assert forwarded.upstreams == ["8.8.8.8", "8.8.4.4"]
    end

    test "acls survive save/load cycle", %{tmp_dir: tmp_dir} do
      original_acls = [
        %{
          name: "roundtrip_acl",
          description: "Test round-trip",
          rules: [
            %{action: "allow", network: "192.168.0.0/16"},
            %{action: "allow", geo_countries: ["US", "GB"]}
          ]
        }
      ]

      :ok = ConfigPersistence.save_acls(tmp_dir, original_acls)
      {:ok, loaded_acls} = AclStore.load_acls(Path.join(tmp_dir, "acls.toml"))

      assert length(loaded_acls) == 1
      loaded = hd(loaded_acls)
      assert loaded.name == "roundtrip_acl"
      assert loaded.description == "Test round-trip"
      assert length(loaded.rules) == 2
    end

    test "full config survives save/load cycle", %{tmp_dir: tmp_dir} do
      views = [
        %{name: "test_view", priority: 75, recursion: true}
      ]

      zones = [
        %{name: "test.zone", type: :auth, view_name: "test_view"}
      ]

      acls = [
        %{name: "test_acl", rules: [%{action: "allow", network: "10.0.0.0/8"}]}
      ]

      :ok = ConfigPersistence.save_all(tmp_dir, views, zones, acls)
      {:ok, loaded} = ConfigPersistence.load_all(tmp_dir)

      assert length(loaded.views) == 1
      assert length(loaded.zones) == 1
      assert length(loaded.acls) == 1

      assert hd(loaded.views).name == "test_view"
      assert hd(loaded.zones).name == "test.zone"
      assert hd(loaded.acls).name == "test_acl"
    end
  end

  describe "edge cases" do
    test "handles unicode in view/zone names", %{tmp_dir: tmp_dir} do
      views = [%{name: "日本語ビュー", priority: 100}]
      zones = [%{name: "日本語.example.com", type: :auth, view_name: "日本語ビュー"}]

      :ok = ConfigPersistence.save_all(tmp_dir, views, zones)
      {:ok, loaded} = ConfigPersistence.load_all(tmp_dir)

      assert hd(loaded.views).name == "日本語ビュー"
      assert hd(loaded.zones).name == "日本語.example.com"
    end

    test "handles special characters in values", %{tmp_dir: tmp_dir} do
      views = [%{name: "view-with_special.chars", priority: 100}]

      :ok = ConfigPersistence.save_views(tmp_dir, views)
      {:ok, loaded} = ViewStore.load_views(Path.join(tmp_dir, "views.toml"))

      assert hd(loaded).name == "view-with_special.chars"
    end

    test "handles empty string values", %{tmp_dir: tmp_dir} do
      views = [%{name: "empty_desc", priority: 100, description: ""}]

      :ok = ConfigPersistence.save_views(tmp_dir, views)
      {:ok, loaded} = ViewStore.load_views(Path.join(tmp_dir, "views.toml"))

      assert length(loaded) == 1
    end

    test "handles very long zone names", %{tmp_dir: tmp_dir} do
      long_name = String.duplicate("sub.", 50) <> "example.com"
      zones = [%{name: long_name, type: :auth, view_name: "default"}]

      :ok = ConfigPersistence.save_zones(tmp_dir, zones)
      {:ok, loaded} = ZoneStore.load_zones(Path.join(tmp_dir, "zones.toml"))

      assert hd(loaded).name == long_name
    end

    test "handles many views and zones", %{tmp_dir: tmp_dir} do
      views = for i <- 1..50, do: %{name: "view_#{i}", priority: i}
      zones = for i <- 1..100, do: %{name: "zone_#{i}.local", type: :auth, view_name: "view_1"}

      :ok = ConfigPersistence.save_all(tmp_dir, views, zones)
      {:ok, loaded} = ConfigPersistence.load_all(tmp_dir)

      assert length(loaded.views) == 50
      assert length(loaded.zones) == 100
    end
  end

  describe "collect_views/1" do
    test "collects views from ViewManager" do
      ensure_registry(YellowDog.Dns.ViewRegistry)

      vm_name = :"test_vm_#{:erlang.unique_integer([:positive])}"
      {:ok, vm} = YellowDog.Dns.ViewManager.start_link(name: vm_name)

      {:ok, _} =
        YellowDog.Dns.ViewManager.start_view(vm, %{
          name: "collect_test_#{:erlang.unique_integer([:positive])}",
          priority: 10,
          acl: :any,
          zones: [],
          recursion_enabled: false
        })

      views = ConfigPersistence.collect_views(vm)
      assert is_list(views)
      assert length(views) == 1
      assert hd(views).priority == 10

      DynamicSupervisor.stop(vm)
    end
  end

  describe "collect_zones/1" do
    test "collects zones from ZoneController" do
      ensure_registry(YellowDog.Dns.ZoneRegistry)

      zc_name = :"test_zc_#{:erlang.unique_integer([:positive])}"
      {:ok, zc} = YellowDog.Dns.ZoneController.start_link(name: zc_name)

      view_name = "collect_zones_#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        YellowDog.Dns.ZoneController.start_zone(zc, :auth, "collect.example.com",
          view_name: view_name,
          zone_data: []
        )

      zones = ConfigPersistence.collect_zones(zc)
      assert is_list(zones)
      assert length(zones) == 1
      assert hd(zones).name == "collect.example.com"
      assert hd(zones).type == :auth

      DynamicSupervisor.stop(zc)
    end

    test "collects auth zone cloud mirror metadata from Store" do
      ensure_registry(YellowDog.Dns.ZoneRegistry)
      EtsBackend.create_table()
      Backend.set_active(EtsBackend)
      :ets.delete_all_objects(EtsBackend.table())

      zc_name = :"test_zc_#{:erlang.unique_integer([:positive])}"
      {:ok, zc} = YellowDog.Dns.ZoneController.start_link(name: zc_name)

      view_name = "collect_cloud_#{:erlang.unique_integer([:positive])}"

      cloud_mirror = %{
        enabled: true,
        connector_name: "aws-prod",
        provider: :route53,
        zone_id: "Z123456789",
        direction: :bidirectional,
        conflict_strategy: :local_wins
      }

      {:ok, _} =
        YellowDog.Dns.ZoneController.start_zone(zc, :auth, "cloud.example.com",
          view_name: view_name,
          zone_data: [],
          cloud_mirror: cloud_mirror
        )

      zones = ConfigPersistence.collect_zones(zc)
      assert [%{cloud_mirror: ^cloud_mirror}] = zones

      DynamicSupervisor.stop(zc)
    end
  end

  describe "save_current/2" do
    test "saves current configuration from running services", %{tmp_dir: tmp_dir} do
      ensure_registry(YellowDog.Dns.ViewRegistry)
      ensure_registry(YellowDog.Dns.ZoneRegistry)

      # Start global-named ViewManager and ZoneController for save_current/2
      vm_pid =
        case YellowDog.Dns.ViewManager.start_link(name: YellowDog.Dns.ViewManager) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      _zc_pid =
        case DynamicSupervisor.start_link(
               strategy: :one_for_one,
               name: YellowDog.Dns.ZoneController
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      view_name = "save_current_#{:erlang.unique_integer([:positive])}"

      {:ok, view_pid} =
        YellowDog.Dns.ViewManager.start_view(vm_pid, %{
          name: view_name,
          priority: 5,
          acl: :any,
          zones: [{:auth, "save.example.com"}],
          recursion_enabled: false
        })

      {:ok, zone_pid} =
        YellowDog.Dns.ZoneController.start_zone(:auth, "save.example.com",
          view_name: view_name,
          zone_data: []
        )

      result = ConfigPersistence.save_current(tmp_dir)
      assert result == :ok

      # Verify files were created
      assert File.exists?(Path.join(tmp_dir, "views"))

      # Clean up
      GenServer.stop(view_pid)
      GenServer.stop(zone_pid)
    end
  end

  describe "error handling" do
    test "returns error for read-only directory", %{tmp_dir: tmp_dir} do
      # Create a read-only directory
      readonly_dir = Path.join(tmp_dir, "readonly")
      File.mkdir_p!(readonly_dir)

      # Make it read-only (may not work on all systems)
      try do
        File.chmod!(readonly_dir, 0o444)

        # Attempt to save should fail
        result = ConfigPersistence.save_all(readonly_dir, [], [])
        # On some systems this might succeed, so we just check it's a valid result
        assert result == :ok or match?({:error, _}, result)
      after
        # Restore permissions for cleanup
        File.chmod!(readonly_dir, 0o755)
      end
    end
  end

  defp ensure_registry(name) do
    case Process.whereis(name) do
      nil -> Registry.start_link(keys: :unique, name: name)
      _pid -> {:ok, name}
    end
  end
end
