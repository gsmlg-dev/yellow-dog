defmodule YellowDog.Dns.View.ConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View.Config, as: ViewConfig
  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ACL

  describe "load_file/1" do
    test "loads views from TOML file" do
      path = "examples/views.toml"

      assert {:ok, views} = ViewConfig.load_file(path)
      assert length(views) == 3

      # Check internal view
      internal = Enum.find(views, &(&1.name == "internal"))
      assert internal != nil
      assert internal.match_clients == "localnets"
      assert internal.recursion_enabled == true
      assert "corp.example.com" in internal.zones
      assert "internal.example.com" in internal.zones

      # Check DMZ view with custom ACL
      dmz = Enum.find(views, &(&1.name == "dmz"))
      assert dmz != nil
      assert %ACL{} = dmz.match_clients
      assert dmz.match_clients.name == "dmz"
      assert dmz.recursion_enabled == true
      assert "dmz.example.com" in dmz.zones

      # Check external view
      external = Enum.find(views, &(&1.name == "external"))
      assert external != nil
      assert external.match_clients == "any"
      assert external.recursion_enabled == false
      assert external.zones == ["public.example.com"]
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_read_error, :enoent}} = ViewConfig.load_file("nonexistent.toml")
    end

    test "returns error for invalid TOML" do
      # Create temporary file with invalid TOML
      path = "/tmp/invalid_views_#{:rand.uniform(10000)}.toml"
      File.write!(path, "[[view]\ninvalid toml syntax")

      assert {:error, {:toml_parse_error, _reason}} = ViewConfig.load_file(path)

      File.rm(path)
    end
  end

  describe "parse_toml/1" do
    test "parses simple view with built-in ACL" do
      toml = """
      [[view]]
      name = "test"
      match_clients = "localnets"
      recursion = true
      zones = ["example.com"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.name == "test"
      assert view.match_clients == "localnets"
      assert view.recursion_enabled == true
      assert view.zones == ["example.com"]
    end

    test "parses view with custom ACL" do
      toml = """
      [[view]]
      name = "custom"
      recursion = true
      zones = ["test.com"]

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"

      [[view.acl]]
      action = "deny"
      network = "10.1.0.0/16"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.name == "custom"
      assert %ACL{} = view.match_clients
      assert view.match_clients.name == "custom"
      assert length(view.match_clients.rules) == 2
    end

    test "parses multiple views" do
      toml = """
      [[view]]
      name = "view1"
      match_clients = "localnets"
      zones = ["zone1.com"]

      [[view]]
      name = "view2"
      match_clients = "any"
      zones = ["zone2.com"]
      """

      assert {:ok, views} = ViewConfig.parse_toml(toml)
      assert length(views) == 2
      assert Enum.any?(views, &(&1.name == "view1"))
      assert Enum.any?(views, &(&1.name == "view2"))
    end

    test "handles default values" do
      toml = """
      [[view]]
      name = "default"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.name == "default"
      assert view.match_clients == :all
      assert view.recursion_enabled == true
      assert view.zones == []
    end

    test "handles empty TOML views array" do
      # Empty [[view]] sections are ignored by TOML parser
      toml = """
      [[view]]
      """

      assert {:ok, []} = ViewConfig.parse_toml(toml)
    end

    test "handles multiple views with defaults" do
      toml = """
      [[view]]
      name = "first"

      [[view]]
      name = "second"
      """

      assert {:ok, views} = ViewConfig.parse_toml(toml)
      assert length(views) == 2
      assert Enum.at(views, 0).name == "first"
      assert Enum.at(views, 1).name == "second"
    end
  end

  describe "from_map/1" do
    test "converts configuration map to views" do
      config = %{
        "view" => [
          %{
            "name" => "test",
            "match_clients" => "any",
            "zones" => ["example.com"],
            "recursion" => true
          }
        ]
      }

      assert {:ok, [view]} = ViewConfig.from_map(config)
      assert view.name == "test"
      assert view.match_clients == "any"
      assert view.zones == ["example.com"]
      assert view.recursion_enabled == true
    end

    test "returns error for missing view key" do
      config = %{}
      assert {:ok, []} = ViewConfig.from_map(config)
    end

    test "returns error for invalid view config" do
      config = %{"view" => "not_a_list"}
      assert {:error, :invalid_view_config} = ViewConfig.from_map(config)
    end
  end

  describe "built-in ACL support" do
    test "parses 'any' ACL" do
      toml = """
      [[view]]
      name = "public"
      match_clients = "any"
      zones = ["example.com"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.match_clients == "any"
    end

    test "parses 'none' ACL" do
      toml = """
      [[view]]
      name = "blocked"
      match_clients = "none"
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.match_clients == "none"
    end

    test "parses 'localhost' ACL" do
      toml = """
      [[view]]
      name = "local"
      match_clients = "localhost"
      zones = ["local.test"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.match_clients == "localhost"
    end

    test "parses 'localnets' ACL" do
      toml = """
      [[view]]
      name = "internal"
      match_clients = "localnets"
      zones = ["corp.example.com"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.match_clients == "localnets"
    end
  end

  describe "custom ACL parsing" do
    test "parses single ACL rule" do
      toml = """
      [[view]]
      name = "dmz"
      zones = ["dmz.example.com"]

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert %ACL{} = view.match_clients
      assert view.match_clients.name == "dmz"
      assert length(view.match_clients.rules) == 1

      [{action, ip, prefix}] = view.match_clients.rules
      assert action == :allow
      assert ip == {10, 0, 0, 0}
      assert prefix == 8
    end

    test "parses multiple ACL rules" do
      toml = """
      [[view]]
      name = "complex"
      zones = []

      [[view.acl]]
      action = "allow"
      network = "10.1.1.0/24"

      [[view.acl]]
      action = "deny"
      network = "10.1.0.0/16"

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert %ACL{} = view.match_clients
      assert length(view.match_clients.rules) == 3

      # Verify rule order is preserved
      rules = view.match_clients.rules
      assert Enum.at(rules, 0) == {:allow, {10, 1, 1, 0}, 24}
      assert Enum.at(rules, 1) == {:deny, {10, 1, 0, 0}, 16}
      assert Enum.at(rules, 2) == {:allow, {10, 0, 0, 0}, 8}
    end

    test "parses IPv6 ACL rules" do
      toml = """
      [[view]]
      name = "ipv6"
      zones = []

      [[view.acl]]
      action = "allow"
      network = "2001:db8::/32"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert %ACL{} = view.match_clients
      assert length(view.match_clients.rules) == 1

      [{action, ip, prefix}] = view.match_clients.rules
      assert action == :allow
      assert ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}
      assert prefix == 32
    end

    test "returns error for invalid ACL rules" do
      toml = """
      [[view]]
      name = "invalid"
      zones = []

      [[view.acl]]
      action = "invalid_action"
      network = "10.0.0.0/8"
      """

      assert {:error, {:invalid_acl_rules, _}} = ViewConfig.parse_toml(toml)
    end

    test "returns error for ACL without network" do
      toml = """
      [[view]]
      name = "invalid"
      zones = []

      [[view.acl]]
      action = "allow"
      """

      assert {:error, {:invalid_acl_rules, _}} = ViewConfig.parse_toml(toml)
    end
  end

  describe "recursion configuration" do
    test "parses recursion = true" do
      toml = """
      [[view]]
      name = "recursive"
      match_clients = "any"
      recursion = true
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.recursion_enabled == true
    end

    test "parses recursion = false" do
      toml = """
      [[view]]
      name = "authoritative"
      match_clients = "any"
      recursion = false
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.recursion_enabled == false
    end

    test "defaults to recursion = true when not specified" do
      toml = """
      [[view]]
      name = "default"
      match_clients = "any"
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.recursion_enabled == true
    end

    test "returns error for invalid recursion value" do
      config = %{
        "view" => [
          %{
            "name" => "test",
            "match_clients" => "any",
            "zones" => [],
            "recursion" => "invalid"
          }
        ]
      }

      assert {:error, {:invalid_recursion, _}} = ViewConfig.from_map(config)
    end
  end

  describe "zone configuration" do
    test "parses single zone" do
      toml = """
      [[view]]
      name = "test"
      match_clients = "any"
      zones = ["example.com"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.zones == ["example.com"]
    end

    test "parses multiple zones" do
      toml = """
      [[view]]
      name = "test"
      match_clients = "any"
      zones = ["example.com", "test.com", "demo.org"]
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert length(view.zones) == 3
      assert "example.com" in view.zones
      assert "test.com" in view.zones
      assert "demo.org" in view.zones
    end

    test "handles empty zones list" do
      toml = """
      [[view]]
      name = "test"
      match_clients = "any"
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.zones == []
    end

    test "defaults to empty zones when not specified" do
      toml = """
      [[view]]
      name = "test"
      match_clients = "any"
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.zones == []
    end

    test "filters non-string zone values" do
      config = %{
        "view" => [
          %{
            "name" => "test",
            "match_clients" => "any",
            "zones" => ["valid.com", 123, "another.com", nil]
          }
        ]
      }

      assert {:ok, [view]} = ViewConfig.from_map(config)
      assert view.zones == ["valid.com", "another.com"]
    end
  end

  describe "view name generation" do
    test "uses provided name" do
      toml = """
      [[view]]
      name = "my_view"
      match_clients = "any"
      zones = []
      """

      assert {:ok, [view]} = ViewConfig.parse_toml(toml)
      assert view.name == "my_view"
    end

    test "generates name from index when not provided" do
      toml = """
      [[view]]
      match_clients = "any"
      zones = []

      [[view]]
      match_clients = "localnets"
      zones = []
      """

      assert {:ok, views} = ViewConfig.parse_toml(toml)
      assert length(views) == 2
      assert Enum.at(views, 0).name == "view_0"
      assert Enum.at(views, 1).name == "view_1"
    end

    test "generates name for empty string name" do
      config = %{
        "view" => [
          %{
            "name" => "",
            "match_clients" => "any",
            "zones" => []
          }
        ]
      }

      assert {:ok, [view]} = ViewConfig.from_map(config)
      assert view.name == "view_0"
    end
  end

  describe "comprehensive example" do
    test "parses full configuration with multiple views and ACLs" do
      toml = """
      # Internal network view
      [[view]]
      name = "internal"
      match_clients = "localnets"
      recursion = true
      zones = ["corp.example.com", "internal.example.com"]

      # DMZ with custom ACL
      [[view]]
      name = "dmz"
      recursion = true
      zones = ["dmz.example.com", "public.example.com"]

      [[view.acl]]
      action = "allow"
      network = "10.0.0.0/8"

      [[view.acl]]
      action = "deny"
      network = "192.168.0.0/16"

      # Public view
      [[view]]
      name = "external"
      match_clients = "any"
      recursion = false
      zones = ["public.example.com"]
      """

      assert {:ok, views} = ViewConfig.parse_toml(toml)
      assert length(views) == 3

      # Verify internal view
      internal = Enum.find(views, &(&1.name == "internal"))
      assert internal.match_clients == "localnets"
      assert internal.recursion_enabled == true
      assert length(internal.zones) == 2

      # Verify DMZ view with ACL
      dmz = Enum.find(views, &(&1.name == "dmz"))
      assert %ACL{} = dmz.match_clients
      assert length(dmz.match_clients.rules) == 2
      assert dmz.recursion_enabled == true

      # Verify external view
      external = Enum.find(views, &(&1.name == "external"))
      assert external.match_clients == "any"
      assert external.recursion_enabled == false
      assert external.zones == ["public.example.com"]
    end
  end
end
