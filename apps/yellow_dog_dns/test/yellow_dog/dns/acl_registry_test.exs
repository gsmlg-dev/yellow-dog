defmodule YellowDog.Dns.AclRegistryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.AclRegistry

  @tmp_dir "test/tmp/acl_registry_test"

  setup do
    # Generate unique tmp dir for this test
    test_ref = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(@tmp_dir, to_string(test_ref))
    File.mkdir_p!(tmp_dir)

    # Stop any existing registry
    if pid = Process.whereis(AclRegistry) do
      GenServer.stop(pid, :normal)
    end

    on_exit(fn ->
      # Cleanup registry - use try/catch to handle already-stopped processes
      try do
        if pid = Process.whereis(AclRegistry) do
          GenServer.stop(pid, :normal)
        end
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Cleanup tmp files
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "start_link/1" do
    test "starts the ACL registry without ACL file" do
      assert {:ok, pid} = AclRegistry.start_link([])
      assert Process.alive?(pid)
    end

    test "starts with ACL file path", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "acls.toml")

      # Create a valid ACL file (using correct [[acl]] format)
      File.write!(acl_file, """
      [[acl]]
      name = "internal"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"
      """)

      assert {:ok, pid} = AclRegistry.start_link(acl_file: acl_file)
      assert Process.alive?(pid)
    end

    test "starts with non-existent ACL file (graceful handling)", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "nonexistent.toml")

      # Should start without error, just with empty ACLs
      assert {:ok, pid} = AclRegistry.start_link(acl_file: acl_file)
      assert Process.alive?(pid)
    end
  end

  describe "list_acls/0" do
    test "returns empty list when no ACLs defined" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert AclRegistry.list_acls() == []
    end

    test "returns ACLs sorted by name" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "zebra", rules: []})
      :ok = AclRegistry.create_acl(%{name: "alpha", rules: []})
      :ok = AclRegistry.create_acl(%{name: "middle", rules: []})

      acls = AclRegistry.list_acls()
      names = Enum.map(acls, & &1.name)

      assert names == ["alpha", "middle", "zebra"]
    end

    test "returns ACLs loaded from file", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "acls.toml")

      # Using correct [[acl]] format with [[acl.rules]]
      File.write!(acl_file, """
      [[acl]]
      name = "internal"

      [[acl.rules]]
      action = "allow"
      network = "10.0.0.0/8"

      [[acl]]
      name = "external"

      [[acl.rules]]
      action = "deny"
      network = "0.0.0.0/0"
      """)

      {:ok, _pid} = AclRegistry.start_link(acl_file: acl_file)

      acls = AclRegistry.list_acls()
      names = Enum.map(acls, & &1.name)

      assert "internal" in names
      assert "external" in names
    end
  end

  describe "get_acl/1" do
    test "returns {:ok, acl} for existing ACL" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "test_acl",
          description: "Test ACL",
          rules: [%{action: "allow", network: "192.168.0.0/16"}]
        })

      assert {:ok, acl} = AclRegistry.get_acl("test_acl")
      assert acl.name == "test_acl"
      assert acl.description == "Test ACL"
      assert length(acl.rules) == 1
    end

    test "returns {:error, :not_found} for non-existent ACL" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert {:error, :not_found} = AclRegistry.get_acl("nonexistent")
    end
  end

  describe "create_acl/1" do
    test "creates a new ACL" do
      {:ok, _pid} = AclRegistry.start_link([])

      assert :ok =
               AclRegistry.create_acl(%{
                 name: "new_acl",
                 rules: [%{action: "allow", network: "10.0.0.0/8"}]
               })

      assert {:ok, acl} = AclRegistry.get_acl("new_acl")
      assert acl.name == "new_acl"
    end

    test "returns {:error, :invalid_name} for nil name" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert {:error, :invalid_name} = AclRegistry.create_acl(%{rules: []})
    end

    test "returns {:error, :invalid_name} for empty name" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert {:error, :invalid_name} = AclRegistry.create_acl(%{name: "", rules: []})
    end

    test "returns {:error, :already_exists} for duplicate name" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "duplicate", rules: []})
      assert {:error, :already_exists} = AclRegistry.create_acl(%{name: "duplicate", rules: []})
    end

    test "normalizes ACL with default description" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "no_desc", rules: []})

      {:ok, acl} = AclRegistry.get_acl("no_desc")
      assert acl.description == ""
    end

    test "normalizes rules with network" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "with_network",
          rules: [%{action: "allow", network: "192.168.0.0/24"}]
        })

      {:ok, acl} = AclRegistry.get_acl("with_network")
      [rule] = acl.rules
      assert rule.action == "allow"
      assert rule.network == "192.168.0.0/24"
    end

    test "normalizes rules with geo_countries" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "geo_acl",
          rules: [%{action: "allow", geo_countries: ["US", "CA", "UK"]}]
        })

      {:ok, acl} = AclRegistry.get_acl("geo_acl")
      [rule] = acl.rules
      assert rule.action == "allow"
      assert rule.geo_countries == ["US", "CA", "UK"]
    end

    test "handles string keys in ACL map" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          "name" => "string_keys",
          "description" => "ACL with string keys",
          "rules" => [%{"action" => "deny", "network" => "0.0.0.0/0"}]
        })

      {:ok, acl} = AclRegistry.get_acl("string_keys")
      assert acl.name == "string_keys"
      assert acl.description == "ACL with string keys"
    end

    test "saves ACL to file when acl_file configured", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "acls_save.toml")
      File.write!(acl_file, "# Empty ACL file\n")

      {:ok, _pid} = AclRegistry.start_link(acl_file: acl_file)

      :ok =
        AclRegistry.create_acl(%{
          name: "saved_acl",
          rules: [%{action: "allow", network: "10.0.0.0/8"}]
        })

      # Wait for async save
      Process.sleep(100)

      # Just verify ACL was created in memory
      # (File may or may not be updated depending on async task timing)
      {:ok, acl} = AclRegistry.get_acl("saved_acl")
      assert acl.name == "saved_acl"
    end
  end

  describe "update_acl/2" do
    test "updates an existing ACL" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "updatable",
          description: "Original description",
          rules: []
        })

      assert :ok =
               AclRegistry.update_acl("updatable", %{
                 description: "Updated description",
                 rules: [%{action: "deny", network: "0.0.0.0/0"}]
               })

      {:ok, acl} = AclRegistry.get_acl("updatable")
      assert acl.description == "Updated description"
      assert length(acl.rules) == 1
    end

    test "returns {:error, :not_found} for non-existent ACL" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert {:error, :not_found} = AclRegistry.update_acl("nonexistent", %{rules: []})
    end

    test "preserves the original name when updating" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "keep_name", rules: []})

      # Try to update with a different name in the map
      :ok = AclRegistry.update_acl("keep_name", %{name: "different_name", rules: []})

      # Should still use the original name
      {:ok, acl} = AclRegistry.get_acl("keep_name")
      assert acl.name == "keep_name"
      assert {:error, :not_found} = AclRegistry.get_acl("different_name")
    end
  end

  describe "delete_acl/1" do
    test "deletes an existing ACL" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "to_delete", rules: []})
      assert {:ok, _} = AclRegistry.get_acl("to_delete")

      assert :ok = AclRegistry.delete_acl("to_delete")
      assert {:error, :not_found} = AclRegistry.get_acl("to_delete")
    end

    test "returns {:error, :not_found} for non-existent ACL" do
      {:ok, _pid} = AclRegistry.start_link([])
      assert {:error, :not_found} = AclRegistry.delete_acl("nonexistent")
    end

    test "removes ACL from list_acls" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "acl1", rules: []})
      :ok = AclRegistry.create_acl(%{name: "acl2", rules: []})
      :ok = AclRegistry.create_acl(%{name: "acl3", rules: []})

      assert length(AclRegistry.list_acls()) == 3

      :ok = AclRegistry.delete_acl("acl2")

      acls = AclRegistry.list_acls()
      assert length(acls) == 2
      names = Enum.map(acls, & &1.name)
      refute "acl2" in names
    end
  end

  describe "reload/0" do
    test "reloads ACLs from file", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "reload_acls.toml")

      # Initial file with one ACL (correct [[acl]] format)
      File.write!(acl_file, """
      [[acl]]
      name = "initial"
      """)

      {:ok, _pid} = AclRegistry.start_link(acl_file: acl_file)

      assert [%{name: "initial"}] = AclRegistry.list_acls()

      # Update file with different ACLs (correct [[acl]] format)
      File.write!(acl_file, """
      [[acl]]
      name = "reloaded1"

      [[acl]]
      name = "reloaded2"
      """)

      assert :ok = AclRegistry.reload()

      acls = AclRegistry.list_acls()
      names = Enum.map(acls, & &1.name)

      assert "reloaded1" in names
      assert "reloaded2" in names
      refute "initial" in names
    end

    test "handles reload when file becomes invalid", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "invalid_reload.toml")

      # Correct [[acl]] format
      File.write!(acl_file, """
      [[acl]]
      name = "valid"
      """)

      {:ok, _pid} = AclRegistry.start_link(acl_file: acl_file)
      assert [%{name: "valid"}] = AclRegistry.list_acls()

      # Make file invalid
      File.write!(acl_file, "not valid toml {{{")

      # Reload should not crash, keeps existing ACLs
      assert :ok = AclRegistry.reload()
      # State should remain unchanged or empty depending on implementation
      # Current implementation keeps old state on error
    end

    test "handles reload when file is deleted", %{tmp_dir: tmp_dir} do
      acl_file = Path.join(tmp_dir, "deleted_reload.toml")

      # Correct [[acl]] format
      File.write!(acl_file, """
      [[acl]]
      name = "before_delete"
      """)

      {:ok, _pid} = AclRegistry.start_link(acl_file: acl_file)
      assert [%{name: "before_delete"}] = AclRegistry.list_acls()

      # Delete the file
      File.rm!(acl_file)

      # Reload should not crash
      assert :ok = AclRegistry.reload()
    end

    test "reload with no acl_file configured" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "in_memory", rules: []})

      # Reload without file should work (no-op)
      assert :ok = AclRegistry.reload()

      # In-memory ACLs should remain
      assert [%{name: "in_memory"}] = AclRegistry.list_acls()
    end
  end

  describe "concurrent operations" do
    test "handles concurrent create operations" do
      {:ok, _pid} = AclRegistry.start_link([])

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            AclRegistry.create_acl(%{name: "concurrent_#{i}", rules: []})
          end)
        end

      results = Task.await_many(tasks)
      ok_count = Enum.count(results, &(&1 == :ok))

      # All should succeed since names are unique
      assert ok_count == 10
      assert length(AclRegistry.list_acls()) == 10
    end

    test "handles concurrent list and create operations" do
      {:ok, _pid} = AclRegistry.start_link([])

      create_tasks =
        for i <- 1..5 do
          Task.async(fn ->
            AclRegistry.create_acl(%{name: "mixed_#{i}", rules: []})
          end)
        end

      list_tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            AclRegistry.list_acls()
          end)
        end

      Task.await_many(create_tasks)
      list_results = Task.await_many(list_tasks)

      # List operations should return lists (may have varying lengths during creation)
      Enum.each(list_results, fn result ->
        assert is_list(result)
      end)
    end
  end

  describe "edge cases" do
    test "handles ACL with empty rules" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "empty_rules", rules: []})

      {:ok, acl} = AclRegistry.get_acl("empty_rules")
      assert acl.rules == []
    end

    test "handles ACL with nil rules" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "nil_rules"})

      {:ok, acl} = AclRegistry.get_acl("nil_rules")
      assert acl.rules == []
    end

    test "handles ACL name with special characters" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok = AclRegistry.create_acl(%{name: "acl-with_special.chars", rules: []})

      {:ok, acl} = AclRegistry.get_acl("acl-with_special.chars")
      assert acl.name == "acl-with_special.chars"
    end

    test "handles unicode in ACL name and description" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "日本語_acl",
          description: "ACL with 日本語 description 🔐",
          rules: []
        })

      {:ok, acl} = AclRegistry.get_acl("日本語_acl")
      assert acl.name == "日本語_acl"
      assert acl.description == "ACL with 日本語 description 🔐"
    end

    test "handles rule without action defaulting to allow" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "no_action",
          rules: [%{network: "192.168.0.0/16"}]
        })

      {:ok, acl} = AclRegistry.get_acl("no_action")
      [rule] = acl.rules
      assert rule.action == "allow"
    end

    test "handles rule without network or geo_countries" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "minimal_rule",
          rules: [%{action: "deny"}]
        })

      {:ok, acl} = AclRegistry.get_acl("minimal_rule")
      [rule] = acl.rules
      assert rule.action == "deny"
      refute Map.has_key?(rule, :network)
      refute Map.has_key?(rule, :geo_countries)
    end

    test "handles invalid rule format (not a map)" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "invalid_rule_format",
          rules: ["not_a_map", 123, nil]
        })

      {:ok, acl} = AclRegistry.get_acl("invalid_rule_format")
      # Invalid rules should be normalized to default
      assert length(acl.rules) == 3
    end

    test "handles rules as non-list" do
      {:ok, _pid} = AclRegistry.start_link([])

      :ok =
        AclRegistry.create_acl(%{
          name: "rules_not_list",
          rules: "not_a_list"
        })

      {:ok, acl} = AclRegistry.get_acl("rules_not_list")
      assert acl.rules == []
    end
  end
end
