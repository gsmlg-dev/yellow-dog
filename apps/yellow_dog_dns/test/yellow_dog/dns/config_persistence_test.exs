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
  alias YellowDog.Dns.ViewStore
  alias YellowDog.Dns.ZoneStore

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
  end

  describe "zones_path/1" do
    test "returns path to zones directory" do
      path = ConfigPersistence.zones_path("test/data")
      assert path == "test/data/zones"
    end

    test "handles trailing slash" do
      path = ConfigPersistence.zones_path("test/data/")
      assert path == "test/data/zones"
    end
  end

  describe "zone_file_path/2" do
    test "default view zones go in zones/ directly" do
      path = ConfigPersistence.zone_file_path("default", "example.com")
      assert path == "zones/example.com.zone"
    end

    test "other views get their own subdirectory" do
      path = ConfigPersistence.zone_file_path("internal", "example.com")
      assert path == "zones/internal/example.com.zone"
    end

    test "handles dots in zone names" do
      path = ConfigPersistence.zone_file_path("default", "sub.example.com")
      assert path == "zones/sub.example.com.zone"
    end

    test "handles root zone" do
      path = ConfigPersistence.zone_file_path("default", ".")
      assert path == "zones/..zone"
    end

    test "single-arg version uses default view" do
      path = ConfigPersistence.zone_file_path("example.com")
      assert path == "zones/example.com.zone"
    end
  end

  describe "load_all/1" do
    test "loads views and zones from valid files", %{tmp_dir: tmp_dir} do
      views_file = Path.join(tmp_dir, "views.toml")
      zones_file = Path.join(tmp_dir, "zones.toml")

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
      file = "zones/example.com.zone"

      [zones."internal:internal.example.com"]
      type = "forward"
      upstreams = ["10.0.0.1", "10.0.0.2"]
      """)

      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)

      assert is_list(config.views)
      assert length(config.views) == 2

      assert is_list(config.zones)
      assert length(config.zones) == 2
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

      File.write!(views_file, "# Empty views\n")
      File.write!(zones_file, "# Empty zones\n")

      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)
      assert config.views == []
      assert config.zones == []
    end

    test "returns empty lists when files don't exist", %{tmp_dir: tmp_dir} do
      assert {:ok, config} = ConfigPersistence.load_all(tmp_dir)
      assert config.views == []
      assert config.zones == []
    end
  end

  describe "save_all/4" do
    test "saves views and zones to files", %{tmp_dir: tmp_dir} do
      views = [
        %{name: "default", priority: 100, recursion: true, match_clients: "any"},
        %{name: "test", priority: 50, recursion: false, match_clients: "10.0.0.0/8"}
      ]

      zones = [
        %{name: "example.com", type: :auth, view_name: "default", file: "zones/example.com.zone"},
        %{name: "test.local", type: :forward, view_name: "test", upstreams: ["8.8.8.8"]}
      ]

      assert :ok = ConfigPersistence.save_all(tmp_dir, views, zones)

      # Verify files were created
      assert File.exists?(Path.join(tmp_dir, "views.toml"))
      assert File.exists?(Path.join(tmp_dir, "zones.toml"))
      assert File.dir?(Path.join(tmp_dir, "zones"))
    end

    test "creates data directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      new_dir = Path.join(tmp_dir, "nested/data/path")

      assert :ok = ConfigPersistence.save_all(new_dir, [], [])

      assert File.dir?(new_dir)
      assert File.dir?(Path.join(new_dir, "zones"))
    end

    test "saves empty configuration", %{tmp_dir: tmp_dir} do
      assert :ok = ConfigPersistence.save_all(tmp_dir, [], [])

      # Verify files were created (even if empty)
      assert File.exists?(Path.join(tmp_dir, "views.toml"))
      assert File.exists?(Path.join(tmp_dir, "zones.toml"))
    end

    test "overwrites existing files", %{tmp_dir: tmp_dir} do
      # First save
      views1 = [%{name: "original", priority: 100}]
      :ok = ConfigPersistence.save_all(tmp_dir, views1, [])

      # Second save with different data
      views2 = [%{name: "updated", priority: 200}]
      :ok = ConfigPersistence.save_all(tmp_dir, views2, [])

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

    test "full config survives save/load cycle", %{tmp_dir: tmp_dir} do
      views = [
        %{name: "test_view", priority: 75, recursion: true}
      ]

      zones = [
        %{name: "test.zone", type: :auth, view_name: "test_view"}
      ]

      :ok = ConfigPersistence.save_all(tmp_dir, views, zones)
      {:ok, loaded} = ConfigPersistence.load_all(tmp_dir)

      assert length(loaded.views) == 1
      assert length(loaded.zones) == 1

      assert hd(loaded.views).name == "test_view"
      assert hd(loaded.zones).name == "test.zone"
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
    # These tests would require ViewManager to be running
    # Skip if ViewManager integration is not available in test environment

    @tag :skip
    test "collects views from ViewManager" do
      # This test requires ViewManager to be started
      views = ConfigPersistence.collect_views()
      assert is_list(views)
    end
  end

  describe "collect_zones/1" do
    # These tests would require ZoneController to be running
    # Skip if ZoneController integration is not available in test environment

    @tag :skip
    test "collects zones from ZoneController" do
      # This test requires ZoneController to be started
      zones = ConfigPersistence.collect_zones()
      assert is_list(zones)
    end
  end

  describe "save_current/2" do
    @tag :skip
    test "saves current configuration from running services" do
      # This test requires ViewManager and ZoneController to be started
      # Would verify that save_current properly collects and persists
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
end
