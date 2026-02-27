defmodule YellowDog.Data.Resource.HardwareTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Resource.Hardware
  alias YellowDog.Data.Collection

  describe "collection/0" do
    test "returns a Collection struct" do
      assert %Collection{name: :hw_inventory} = Hardware.collection()
    end

    test "key_field is :id" do
      assert Hardware.collection().key_field == :id
    end

    test "indexes include :mac, :hostname, :device_type, :status" do
      indexes = Hardware.collection().indexes
      assert :mac in indexes
      assert :hostname in indexes
      assert :device_type in indexes
      assert :status in indexes
    end
  end

  describe "new/1 — valid cases" do
    test "creates hardware with minimal required fields" do
      assert {:ok, hw} = Hardware.new(%{id: "srv-01"})
      assert hw.id == "srv-01"
    end

    test "sets default device_type to 'other'" do
      {:ok, hw} = Hardware.new(%{id: "srv-01"})
      assert hw.device_type == "other"
    end

    test "sets default status to 'active'" do
      {:ok, hw} = Hardware.new(%{id: "srv-01"})
      assert hw.status == "active"
    end

    test "accepts string keys" do
      assert {:ok, hw} = Hardware.new(%{"id" => "srv-02", "hostname" => "web-1"})
      assert hw.id == "srv-02"
      assert hw.hostname == "web-1"
    end

    test "accepts valid MAC with colons" do
      assert {:ok, hw} = Hardware.new(%{id: "srv-03", mac: "AA:BB:CC:DD:EE:FF"})
      assert hw.mac == "AA:BB:CC:DD:EE:FF"
    end

    test "accepts valid MAC with hyphens" do
      assert {:ok, hw} = Hardware.new(%{id: "srv-04", mac: "AA-BB-CC-DD-EE-FF"})
      assert hw.mac == "AA-BB-CC-DD-EE-FF"
    end

    test "accepts all valid device types" do
      valid_types = ~w(server workstation laptop switch router access_point
                       printer iot sensor gateway storage firewall other)

      for type <- valid_types do
        assert {:ok, hw} = Hardware.new(%{id: "d-#{type}", device_type: type})
        assert hw.device_type == type
      end
    end

    test "accepts all valid statuses" do
      for status <- ~w(active decommissioned maintenance provisioning unknown) do
        assert {:ok, hw} = Hardware.new(%{id: "d-#{status}", status: status})
        assert hw.status == status
      end
    end

    test "sets created_at and updated_at timestamps" do
      {:ok, hw} = Hardware.new(%{id: "srv-ts"})
      assert %DateTime{} = hw.created_at
      assert %DateTime{} = hw.updated_at
    end

    test "defaults tags to empty list" do
      {:ok, hw} = Hardware.new(%{id: "srv-tags"})
      assert hw.tags == []
    end

    test "defaults properties to empty map" do
      {:ok, hw} = Hardware.new(%{id: "srv-props"})
      assert hw.properties == %{}
    end
  end

  describe "new/1 — validation errors" do
    test "returns error when id is nil" do
      assert {:error, "id is required"} = Hardware.new(%{})
    end

    test "returns error when id is empty string" do
      assert {:error, "id is required"} = Hardware.new(%{id: ""})
    end

    test "returns error for invalid MAC format" do
      assert {:error, msg} = Hardware.new(%{id: "x", mac: "invalid-mac"})
      assert msg =~ "invalid MAC"
    end

    test "returns error for MAC with wrong octet count" do
      assert {:error, _} = Hardware.new(%{id: "x", mac: "AA:BB:CC:DD:EE"})
    end

    test "returns error for invalid device_type" do
      assert {:error, msg} = Hardware.new(%{id: "x", device_type: "spaceship"})
      assert msg =~ "invalid device_type"
    end

    test "returns error for invalid status" do
      assert {:error, msg} = Hardware.new(%{id: "x", status: "broken"})
      assert msg =~ "invalid status"
    end
  end

  describe "validate/1" do
    test "returns {:ok, hw} for valid struct" do
      hw = %Hardware{id: "srv-v", device_type: "server", status: "active"}
      assert {:ok, ^hw} = Hardware.validate(hw)
    end

    test "returns error for struct with no id" do
      hw = %Hardware{id: nil}
      assert {:error, "id is required"} = Hardware.validate(hw)
    end
  end

  describe "update/2" do
    test "updates hostname" do
      {:ok, hw} = Hardware.new(%{id: "srv-u1"})
      assert {:ok, updated} = Hardware.update(hw, %{hostname: "new-host"})
      assert updated.hostname == "new-host"
    end

    test "updates updated_at timestamp" do
      {:ok, hw} = Hardware.new(%{id: "srv-u2"})
      Process.sleep(1)
      {:ok, updated} = Hardware.update(hw, %{hostname: "h"})
      assert DateTime.compare(updated.updated_at, hw.updated_at) in [:gt, :eq]
    end

    test "preserves id on update" do
      {:ok, hw} = Hardware.new(%{id: "srv-u3"})
      {:ok, updated} = Hardware.update(hw, %{hostname: "h"})
      assert updated.id == "srv-u3"
    end

    test "accepts string keys in update attrs" do
      {:ok, hw} = Hardware.new(%{id: "srv-u4"})
      assert {:ok, updated} = Hardware.update(hw, %{"hostname" => "str-host"})
      assert updated.hostname == "str-host"
    end

    test "returns error when update produces invalid status" do
      {:ok, hw} = Hardware.new(%{id: "srv-u5"})
      assert {:error, _} = Hardware.update(hw, %{status: "invalid"})
    end

    test "returns error when update produces invalid device_type" do
      {:ok, hw} = Hardware.new(%{id: "srv-u6"})
      assert {:error, _} = Hardware.update(hw, %{device_type: "rocket"})
    end
  end
end
