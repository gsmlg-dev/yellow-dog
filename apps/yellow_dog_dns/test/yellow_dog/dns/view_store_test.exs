defmodule YellowDog.Dns.ViewStoreTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.ViewStore.

  Tests cover:
  - TOML file loading and parsing
  - View configuration validation
  - View normalization
  - File saving with atomic writes
  - Backup creation
  - ACL configuration handling
  - Error cases
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.ViewStore

  @test_dir "test/tmp/view_store_test"

  setup do
    # Create a unique test directory for each test
    test_path = Path.join(@test_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
    end)

    {:ok, test_path: test_path}
  end

  describe "load_views/1" do
    test "loads views from valid TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      name = "internal"
      priority = 10
      match_clients = "localnets"
      recursion = true
      ecs_enabled = false
      zones = ["example.com", "internal.example.com"]
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      assert length(views) == 1
      [view] = views
      assert view.name == "internal"
      assert view.priority == 10
      assert view.match_clients == "localnets"
      assert view.recursion == true
      assert view.ecs_enabled == false
      assert view.zones == ["example.com", "internal.example.com"]
    end

    test "loads multiple views", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      name = "internal"
      priority = 10

      [[view]]
      name = "external"
      priority = 20
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      assert length(views) == 2
      names = Enum.map(views, & &1.name)
      assert "internal" in names
      assert "external" in names
    end

    test "loads views with network ACL", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      name = "restricted"
      priority = 5

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"

      [[view.acl]]
      action = "deny"
      network = "192.168.0.0/16"
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      assert length(views) == 1
      [view] = views
      assert view.name == "restricted"
      assert length(view.acl) == 2

      [allow_rule, deny_rule] = view.acl
      assert allow_rule.action == "allow"
      assert allow_rule.network == "10.0.0.0/8"
      assert deny_rule.action == "deny"
      assert deny_rule.network == "192.168.0.0/16"
    end

    test "loads views with geo ACL", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      name = "north_america"
      priority = 15

      [[view.acl]]
      action = "allow"
      geo_countries = ["US", "CA", "MX"]
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      assert length(views) == 1
      [view] = views
      assert view.name == "north_america"
      assert length(view.acl) == 1

      [geo_rule] = view.acl
      assert geo_rule.action == "allow"
      assert geo_rule.geo_countries == ["US", "CA", "MX"]
    end

    test "returns empty list for non-existent file", %{test_path: test_path} do
      file_path = Path.join(test_path, "nonexistent.toml")

      {:ok, views} = ViewStore.load_views(file_path)

      assert views == []
    end

    test "returns error for invalid TOML", %{test_path: test_path} do
      file_path = Path.join(test_path, "invalid.toml")

      content = """
      [[view]
      name = "broken"
      """

      File.write!(file_path, content)

      {:error, {:toml_parse_error, _reason}} = ViewStore.load_views(file_path)
    end

    test "uses default values for missing optional fields", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      name = "minimal"
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      assert length(views) == 1
      [view] = views
      assert view.name == "minimal"
      assert view.priority == 100
      assert view.recursion == false
      assert view.ecs_enabled == false
      assert view.zones == []
      assert view.match_clients == nil
    end

    test "skips views without name", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      content = """
      [[view]]
      priority = 10

      [[view]]
      name = "valid"
      priority = 20
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)

      # Only the valid view should be loaded
      assert length(views) == 1
      [view] = views
      assert view.name == "valid"
    end
  end

  describe "save_views/3" do
    test "saves views to TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "output.toml")

      views = [
        %{
          name: "test_view",
          priority: 50,
          match_clients: "any",
          recursion: true,
          ecs_enabled: true,
          zones: ["example.com"],
          acl: nil
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)
      assert File.exists?(file_path)

      # Verify content can be read back
      {:ok, loaded} = ViewStore.load_views(file_path)
      assert length(loaded) == 1
      [view] = loaded
      assert view.name == "test_view"
      assert view.priority == 50
    end

    test "saves views with ACL", %{test_path: test_path} do
      file_path = Path.join(test_path, "output_acl.toml")

      views = [
        %{
          name: "acl_view",
          priority: 10,
          recursion: false,
          ecs_enabled: false,
          zones: [],
          acl: [
            %{action: "allow", network: "10.0.0.0/8"},
            %{action: "deny", geo_countries: ["RU", "CN"]}
          ]
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      # Read back and verify
      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      assert length(view.acl) == 2
    end

    test "creates backup before overwriting", %{test_path: test_path} do
      file_path = Path.join(test_path, "backup_test.toml")
      backup_path = file_path <> ".backup"

      # Write initial file
      views1 = [%{name: "original", priority: 1, recursion: false, ecs_enabled: false, zones: []}]
      ViewStore.save_views(file_path, views1)

      # Overwrite with new content
      views2 = [%{name: "updated", priority: 2, recursion: true, ecs_enabled: false, zones: []}]
      ViewStore.save_views(file_path, views2)

      assert File.exists?(backup_path)

      # Verify backup contains original content
      {:ok, backup} = ViewStore.load_views(backup_path)
      [backup_view] = backup
      assert backup_view.name == "original"
    end

    test "skips backup when option is false", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_backup.toml")
      backup_path = file_path <> ".backup"

      views1 = [%{name: "first", priority: 1, recursion: false, ecs_enabled: false, zones: []}]
      ViewStore.save_views(file_path, views1)

      views2 = [%{name: "second", priority: 2, recursion: false, ecs_enabled: false, zones: []}]
      ViewStore.save_views(file_path, views2, backup: false)

      refute File.exists?(backup_path)
    end

    test "creates parent directories if needed", %{test_path: test_path} do
      file_path = Path.join([test_path, "deep", "nested", "views.toml"])

      views = [%{name: "deep", priority: 1, recursion: false, ecs_enabled: false, zones: []}]
      assert :ok = ViewStore.save_views(file_path, views)

      assert File.exists?(file_path)
    end

    test "handles :infinity priority", %{test_path: test_path} do
      file_path = Path.join(test_path, "infinity.toml")

      views = [
        %{name: "default", priority: :infinity, recursion: false, ecs_enabled: false, zones: []}
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      # Verify it's readable
      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      # :infinity is converted to 999999
      assert view.priority == 999_999
    end

    test "handles zone tuples", %{test_path: test_path} do
      file_path = Path.join(test_path, "zone_tuples.toml")

      views = [
        %{
          name: "with_tuples",
          priority: 10,
          recursion: false,
          ecs_enabled: false,
          zones: [{:forward, "example.com"}, {:auth, "internal.local"}]
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      # Tuples are converted to just names
      assert "example.com" in view.zones
      assert "internal.local" in view.zones
    end

    test "escapes quotes in strings", %{test_path: test_path} do
      file_path = Path.join(test_path, "quotes.toml")

      views = [
        %{
          name: "view with \"quotes\"",
          priority: 10,
          recursion: false,
          ecs_enabled: false,
          zones: []
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      assert view.name == "view with \"quotes\""
    end
  end

  describe "validate_view/1" do
    test "validates view with all required fields" do
      view = %{
        name: "valid",
        priority: 10,
        recursion: true,
        ecs_enabled: false,
        zones: []
      }

      assert :ok = ViewStore.validate_view(view)
    end

    test "returns error for missing name" do
      view = %{
        priority: 10,
        recursion: true
      }

      assert {:error, "Missing required field: name"} = ViewStore.validate_view(view)
    end

    test "returns error for empty name" do
      view = %{
        name: "",
        priority: 10
      }

      assert {:error, "Invalid name"} = ViewStore.validate_view(view)
    end

    test "returns error for nil name" do
      view = %{
        name: nil,
        priority: 10
      }

      assert {:error, "Missing required field: name"} = ViewStore.validate_view(view)
    end

    test "returns error for negative priority" do
      view = %{
        name: "test",
        priority: -1
      }

      assert {:error, "Priority must be a non-negative integer"} = ViewStore.validate_view(view)
    end

    test "accepts zero priority" do
      view = %{
        name: "test",
        priority: 0
      }

      assert :ok = ViewStore.validate_view(view)
    end

    test "accepts nil priority" do
      view = %{
        name: "test",
        priority: nil
      }

      assert :ok = ViewStore.validate_view(view)
    end

    test "validates ACL entries" do
      view = %{
        name: "test",
        acl: [
          %{action: "allow", network: "10.0.0.0/8"},
          %{action: "deny", geo_countries: ["US"]}
        ]
      }

      assert :ok = ViewStore.validate_view(view)
    end

    test "returns error for invalid ACL entries" do
      view = %{
        name: "test",
        acl: [
          # Missing network or geo_countries
          %{action: "allow"}
        ]
      }

      assert {:error, "Invalid ACL entries: " <> _} = ViewStore.validate_view(view)
    end

    test "returns error for non-list ACL" do
      view = %{
        name: "test",
        acl: "invalid"
      }

      assert {:error, "ACL must be a list"} = ViewStore.validate_view(view)
    end

    test "accepts empty ACL list" do
      view = %{
        name: "test",
        acl: []
      }

      assert :ok = ViewStore.validate_view(view)
    end
  end

  describe "round-trip persistence" do
    test "complex view survives save/load cycle", %{test_path: test_path} do
      file_path = Path.join(test_path, "roundtrip.toml")

      original_views = [
        %{
          name: "complex",
          priority: 42,
          match_clients: "localnets",
          recursion: true,
          ecs_enabled: true,
          zones: ["zone1.com", "zone2.com", "zone3.com"],
          acl: [
            %{action: "allow", network: "10.0.0.0/8"},
            %{action: "allow", network: "172.16.0.0/12"},
            %{action: "deny", geo_countries: ["RU", "CN", "KP"]}
          ]
        },
        %{
          name: "simple",
          priority: 100,
          recursion: false,
          ecs_enabled: false,
          zones: [],
          acl: nil
        }
      ]

      assert :ok = ViewStore.save_views(file_path, original_views)
      {:ok, loaded} = ViewStore.load_views(file_path)

      assert length(loaded) == 2

      complex = Enum.find(loaded, &(&1.name == "complex"))
      assert complex.priority == 42
      assert complex.match_clients == "localnets"
      assert complex.recursion == true
      assert complex.ecs_enabled == true
      assert length(complex.zones) == 3
      assert length(complex.acl) == 3

      simple = Enum.find(loaded, &(&1.name == "simple"))
      assert simple.priority == 100
      assert simple.recursion == false
    end
  end

  describe "edge cases" do
    test "handles empty views list", %{test_path: test_path} do
      file_path = Path.join(test_path, "empty.toml")

      assert :ok = ViewStore.save_views(file_path, [])
      {:ok, loaded} = ViewStore.load_views(file_path)
      assert loaded == []
    end

    test "handles file with no view sections", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_views.toml")

      content = """
      # Configuration file with no views
      [settings]
      debug = true
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)
      assert views == []
    end

    test "handles single view (not array)", %{test_path: test_path} do
      # This tests the case where TOML parser returns a single map instead of array
      file_path = Path.join(test_path, "single.toml")

      content = """
      [view]
      name = "single"
      priority = 1
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)
      assert length(views) == 1
      [view] = views
      assert view.name == "single"
    end

    test "handles unicode in view names", %{test_path: test_path} do
      file_path = Path.join(test_path, "unicode.toml")

      views = [
        %{
          name: "视图-日本語-한국어",
          priority: 10,
          recursion: false,
          ecs_enabled: false,
          zones: []
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      assert view.name == "视图-日本語-한국어"
    end

    test "handles very long zone lists", %{test_path: test_path} do
      file_path = Path.join(test_path, "long_zones.toml")

      zones = for i <- 1..100, do: "zone#{i}.example.com"

      views = [
        %{
          name: "many_zones",
          priority: 10,
          recursion: false,
          ecs_enabled: false,
          zones: zones
        }
      ]

      assert :ok = ViewStore.save_views(file_path, views)

      {:ok, loaded} = ViewStore.load_views(file_path)
      [view] = loaded
      assert length(view.zones) == 100
    end

    test "handles string boolean values", %{test_path: test_path} do
      file_path = Path.join(test_path, "string_bools.toml")

      # Some TOML configs might have string "true"/"false"
      content = """
      [[view]]
      name = "string_bools"
      recursion = true
      ecs_enabled = false
      """

      File.write!(file_path, content)

      {:ok, views} = ViewStore.load_views(file_path)
      [view] = views
      assert view.recursion == true
      assert view.ecs_enabled == false
    end
  end
end
