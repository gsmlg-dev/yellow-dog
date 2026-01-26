defmodule DNS.Zone.StoreTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Store module.

  Tests cover:
  - Module structure and exports
  - init/0 - store initialization
  - put_zone/1 - zone storage
  - get_zone/1 - zone retrieval
  - list_zones/0 - zone listing
  - delete_zone/1 - zone deletion
  - zone_exists?/1 - zone existence check
  - get_zones_by_type/1 - type-based filtering
  - clear/0 - clearing all zones
  - Normalization and edge cases
  """
  use ExUnit.Case, async: false

  alias DNS.Zone
  alias DNS.Zone.Store
  alias DNS.Zone.Name

  setup do
    # Clear the store before each test
    Store.clear()
    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Store)
    end

    test "exports init/0" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :init, 0)
    end

    test "exports ensure_initialized/0" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :ensure_initialized, 0)
    end

    test "exports put_zone/1" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :put_zone, 1)
    end

    test "exports get_zone/1" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :get_zone, 1)
    end

    test "exports list_zones/0" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :list_zones, 0)
    end

    test "exports delete_zone/1" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :delete_zone, 1)
    end

    test "exports zone_exists?/1" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :zone_exists?, 1)
    end

    test "exports get_zones_by_type/1" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :get_zones_by_type, 1)
    end

    test "exports clear/0" do
      Code.ensure_loaded!(Store)
      assert Kernel.function_exported?(Store, :clear, 0)
    end
  end

  describe "init/0" do
    test "returns :ok" do
      result = Store.init()
      assert result == :ok
    end

    test "can be called multiple times safely" do
      assert Store.init() == :ok
      assert Store.init() == :ok
      assert Store.init() == :ok
    end

    test "creates ETS table" do
      Store.init()
      # Verify table exists by performing an operation
      assert Store.list_zones() == []
    end
  end

  describe "ensure_initialized/0" do
    test "returns :ok" do
      result = Store.ensure_initialized()
      assert result == :ok
    end

    test "initializes the store if not already initialized" do
      Store.ensure_initialized()
      # Should be able to use store operations
      assert Store.list_zones() == []
    end
  end

  describe "put_zone/1" do
    test "stores a zone and returns {:ok, zone}" do
      zone = create_test_zone("example.com.")

      result = Store.put_zone(zone)

      assert {:ok, ^zone} = result
    end

    test "zone can be retrieved after storage" do
      zone = create_test_zone("test.org.")
      Store.put_zone(zone)

      {:ok, retrieved} = Store.get_zone("test.org.")

      assert retrieved == zone
    end

    test "overwrites existing zone with same name" do
      zone1 = create_test_zone("example.com.", :primary)
      zone2 = create_test_zone("example.com.", :secondary)

      Store.put_zone(zone1)
      Store.put_zone(zone2)

      {:ok, retrieved} = Store.get_zone("example.com.")
      assert retrieved.type == :secondary
    end

    test "stores multiple zones" do
      zone1 = create_test_zone("one.com.")
      zone2 = create_test_zone("two.com.")
      zone3 = create_test_zone("three.com.")

      Store.put_zone(zone1)
      Store.put_zone(zone2)
      Store.put_zone(zone3)

      zones = Store.list_zones()
      assert length(zones) == 3
    end
  end

  describe "get_zone/1 - string name" do
    test "retrieves existing zone" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      result = Store.get_zone("example.com.")

      assert {:ok, ^zone} = result
    end

    test "returns {:error, :not_found} for non-existent zone" do
      result = Store.get_zone("nonexistent.com.")

      assert result == {:error, :not_found}
    end

    test "normalizes name to lowercase" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      # Should find regardless of case
      {:ok, _} = Store.get_zone("EXAMPLE.COM.")
      {:ok, _} = Store.get_zone("Example.Com.")
      {:ok, _} = Store.get_zone("example.com.")
    end
  end

  describe "get_zone/1 - Name struct" do
    test "retrieves zone using Name struct" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      name = %Name{value: "example.com."}
      result = Store.get_zone(name)

      assert {:ok, ^zone} = result
    end

    test "normalizes Name struct to lowercase" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      name = %Name{value: "EXAMPLE.COM."}
      {:ok, _} = Store.get_zone(name)
    end
  end

  describe "list_zones/0" do
    test "returns empty list when no zones stored" do
      result = Store.list_zones()

      assert result == []
    end

    test "returns all stored zones" do
      Store.put_zone(create_test_zone("a.com."))
      Store.put_zone(create_test_zone("b.com."))

      zones = Store.list_zones()

      assert length(zones) == 2
    end

    test "zones are sorted by name" do
      Store.put_zone(create_test_zone("zebra.com."))
      Store.put_zone(create_test_zone("alpha.com."))
      Store.put_zone(create_test_zone("middle.com."))

      zones = Store.list_zones()
      names = Enum.map(zones, & &1.name.value)

      assert names == ["alpha.com.", "middle.com.", "zebra.com."]
    end
  end

  describe "delete_zone/1 - string name" do
    test "returns :ok" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      result = Store.delete_zone("example.com.")

      assert result == :ok
    end

    test "removes zone from store" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      Store.delete_zone("example.com.")

      assert Store.get_zone("example.com.") == {:error, :not_found}
    end

    test "returns :ok for non-existent zone" do
      result = Store.delete_zone("nonexistent.com.")

      assert result == :ok
    end

    test "normalizes name to lowercase" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      Store.delete_zone("EXAMPLE.COM.")

      assert Store.get_zone("example.com.") == {:error, :not_found}
    end
  end

  describe "delete_zone/1 - Name struct" do
    test "removes zone using Name struct" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      name = %Name{value: "example.com."}
      Store.delete_zone(name)

      assert Store.get_zone("example.com.") == {:error, :not_found}
    end
  end

  describe "zone_exists?/1 - string name" do
    test "returns true for existing zone" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      result = Store.zone_exists?("example.com.")

      assert result == true
    end

    test "returns false for non-existent zone" do
      result = Store.zone_exists?("nonexistent.com.")

      assert result == false
    end

    test "normalizes name to lowercase" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      assert Store.zone_exists?("EXAMPLE.COM.") == true
      assert Store.zone_exists?("Example.Com.") == true
    end
  end

  describe "zone_exists?/1 - Name struct" do
    test "checks existence using Name struct" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      name = %Name{value: "example.com."}
      assert Store.zone_exists?(name) == true

      name2 = %Name{value: "nonexistent.com."}
      assert Store.zone_exists?(name2) == false
    end
  end

  describe "get_zones_by_type/1" do
    test "returns zones of specified type" do
      Store.put_zone(create_test_zone("primary1.com.", :primary))
      Store.put_zone(create_test_zone("primary2.com.", :primary))
      Store.put_zone(create_test_zone("secondary1.com.", :secondary))

      primary_zones = Store.get_zones_by_type(:primary)

      assert length(primary_zones) == 2
      assert Enum.all?(primary_zones, &(&1.type == :primary))
    end

    test "returns empty list when no zones of type exist" do
      Store.put_zone(create_test_zone("primary.com.", :primary))

      result = Store.get_zones_by_type(:secondary)

      assert result == []
    end

    test "returns empty list when store is empty" do
      result = Store.get_zones_by_type(:primary)

      assert result == []
    end

    test "filters by forward type" do
      Store.put_zone(create_test_zone("forward.com.", :forward))
      Store.put_zone(create_test_zone("primary.com.", :primary))

      forward_zones = Store.get_zones_by_type(:forward)

      assert length(forward_zones) == 1
      assert hd(forward_zones).type == :forward
    end
  end

  describe "clear/0" do
    test "returns :ok" do
      result = Store.clear()

      assert result == :ok
    end

    test "removes all zones" do
      Store.put_zone(create_test_zone("one.com."))
      Store.put_zone(create_test_zone("two.com."))
      Store.put_zone(create_test_zone("three.com."))

      Store.clear()

      assert Store.list_zones() == []
    end

    test "can be called on empty store" do
      result = Store.clear()

      assert result == :ok
      assert Store.list_zones() == []
    end
  end

  describe "case normalization" do
    test "keys are case-insensitive" do
      zone = create_test_zone("Example.COM.")
      Store.put_zone(zone)

      # All variations should work
      assert {:ok, _} = Store.get_zone("example.com.")
      assert {:ok, _} = Store.get_zone("EXAMPLE.COM.")
      assert {:ok, _} = Store.get_zone("Example.Com.")
    end

    test "same zone stored once regardless of case" do
      Store.put_zone(create_test_zone("EXAMPLE.COM."))
      Store.put_zone(create_test_zone("example.com."))

      zones = Store.list_zones()
      assert length(zones) == 1
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads" do
      zone = create_test_zone("example.com.")
      Store.put_zone(zone)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Store.get_zone("example.com.")
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, fn {:ok, z} -> z == zone end)
    end

    test "handles concurrent writes" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            zone = create_test_zone("zone#{i}.com.")
            Store.put_zone(zone)
          end)
        end

      Task.await_many(tasks)

      zones = Store.list_zones()
      assert length(zones) == 10
    end
  end

  # Helper function to create test zones
  defp create_test_zone(name, type \\ :primary) do
    %Zone{
      name: %Name{value: name},
      type: type,
      records: []
    }
  end
end
