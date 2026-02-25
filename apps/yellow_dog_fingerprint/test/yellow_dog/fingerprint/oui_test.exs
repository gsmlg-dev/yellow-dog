defmodule YellowDog.Fingerprint.OUITest do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.OUI

  # VMware OUI prefix — a stable, well-known vendor in the GSMLG MAC database
  @vmware_mac "00:50:56:aa:bb:cc"
  @unknown_mac "aa:bb:cc:dd:ee:ff"

  describe "lookup/1 with known vendor" do
    test "returns {:ok, vendor} for known OUI prefix" do
      assert {:ok, vendor} = OUI.lookup(@vmware_mac)
      assert is_binary(vendor)
      assert String.length(vendor) > 0
    end

    test "vendor string is non-empty" do
      {:ok, vendor} = OUI.lookup(@vmware_mac)
      refute vendor == ""
    end
  end

  describe "lookup/1 with unknown vendor" do
    test "returns :not_found for unregistered MAC prefix" do
      assert :not_found = OUI.lookup(@unknown_mac)
    end
  end

  describe "lookup_full/1" do
    test "returns {:ok, short, full} for known OUI prefix" do
      assert {:ok, short, full} = OUI.lookup_full(@vmware_mac)
      assert is_binary(short)
      assert is_binary(full)
      assert String.length(short) > 0
      assert String.length(full) > 0
    end

    test "returns :not_found for unknown OUI prefix" do
      assert :not_found = OUI.lookup_full(@unknown_mac)
    end
  end

  describe "MAC normalization via lookup/1" do
    test "accepts colon-separated MACs" do
      assert {:ok, _} = OUI.lookup("00:50:56:aa:bb:cc")
    end

    test "accepts hyphen-separated MACs" do
      assert {:ok, _} = OUI.lookup("00-50-56-aa-bb-cc")
    end

    test "accepts uppercase MAC" do
      assert {:ok, _} = OUI.lookup("00:50:56:AA:BB:CC")
    end

    test "accepts mixed-case MAC" do
      assert {:ok, _} = OUI.lookup("00:50:56:Aa:bB:cC")
    end

    test "normalizes different formats to same lookup result" do
      result_colon = OUI.lookup("00:50:56:aa:bb:cc")
      result_hyphen = OUI.lookup("00-50-56-aa-bb-cc")
      result_upper = OUI.lookup("00:50:56:AA:BB:CC")

      assert result_colon == result_hyphen
      assert result_colon == result_upper
    end
  end

  describe "start_link/1" do
    test "OUI GenServer is running (started by application)" do
      pid = Process.whereis(OUI)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
