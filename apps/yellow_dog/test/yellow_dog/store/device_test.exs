defmodule YellowDog.Store.DeviceTest do
  use ExUnit.Case

  alias YellowDog.Store.Device

  @moduletag :store_integration

  @tag :skip
  test "upsert creates a new device record" do
    mac = "aa:bb:cc:dd:ee:01"
    attrs = %{vendor_class: "TestVendor", hostname: "test-device"}

    assert :ok = Device.upsert(mac, attrs)

    {:ok, device} = Device.get(mac)
    assert device.vendor_class == "TestVendor"
    assert device.hostname == "test-device"
    assert device.mac == mac
    assert is_integer(device.first_seen)
    assert is_integer(device.last_seen)
  end

  @tag :skip
  test "upsert merges new attributes into existing device" do
    mac = "aa:bb:cc:dd:ee:02"

    Device.upsert(mac, %{vendor_class: "Vendor1"})
    Device.upsert(mac, %{hostname: "updated-host"})

    {:ok, device} = Device.get(mac)
    assert device.vendor_class == "Vendor1"
    assert device.hostname == "updated-host"
  end

  @tag :skip
  test "get returns :not_found for unknown MAC" do
    assert {:error, :not_found} = Device.get("ff:ff:ff:ff:ff:ff")
  end

  @tag :skip
  test "by_vendor returns devices matching vendor class" do
    Device.upsert("aa:bb:cc:dd:ee:03", %{vendor_class: "SpecificVendor"})
    Device.upsert("aa:bb:cc:dd:ee:04", %{vendor_class: "OtherVendor"})

    {:ok, devices} = Device.by_vendor("SpecificVendor")
    assert length(devices) >= 1
    assert Enum.all?(devices, &(&1.vendor_class == "SpecificVendor"))
  end

  @tag :skip
  test "list_recent returns devices seen since timestamp" do
    now = System.system_time(:second)
    Device.upsert("aa:bb:cc:dd:ee:05", %{hostname: "recent"})

    {:ok, devices} = Device.list_recent(now - 10)
    assert length(devices) >= 1
  end

  @tag :skip
  test "different MAC formats resolve to same device" do
    Device.upsert("AA-BB-CC-DD-EE-06", %{hostname: "format-test"})

    {:ok, device} = Device.get("aa:bb:cc:dd:ee:06")
    assert device.hostname == "format-test"
  end
end
