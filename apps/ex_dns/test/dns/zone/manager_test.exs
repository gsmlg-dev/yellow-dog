defmodule DNS.Zone.ManagerTest do
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Manager

  setup do
    DNS.Zone.Store.init()
    DNS.Zone.Store.clear()
    :ok
  end

  describe "zone management" do
    test "create_zone/3 creates a new zone" do
      assert {:ok, zone} = Manager.create_zone("example.com", :authoritative)
      assert zone.name.value == "example.com"
      assert zone.type == :authoritative
    end

    test "get_zone/1 retrieves a zone" do
      {:ok, zone} = Manager.create_zone("example.com", :authoritative)
      assert {:ok, ^zone} = Manager.get_zone("example.com")
    end

    test "list_zones/0 lists all zones" do
      Manager.create_zone("example.com", :authoritative)
      Manager.create_zone("test.com", :stub)

      zones = Manager.list_zones()
      assert length(zones) == 2
      assert Enum.map(zones, & &1.name.value) == ["example.com", "test.com"]
    end

    test "delete_zone/1 removes a zone" do
      Manager.create_zone("example.com", :authoritative)
      assert :ok = Manager.delete_zone("example.com")
      assert {:error, :not_found} = Manager.get_zone("example.com")
    end

    test "update_zone/2 updates zone configuration" do
      {:ok, _zone} = Manager.create_zone("example.com", :authoritative, ttl: 300)
      assert {:ok, updated_zone} = Manager.update_zone("example.com", ttl: 600)
      assert Keyword.get(updated_zone.options, :ttl) == 600
    end
  end

  describe "zone loading" do
    test "load_zone_from_string/2 loads zone from content" do
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
  end

  describe "zone validation" do
    test "validate_zone/1 returns ok for valid zones" do
      zone = Zone.new("example.com", :authoritative, ttl: 3600)
      assert {:ok, ^zone} = Manager.validate_zone(zone)
    end

    test "validate_zone/1 returns errors for invalid zones" do
      zone = Zone.new("", :invalid_type, ttl: -1)
      assert {:error, errors} = Manager.validate_zone(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Zone name"))
      assert Enum.any?(errors, &String.contains?(&1, "Invalid zone type"))
      assert Enum.any?(errors, &String.contains?(&1, "TTL must be"))
    end
  end
end
