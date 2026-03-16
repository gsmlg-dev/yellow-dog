defmodule YellowDog.Data.ResourceTest do
  use ExUnit.Case, async: false

  alias YellowDog.Data.Resource
  alias YellowDog.Data.Resource.{Hardware, Ownership, NetworkResource}

  setup do
    {:ok, _stores} = Resource.init_stores()
    :ok
  end

  # ── Hardware ──────────────────────────────────────────────────────

  describe "hardware CRUD" do
    test "create and retrieve hardware" do
      attrs = %{id: "srv-01", mac: "AA:BB:CC:DD:EE:FF", hostname: "web-1"}
      assert {:ok, hw} = Resource.create_hardware(attrs)
      assert hw.id == "srv-01"
      assert hw.mac == "AA:BB:CC:DD:EE:FF"

      assert {:ok, retrieved} = Resource.get_hardware("srv-01")
      assert retrieved.id == hw.id
    end

    test "create validates required fields" do
      assert {:error, "id is required"} = Resource.create_hardware(%{})
    end

    test "create validates MAC format" do
      assert {:error, _} = Resource.create_hardware(%{id: "x", mac: "invalid"})
    end

    test "update hardware" do
      assert {:ok, _} = Resource.create_hardware(%{id: "srv-02"})
      assert {:ok, updated} = Resource.update_hardware("srv-02", %{hostname: "db-1"})
      assert updated.hostname == "db-1"
    end

    test "update non-existent returns error" do
      assert {:error, :not_found} = Resource.update_hardware("nope", %{hostname: "x"})
    end

    test "delete hardware" do
      assert {:ok, _} = Resource.create_hardware(%{id: "srv-03"})
      assert :ok = Resource.delete_hardware("srv-03")
      assert {:error, :not_found} = Resource.get_hardware("srv-03")
    end

    test "list hardware" do
      assert {:ok, _} = Resource.create_hardware(%{id: "a1"})
      assert {:ok, _} = Resource.create_hardware(%{id: "a2"})
      list = Resource.list_hardware()
      ids = Enum.map(list, & &1.id)
      assert "a1" in ids
      assert "a2" in ids
    end
  end

  describe "hardware validation" do
    test "valid device types" do
      assert {:ok, hw} = Hardware.new(%{id: "x", device_type: "server"})
      assert hw.device_type == "server"
    end

    test "invalid device type" do
      assert {:error, "invalid device_type: " <> _} =
               Hardware.new(%{id: "x", device_type: "spaceship"})
    end

    test "valid status" do
      assert {:ok, hw} = Hardware.new(%{id: "x", status: "maintenance"})
      assert hw.status == "maintenance"
    end

    test "invalid status" do
      assert {:error, "invalid status: " <> _} = Hardware.new(%{id: "x", status: "broken"})
    end

    test "timestamps are set automatically" do
      assert {:ok, hw} = Hardware.new(%{id: "x"})
      assert %DateTime{} = hw.created_at
      assert %DateTime{} = hw.updated_at
    end
  end

  # ── Identity ──────────────────────────────────────────────────────

  describe "identity CRUD" do
    test "create and retrieve identity" do
      assert {:ok, identity} = Resource.create_identity(%{id: "alice", name: "Alice"})
      assert identity.id == "alice"
      assert identity.name == "Alice"

      assert {:ok, retrieved} = Resource.get_identity("alice")
      assert retrieved.name == "Alice"
    end

    test "create validates required fields" do
      assert {:error, "id is required"} = Resource.create_identity(%{name: "Bob"})
      assert {:error, "name is required"} = Resource.create_identity(%{id: "bob"})
    end

    test "create validates email format" do
      assert {:error, "invalid email format"} =
               Resource.create_identity(%{id: "x", name: "X", email: "not-an-email"})
    end

    test "update identity" do
      assert {:ok, _} = Resource.create_identity(%{id: "bob", name: "Bob"})
      assert {:ok, updated} = Resource.update_identity("bob", %{department: "Engineering"})
      assert updated.department == "Engineering"
    end

    test "delete identity" do
      assert {:ok, _} = Resource.create_identity(%{id: "carol", name: "Carol"})
      assert :ok = Resource.delete_identity("carol")
      assert {:error, :not_found} = Resource.get_identity("carol")
    end

    test "list identities" do
      assert {:ok, _} = Resource.create_identity(%{id: "d1", name: "D1"})
      assert {:ok, _} = Resource.create_identity(%{id: "d2", name: "D2"})
      list = Resource.list_identities()
      ids = Enum.map(list, & &1.id)
      assert "d1" in ids
      assert "d2" in ids
    end
  end

  # ── Ownership ─────────────────────────────────────────────────────

  describe "ownership links" do
    test "assign hardware to identity" do
      assert {:ok, _} = Resource.create_identity(%{id: "alice", name: "Alice"})
      assert {:ok, _} = Resource.create_hardware(%{id: "srv-10"})

      assert {:ok, link} = Resource.assign_hardware("alice", "srv-10")
      assert link.identity_id == "alice"
      assert link.hardware_id == "srv-10"
      assert link.id == "alice:srv-10"
    end

    test "list hardware for identity" do
      assert {:ok, _} = Resource.assign_hardware("user1", "hw1")
      assert {:ok, _} = Resource.assign_hardware("user1", "hw2")
      assert {:ok, _} = Resource.assign_hardware("user2", "hw3")

      links = Resource.list_hardware_for_identity("user1")
      hw_ids = Enum.map(links, & &1.hardware_id)
      assert length(hw_ids) == 2
      assert "hw1" in hw_ids
      assert "hw2" in hw_ids
    end

    test "list owners for hardware" do
      assert {:ok, _} = Resource.assign_hardware("owner1", "shared-hw")
      assert {:ok, _} = Resource.assign_hardware("owner2", "shared-hw", role: "user")

      owners = Resource.list_owners_for_hardware("shared-hw")
      assert length(owners) == 2
    end

    test "unassign hardware" do
      assert {:ok, _} = Resource.assign_hardware("alice", "srv-20")
      assert :ok = Resource.unassign_hardware("alice", "srv-20")

      links = Resource.list_hardware_for_identity("alice")
      assert links == []
    end

    test "assign validates required fields" do
      assert {:error, _} = Ownership.new(%{})
    end
  end

  # ── Network Resources ─────────────────────────────────────────────

  describe "network resource CRUD" do
    test "create and retrieve" do
      attrs = %{id: "ip-1", type: "ipv4", value: "192.168.1.100"}
      assert {:ok, resource} = Resource.create_network_resource(attrs)
      assert resource.id == "ip-1"
      assert resource.type == "ipv4"

      assert {:ok, retrieved} = Resource.get_network_resource("ip-1")
      assert retrieved.value == "192.168.1.100"
    end

    test "validates required fields" do
      assert {:error, "id is required"} = NetworkResource.new(%{type: "ipv4", value: "x"})
      assert {:error, "type is required"} = NetworkResource.new(%{id: "x", value: "x"})
      assert {:error, "value is required"} = NetworkResource.new(%{id: "x", type: "ipv4"})
    end

    test "validates type" do
      assert {:error, "invalid type: " <> _} =
               NetworkResource.new(%{id: "x", type: "invalid", value: "x"})
    end

    test "delete network resource" do
      assert {:ok, _} =
               Resource.create_network_resource(%{id: "ip-2", type: "ipv4", value: "10.0.0.1"})

      assert :ok = Resource.delete_network_resource("ip-2")
      assert {:error, :not_found} = Resource.get_network_resource("ip-2")
    end

    test "list by type" do
      assert {:ok, _} =
               Resource.create_network_resource(%{id: "v4-1", type: "ipv4", value: "10.0.0.1"})

      assert {:ok, _} =
               Resource.create_network_resource(%{id: "v6-1", type: "ipv6", value: "::1"})

      assert {:ok, _} =
               Resource.create_network_resource(%{
                 id: "dom-1",
                 type: "domain",
                 value: "example.com"
               })

      ipv4_only = Resource.list_network_resources(type: :ipv4)
      assert length(ipv4_only) == 1
      assert hd(ipv4_only).id == "v4-1"

      all = Resource.list_network_resources()
      assert length(all) == 3
    end

    test "list resources for hardware" do
      assert {:ok, _} =
               Resource.create_network_resource(%{
                 id: "hw-ip-1",
                 type: "ipv4",
                 value: "10.0.0.5",
                 hardware_id: "srv-50"
               })

      assert {:ok, _} =
               Resource.create_network_resource(%{
                 id: "hw-ip-2",
                 type: "ipv6",
                 value: "::5",
                 hardware_id: "srv-50"
               })

      resources = Resource.list_resources_for_hardware("srv-50")
      assert length(resources) == 2
    end
  end
end
