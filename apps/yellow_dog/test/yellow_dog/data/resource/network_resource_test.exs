defmodule YellowDog.Data.Resource.NetworkResourceTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Resource.NetworkResource
  alias YellowDog.Data.Collection

  describe "collection/0" do
    test "returns a Collection struct" do
      assert %Collection{name: :network_resources} = NetworkResource.collection()
    end

    test "key_field is :id" do
      assert NetworkResource.collection().key_field == :id
    end

    test "indexes include :type, :hardware_id, :pool_name, :status" do
      indexes = NetworkResource.collection().indexes
      assert :type in indexes
      assert :hardware_id in indexes
      assert :pool_name in indexes
      assert :status in indexes
    end
  end

  describe "new/1 — valid cases" do
    test "creates network resource with required fields" do
      assert {:ok, r} = NetworkResource.new(%{id: "ip-1", type: "ipv4", value: "192.168.1.100"})
      assert r.id == "ip-1"
      assert r.type == "ipv4"
      assert r.value == "192.168.1.100"
    end

    test "defaults source to 'manual'" do
      {:ok, r} = NetworkResource.new(%{id: "ip-1", type: "ipv4", value: "10.0.0.1"})
      assert r.source == "manual"
    end

    test "defaults status to 'allocated'" do
      {:ok, r} = NetworkResource.new(%{id: "ip-1", type: "ipv4", value: "10.0.0.1"})
      assert r.status == "allocated"
    end

    test "accepts string keys" do
      assert {:ok, r} =
               NetworkResource.new(%{"id" => "ip-2", "type" => "ipv6", "value" => "::1"})

      assert r.id == "ip-2"
      assert r.type == "ipv6"
    end

    test "accepts all valid types" do
      for type <- ~w(ipv4 ipv6 domain vlan subnet prefix) do
        assert {:ok, r} = NetworkResource.new(%{id: "r-#{type}", type: type, value: "v"})
        assert r.type == type
      end
    end

    test "accepts all valid sources" do
      for source <- ~w(dhcp static manual dns auto) do
        assert {:ok, r} =
                 NetworkResource.new(%{
                   id: "r-#{source}",
                   type: "ipv4",
                   value: "1.2.3.4",
                   source: source
                 })

        assert r.source == source
      end
    end

    test "accepts all valid statuses" do
      for status <- ~w(allocated available reserved deprecated) do
        assert {:ok, r} =
                 NetworkResource.new(%{
                   id: "r-#{status}",
                   type: "ipv4",
                   value: "1.2.3.4",
                   status: status
                 })

        assert r.status == status
      end
    end

    test "accepts optional hardware_id" do
      assert {:ok, r} =
               NetworkResource.new(%{
                 id: "ip-3",
                 type: "ipv4",
                 value: "10.0.0.1",
                 hardware_id: "hw-99"
               })

      assert r.hardware_id == "hw-99"
    end

    test "sets timestamps" do
      {:ok, r} = NetworkResource.new(%{id: "ip-ts", type: "vlan", value: "100"})
      assert %DateTime{} = r.created_at
      assert %DateTime{} = r.updated_at
    end

    test "defaults tags to empty list" do
      {:ok, r} = NetworkResource.new(%{id: "ip-tags", type: "ipv4", value: "1.2.3.4"})
      assert r.tags == []
    end
  end

  describe "new/1 — validation errors" do
    test "returns error when id is nil" do
      assert {:error, "id is required"} = NetworkResource.new(%{type: "ipv4", value: "1.2.3.4"})
    end

    test "returns error when id is empty" do
      assert {:error, "id is required"} =
               NetworkResource.new(%{id: "", type: "ipv4", value: "1.2.3.4"})
    end

    test "returns error when type is nil" do
      assert {:error, "type is required"} = NetworkResource.new(%{id: "ip-1", value: "1.2.3.4"})
    end

    test "returns error when type is empty" do
      assert {:error, "type is required"} =
               NetworkResource.new(%{id: "ip-1", type: "", value: "1.2.3.4"})
    end

    test "returns error for invalid type" do
      assert {:error, msg} =
               NetworkResource.new(%{id: "ip-1", type: "fqdn", value: "example.com"})

      assert msg =~ "invalid type"
    end

    test "returns error when value is nil" do
      assert {:error, "value is required"} = NetworkResource.new(%{id: "ip-1", type: "ipv4"})
    end

    test "returns error when value is empty" do
      assert {:error, "value is required"} =
               NetworkResource.new(%{id: "ip-1", type: "ipv4", value: ""})
    end

    test "returns error for invalid source" do
      assert {:error, msg} =
               NetworkResource.new(%{id: "ip-1", type: "ipv4", value: "1.2.3.4", source: "rogue"})

      assert msg =~ "invalid source"
    end

    test "returns error for invalid status" do
      assert {:error, msg} =
               NetworkResource.new(%{
                 id: "ip-1",
                 type: "ipv4",
                 value: "1.2.3.4",
                 status: "broken"
               })

      assert msg =~ "invalid status"
    end
  end
end
