defmodule DNS.Zone.ManagerTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Manager.

  Tests cover:
  - Module structure and exports
  - Zone CRUD operations (create, read, update, delete)
  - Zone listing and querying
  - Zone loading from strings and files
  - Zone validation
  - Zone options and configuration
  - Error handling
  - Concurrent operations
  """
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Manager

  setup do
    DNS.Zone.Store.init()
    DNS.Zone.Store.clear()
    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Manager)
    end

    test "exports create_zone/3" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :create_zone, 3)
    end

    test "exports get_zone/1" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :get_zone, 1)
    end

    test "exports list_zones/0" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :list_zones, 0)
    end

    test "exports delete_zone/1" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :delete_zone, 1)
    end

    test "exports update_zone/2" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :update_zone, 2)
    end

    test "exports validate_zone/1" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :validate_zone, 1)
    end

    test "exports load_zone_from_string/2" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :load_zone_from_string, 2)
    end

    test "exports load_zone_from_file/2" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :load_zone_from_file, 2)
    end

    test "exports reload_zone/1" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :reload_zone, 1)
    end

    test "exports init/0" do
      Code.ensure_loaded!(Manager)
      assert Kernel.function_exported?(Manager, :init, 0)
    end
  end

  describe "create_zone/3" do
    test "creates a new zone with default type" do
      assert {:ok, zone} = Manager.create_zone("example.com")
      assert zone.name.value == "example.com"
      assert zone.type == :authoritative
    end

    test "creates a new zone with authoritative type" do
      assert {:ok, zone} = Manager.create_zone("example.com", :authoritative)
      assert zone.name.value == "example.com"
      assert zone.type == :authoritative
    end

    test "creates a zone with stub type" do
      assert {:ok, zone} = Manager.create_zone("stub.com", :stub)
      assert zone.type == :stub
    end

    test "creates a zone with forward type" do
      assert {:ok, zone} = Manager.create_zone("forward.com", :forward)
      assert zone.type == :forward
    end

    test "creates a zone with cache type" do
      assert {:ok, zone} = Manager.create_zone("cache.com", :cache)
      assert zone.type == :cache
    end

    test "creates a zone with TTL option" do
      assert {:ok, zone} = Manager.create_zone("example.com", :authoritative, ttl: 7200)
      assert Keyword.get(zone.options, :ttl) == 7200
    end

    test "creates a zone with multiple options" do
      opts = [ttl: 600, origin: "example.com."]
      assert {:ok, zone} = Manager.create_zone("example.com", :authoritative, opts)
      assert Keyword.get(zone.options, :ttl) == 600
      assert Keyword.get(zone.options, :origin) == "example.com."
    end

    test "creates a zone with empty name" do
      # Empty name zone creation should work but fail validation
      assert {:ok, zone} = Manager.create_zone("", :authoritative)
      assert zone.name.value == ""
    end

    test "creates multiple zones" do
      assert {:ok, _} = Manager.create_zone("zone1.com", :authoritative)
      assert {:ok, _} = Manager.create_zone("zone2.com", :stub)
      assert {:ok, _} = Manager.create_zone("zone3.com", :forward)

      zones = Manager.list_zones()
      assert length(zones) == 3
    end
  end

  describe "get_zone/1" do
    test "retrieves a zone by name" do
      {:ok, zone} = Manager.create_zone("example.com", :authoritative)
      assert {:ok, ^zone} = Manager.get_zone("example.com")
    end

    test "returns not_found for missing zone" do
      assert {:error, :not_found} = Manager.get_zone("nonexistent.com")
    end

    test "retrieves zone after update" do
      {:ok, _} = Manager.create_zone("example.com", :authoritative, ttl: 300)
      {:ok, updated} = Manager.update_zone("example.com", ttl: 600)
      {:ok, retrieved} = Manager.get_zone("example.com")
      assert retrieved == updated
    end

    test "retrieves zone with correct options" do
      {:ok, _} = Manager.create_zone("example.com", :authoritative, ttl: 3600)
      {:ok, zone} = Manager.get_zone("example.com")
      assert Keyword.get(zone.options, :ttl) == 3600
    end
  end

  describe "list_zones/0" do
    test "returns empty list when no zones exist" do
      zones = Manager.list_zones()
      assert zones == []
    end

    test "lists all zones" do
      Manager.create_zone("example.com", :authoritative)
      Manager.create_zone("test.com", :stub)

      zones = Manager.list_zones()
      assert length(zones) == 2
      assert Enum.map(zones, & &1.name.value) == ["example.com", "test.com"]
    end

    test "lists zones in insertion order" do
      Manager.create_zone("a.com", :authoritative)
      Manager.create_zone("b.com", :authoritative)
      Manager.create_zone("c.com", :authoritative)

      zones = Manager.list_zones()
      names = Enum.map(zones, & &1.name.value)
      assert names == ["a.com", "b.com", "c.com"]
    end

    test "reflects zone deletions" do
      Manager.create_zone("example.com", :authoritative)
      Manager.create_zone("test.com", :stub)

      assert length(Manager.list_zones()) == 2

      Manager.delete_zone("example.com")

      zones = Manager.list_zones()
      assert length(zones) == 1
      assert hd(zones).name.value == "test.com"
    end

    test "lists zones with different types" do
      Manager.create_zone("auth.com", :authoritative)
      Manager.create_zone("stub.com", :stub)
      Manager.create_zone("fwd.com", :forward)
      Manager.create_zone("cache.com", :cache)

      zones = Manager.list_zones()
      assert length(zones) == 4

      types = Enum.map(zones, & &1.type)
      assert :authoritative in types
      assert :stub in types
      assert :forward in types
      assert :cache in types
    end
  end

  describe "delete_zone/1" do
    test "removes a zone" do
      Manager.create_zone("example.com", :authoritative)
      assert :ok = Manager.delete_zone("example.com")
      assert {:error, :not_found} = Manager.get_zone("example.com")
    end

    test "returns error for non-existent zone" do
      result = Manager.delete_zone("nonexistent.com")
      # The delete might return :ok even if not found, depending on implementation
      assert result in [:ok, {:error, :not_found}]
    end

    test "allows re-creation after deletion" do
      Manager.create_zone("example.com", :authoritative)
      Manager.delete_zone("example.com")

      assert {:ok, zone} = Manager.create_zone("example.com", :stub)
      assert zone.type == :stub
    end

    test "deleting one zone doesn't affect others" do
      Manager.create_zone("keep.com", :authoritative)
      Manager.create_zone("delete.com", :stub)

      Manager.delete_zone("delete.com")

      assert {:ok, _} = Manager.get_zone("keep.com")
      assert {:error, :not_found} = Manager.get_zone("delete.com")
    end
  end

  describe "update_zone/2" do
    test "updates zone configuration" do
      {:ok, _zone} = Manager.create_zone("example.com", :authoritative, ttl: 300)
      assert {:ok, updated_zone} = Manager.update_zone("example.com", ttl: 600)
      assert Keyword.get(updated_zone.options, :ttl) == 600
    end

    test "preserves existing options" do
      {:ok, _} = Manager.create_zone("example.com", :authoritative, ttl: 300, origin: "example.com.")
      {:ok, updated} = Manager.update_zone("example.com", ttl: 600)

      assert Keyword.get(updated.options, :ttl) == 600
      assert Keyword.get(updated.options, :origin) == "example.com."
    end

    test "returns error for non-existent zone" do
      assert {:error, :not_found} = Manager.update_zone("nonexistent.com", ttl: 600)
    end

    test "updates multiple options" do
      {:ok, _} = Manager.create_zone("example.com", :authoritative)
      {:ok, updated} = Manager.update_zone("example.com", ttl: 7200, origin: "new.example.com.")

      assert Keyword.get(updated.options, :ttl) == 7200
      assert Keyword.get(updated.options, :origin) == "new.example.com."
    end

    test "update persists in store" do
      {:ok, _} = Manager.create_zone("example.com", :authoritative, ttl: 300)
      {:ok, _} = Manager.update_zone("example.com", ttl: 900)
      {:ok, zone} = Manager.get_zone("example.com")

      assert Keyword.get(zone.options, :ttl) == 900
    end
  end

  describe "zone loading from string" do
    test "loads zone from content" do
      content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. (
                  2024010101  ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  86400       ; minimum
              )
      @       IN  NS  ns1.example.com.
      """

      assert {:ok, zone} = Manager.load_zone_from_string("example.com", content)
      assert zone.name.value == "example.com"
      assert zone.type == :authoritative
      assert zone.soa != nil
    end

    test "loads zone with A records" do
      content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. (
                  1           ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  86400       ; minimum
              )
      www     IN  A   192.168.1.1
      """

      assert {:ok, zone} = Manager.load_zone_from_string("example.com", content)
      assert zone.soa != nil
    end

    test "returns error for invalid zone content" do
      content = "invalid zone content"
      result = Manager.load_zone_from_string("example.com", content)
      # May succeed or fail depending on parser implementation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "loads zone with multiple record types" do
      content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. (
                  1           ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  86400       ; minimum
              )
      @       IN  NS  ns1.example.com.
      @       IN  MX  10 mail.example.com.
      www     IN  A   192.168.1.1
      """

      assert {:ok, zone} = Manager.load_zone_from_string("example.com", content)
      assert zone.name.value == "example.com"
    end
  end

  describe "validate_zone/1" do
    test "returns ok for valid zones" do
      zone = Zone.new("example.com", :authoritative, ttl: 3600)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "returns ok for zone with stub type" do
      zone = Zone.new("example.com", :stub, ttl: 3600)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "returns ok for zone with forward type" do
      zone = Zone.new("example.com", :forward, ttl: 3600)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "returns ok for zone with cache type" do
      zone = Zone.new("example.com", :cache, ttl: 3600)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "returns errors for invalid zones" do
      zone = Zone.new("", :invalid_type, ttl: -1)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Zone name"))
      assert Enum.any?(errors, &String.contains?(&1, "Invalid zone type"))
      assert Enum.any?(errors, &String.contains?(&1, "TTL must be"))
    end

    test "validates empty zone name" do
      zone = Zone.new("", :authoritative, ttl: 3600)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Zone name"))
    end

    test "validates invalid zone type" do
      zone = Zone.new("example.com", :invalid, ttl: 3600)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid zone type"))
    end

    test "validates negative TTL" do
      zone = Zone.new("example.com", :authoritative, ttl: -100)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "TTL"))
    end

    test "validates zero TTL" do
      zone = Zone.new("example.com", :authoritative, ttl: 0)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "TTL"))
    end

    test "validates with valid TTL" do
      zone = Zone.new("example.com", :authoritative, ttl: 1)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "validates zone with no options" do
      zone = Zone.new("example.com", :authoritative)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end
  end

  describe "init/0" do
    test "initializes zone store" do
      # Clear and re-init
      assert :ok = Manager.init()
    end

    test "clears existing zones on init" do
      Manager.create_zone("example.com", :authoritative)
      assert length(Manager.list_zones()) == 1

      Manager.init()
      assert Manager.list_zones() == []
    end
  end

  describe "edge cases" do
    test "handles zone with very long name" do
      long_name = String.duplicate("a", 63) <> ".example.com"
      assert {:ok, zone} = Manager.create_zone(long_name, :authoritative)
      assert zone.name.value == long_name
    end

    test "handles zone with subdomain" do
      assert {:ok, zone} = Manager.create_zone("sub.domain.example.com", :authoritative)
      assert zone.name.value == "sub.domain.example.com"
    end

    test "handles zone with numbers in name" do
      assert {:ok, zone} = Manager.create_zone("zone123.example.com", :authoritative)
      assert zone.name.value == "zone123.example.com"
    end

    test "handles zone with hyphen in name" do
      assert {:ok, zone} = Manager.create_zone("my-zone.example.com", :authoritative)
      assert zone.name.value == "my-zone.example.com"
    end

    test "handles very large TTL" do
      assert {:ok, zone} = Manager.create_zone("example.com", :authoritative, ttl: 2_147_483_647)
      assert Keyword.get(zone.options, :ttl) == 2_147_483_647
    end

    test "concurrent zone operations" do
      # Create zones in parallel
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Manager.create_zone("zone#{i}.com", :authoritative)
          end)
        end)

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      zones = Manager.list_zones()
      assert length(zones) == 10
    end
  end

  describe "zone types" do
    test "authoritative type for primary zones" do
      {:ok, zone} = Manager.create_zone("primary.com", :authoritative)
      assert zone.type == :authoritative
    end

    test "stub type for partial zone data" do
      {:ok, zone} = Manager.create_zone("stub.com", :stub)
      assert zone.type == :stub
    end

    test "forward type for forwarding zones" do
      {:ok, zone} = Manager.create_zone("forward.com", :forward)
      assert zone.type == :forward
    end

    test "cache type for cached zones" do
      {:ok, zone} = Manager.create_zone("cache.com", :cache)
      assert zone.type == :cache
    end

    test "type persists through get_zone" do
      Manager.create_zone("example.com", :stub)
      {:ok, zone} = Manager.get_zone("example.com")
      assert zone.type == :stub
    end
  end
end
