defmodule YellowDog.Dhcpv4.MacFormatTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.MacFormat

  describe "format/2" do
    test "formats 6-byte binary as uppercase colon-separated hex" do
      assert MacFormat.format(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>) == "AA:BB:CC:DD:EE:FF"
    end

    test "formats zero MAC" do
      assert MacFormat.format(<<0, 0, 0, 0, 0, 0>>) == "00:00:00:00:00:00"
    end

    test "formats with lowercase option" do
      assert MacFormat.format(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>, case: :lower) ==
               "aa:bb:cc:dd:ee:ff"
    end

    test "uses first 6 bytes of longer binary" do
      assert MacFormat.format(<<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>) ==
               "01:02:03:04:05:06"
    end

    test "returns nil for short binary" do
      assert MacFormat.format(<<1, 2, 3>>) == nil
    end

    test "returns nil for empty binary" do
      assert MacFormat.format(<<>>) == nil
    end

    test "returns nil for non-binary" do
      assert MacFormat.format(nil) == nil
      assert MacFormat.format(123) == nil
      assert MacFormat.format(:atom) == nil
    end

    test "defaults to uppercase" do
      result = MacFormat.format(<<0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45>>)
      assert result == String.upcase(result)
    end
  end
end
