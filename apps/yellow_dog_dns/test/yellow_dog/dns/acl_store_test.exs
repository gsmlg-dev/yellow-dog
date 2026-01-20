defmodule YellowDog.Dns.AclStoreTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.AclStore.

  Tests cover:
  - TOML file loading and parsing
  - ACL configuration validation
  - ACL rule normalization
  - File saving with atomic writes
  - Network and geo rules
  - Error cases
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.AclStore

  @test_dir "test/tmp/acl_store_test"

  setup do
    # Create a unique test directory for each test
    test_path = Path.join(@test_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
    end)

    {:ok, test_path: test_path}
  end

  describe "load_acls/1" do
    test "loads ACL with network rules from valid TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "acls.toml")

      content = """
      [[acl]]
      name = "internal"
      description = "Internal network clients"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"

      [[acl.rules]]
      action = "allow"
      network = "192.168.0.0/16"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      assert length(acls) == 1
      [acl] = acls
      assert acl.name == "internal"
      assert acl.description == "Internal network clients"
      assert length(acl.rules) == 2

      [rule1, rule2] = acl.rules
      assert rule1.action == "allow"
      assert rule1.network == "10.0.0.0/8"
      assert rule2.network == "192.168.0.0/16"
    end

    test "loads ACL with geo rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "geo_acls.toml")

      content = """
      [[acl]]
      name = "north_america"
      description = "North American clients"

      [[acl.rules]]
      action = "allow"
      geo_countries = ["US", "CA", "MX"]
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      assert length(acls) == 1
      [acl] = acls
      assert acl.name == "north_america"
      assert length(acl.rules) == 1

      [rule] = acl.rules
      assert rule.action == "allow"
      assert rule.geo_countries == ["US", "CA", "MX"]
    end

    test "loads multiple ACLs", %{test_path: test_path} do
      file_path = Path.join(test_path, "multi_acls.toml")

      content = """
      [[acl]]
      name = "internal"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"

      [[acl]]
      name = "external"

      [[acl.rules]]
      action = "allow"
      network = "0.0.0.0/0"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      assert length(acls) == 2
      names = Enum.map(acls, & &1.name)
      assert "internal" in names
      assert "external" in names
    end

    test "loads ACL with deny rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "deny_acls.toml")

      content = """
      [[acl]]
      name = "blacklist"

      [[acl.rules]]
      action = "deny"
      network = "192.168.1.0/24"

      [[acl.rules]]
      action = "allow"
      network = "192.168.0.0/16"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      [acl] = acls
      [deny_rule, allow_rule] = acl.rules
      assert deny_rule.action == "deny"
      assert allow_rule.action == "allow"
    end

    test "returns empty list for non-existent file", %{test_path: test_path} do
      file_path = Path.join(test_path, "nonexistent.toml")

      {:ok, acls} = AclStore.load_acls(file_path)

      assert acls == []
    end

    test "returns error for invalid TOML", %{test_path: test_path} do
      file_path = Path.join(test_path, "invalid.toml")

      content = """
      [[acl]
      name = "broken"
      """

      File.write!(file_path, content)

      {:error, {:toml_parse_error, _reason}} = AclStore.load_acls(file_path)
    end

    test "skips ACLs without name", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_name.toml")

      content = """
      [[acl]]

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"

      [[acl]]
      name = "valid"

      [[acl.rules]]
      action = "allow"
      network = "192.168.0.0/16"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      # Only valid ACL should be loaded
      assert length(acls) == 1
      [acl] = acls
      assert acl.name == "valid"
    end

    test "handles ACL with empty rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "empty_rules.toml")

      content = """
      [[acl]]
      name = "empty"
      description = "No rules"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      [acl] = acls
      assert acl.name == "empty"
      assert acl.rules == []
    end

    test "handles mixed network and geo rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "mixed_rules.toml")

      content = """
      [[acl]]
      name = "mixed"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"

      [[acl.rules]]
      action = "allow"
      geo_countries = ["US", "CA"]

      [[acl.rules]]
      action = "deny"
      network = "0.0.0.0/0"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)

      [acl] = acls
      assert length(acl.rules) == 3

      [net_rule, geo_rule, deny_rule] = acl.rules
      assert Map.has_key?(net_rule, :network)
      assert Map.has_key?(geo_rule, :geo_countries)
      assert deny_rule.action == "deny"
    end
  end

  describe "save_acls/2" do
    test "saves ACLs to TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "output.toml")

      acls = [
        %{
          name: "test_acl",
          description: "Test ACL",
          rules: [
            %{action: "allow", network: "10.0.0.0/8"}
          ]
        }
      ]

      assert :ok = AclStore.save_acls(file_path, acls)
      assert File.exists?(file_path)

      # Verify content can be read back
      {:ok, loaded} = AclStore.load_acls(file_path)
      assert length(loaded) == 1
      [acl] = loaded
      assert acl.name == "test_acl"
    end

    test "saves ACLs with geo rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "geo_output.toml")

      acls = [
        %{
          name: "geo_acl",
          rules: [
            %{action: "allow", geo_countries: ["US", "CA", "MX"]}
          ]
        }
      ]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      [acl] = loaded
      [rule] = acl.rules
      assert rule.geo_countries == ["US", "CA", "MX"]
    end

    test "saves multiple ACLs", %{test_path: test_path} do
      file_path = Path.join(test_path, "multi_output.toml")

      acls = [
        %{name: "acl1", rules: [%{action: "allow", network: "10.0.0.0/8"}]},
        %{name: "acl2", rules: [%{action: "allow", network: "192.168.0.0/16"}]}
      ]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      assert length(loaded) == 2
    end

    test "creates parent directories if needed", %{test_path: test_path} do
      file_path = Path.join([test_path, "deep", "nested", "acls.toml"])

      acls = [%{name: "deep", rules: []}]

      assert :ok = AclStore.save_acls(file_path, acls)
      assert File.exists?(file_path)
    end

    test "saves ACL without description", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_desc.toml")

      acls = [
        %{
          name: "no_description",
          rules: [%{action: "allow", network: "10.0.0.0/8"}]
        }
      ]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      [acl] = loaded
      assert acl.name == "no_description"
      assert acl.description == nil
    end

    test "handles empty ACLs list", %{test_path: test_path} do
      file_path = Path.join(test_path, "empty.toml")

      assert :ok = AclStore.save_acls(file_path, [])
      {:ok, loaded} = AclStore.load_acls(file_path)
      assert loaded == []
    end
  end

  describe "round-trip persistence" do
    test "complex ACL survives save/load cycle", %{test_path: test_path} do
      file_path = Path.join(test_path, "roundtrip.toml")

      original_acls = [
        %{
          name: "complex",
          description: "Complex ACL with many rules",
          rules: [
            %{action: "allow", network: "10.0.0.0/8"},
            %{action: "allow", network: "172.16.0.0/12"},
            %{action: "allow", geo_countries: ["US", "CA", "MX"]},
            %{action: "deny", network: "0.0.0.0/0"}
          ]
        },
        %{
          name: "simple",
          rules: []
        }
      ]

      assert :ok = AclStore.save_acls(file_path, original_acls)
      {:ok, loaded} = AclStore.load_acls(file_path)

      assert length(loaded) == 2

      complex = Enum.find(loaded, &(&1.name == "complex"))
      assert complex.description == "Complex ACL with many rules"
      assert length(complex.rules) == 4

      simple = Enum.find(loaded, &(&1.name == "simple"))
      assert simple.rules == []
    end
  end

  describe "edge cases" do
    test "handles file with no acl sections", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_acls.toml")

      content = """
      # Configuration file with no ACLs
      [settings]
      debug = true
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)
      assert acls == []
    end

    test "handles single ACL (not array)", %{test_path: test_path} do
      file_path = Path.join(test_path, "single.toml")

      content = """
      [acl]
      name = "single"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)
      assert length(acls) == 1
      [acl] = acls
      assert acl.name == "single"
    end

    test "handles unicode in names and descriptions", %{test_path: test_path} do
      file_path = Path.join(test_path, "unicode.toml")

      acls = [
        %{
          name: "日本語-한국어-中文",
          description: "ACL with unicode characters 🌍",
          rules: []
        }
      ]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      [acl] = loaded
      assert acl.name == "日本語-한국어-中文"
      assert acl.description == "ACL with unicode characters 🌍"
    end

    test "handles quotes in strings", %{test_path: test_path} do
      file_path = Path.join(test_path, "quotes.toml")

      acls = [
        %{
          name: "acl with \"quotes\"",
          description: "Description with \"quotes\"",
          rules: []
        }
      ]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      [acl] = loaded
      assert acl.name == "acl with \"quotes\""
    end

    test "handles many rules", %{test_path: test_path} do
      file_path = Path.join(test_path, "many_rules.toml")

      rules = for i <- 1..50 do
        %{action: "allow", network: "10.#{rem(i, 256)}.0.0/16"}
      end

      acls = [%{name: "many_rules", rules: rules}]

      assert :ok = AclStore.save_acls(file_path, acls)

      {:ok, loaded} = AclStore.load_acls(file_path)
      [acl] = loaded
      assert length(acl.rules) == 50
    end

    test "handles single rule (not array)", %{test_path: test_path} do
      file_path = Path.join(test_path, "single_rule.toml")

      content = """
      [[acl]]
      name = "single_rule"

      [acl.rules]
      action = "allow"
      network = "10.0.0.0/8"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)
      [acl] = acls
      assert length(acl.rules) == 1
    end

    test "defaults action to allow if missing", %{test_path: test_path} do
      file_path = Path.join(test_path, "default_action.toml")

      content = """
      [[acl]]
      name = "default_action"

      [[acl.rules]]
      network = "10.0.0.0/8"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)
      [acl] = acls
      [rule] = acl.rules
      assert rule.action == "allow"
    end

    test "skips ACL with empty name", %{test_path: test_path} do
      file_path = Path.join(test_path, "empty_name.toml")

      content = """
      [[acl]]
      name = ""

      [[acl]]
      name = "valid"
      """

      File.write!(file_path, content)

      {:ok, acls} = AclStore.load_acls(file_path)
      assert length(acls) == 1
      [acl] = acls
      assert acl.name == "valid"
    end
  end
end
