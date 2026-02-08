defmodule YellowDog.Dhcpv6.DuidFormatTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.DuidFormat

  describe "format/2" do
    test "formats binary DUID as uppercase colon-separated hex" do
      assert DuidFormat.format(<<0x00, 0x01, 0x00, 0x01>>) == "00:01:00:01"
    end

    test "formats single byte" do
      assert DuidFormat.format(<<0xFF>>) == "FF"
    end

    test "formats with lowercase option" do
      assert DuidFormat.format(<<0xAB, 0xCD>>, case: :lower) == "ab:cd"
    end

    test "formats with custom separator" do
      assert DuidFormat.format(<<0xAA, 0xBB, 0xCC>>, separator: "-") == "AA-BB-CC"
    end

    test "formats with both custom separator and lowercase" do
      assert DuidFormat.format(<<0xAA, 0xBB>>, separator: ".", case: :lower) == "aa.bb"
    end

    test "pads single-digit hex values with leading zero" do
      assert DuidFormat.format(<<0x01, 0x0A>>) == "01:0A"
    end

    test "returns nil for empty binary" do
      assert DuidFormat.format(<<>>) == nil
    end

    test "returns nil for non-binary" do
      assert DuidFormat.format(nil) == nil
      assert DuidFormat.format(123) == nil
      assert DuidFormat.format(:atom) == nil
    end

    test "defaults to uppercase with colon separator" do
      result = DuidFormat.format(<<0xAB, 0xCD, 0xEF>>)
      assert result == "AB:CD:EF"
    end
  end

  describe "format!/2" do
    test "returns formatted string for valid DUID" do
      assert DuidFormat.format!(<<0x00, 0x01>>) == "00:01"
    end

    test "returns UNKNOWN for nil" do
      assert DuidFormat.format!(nil) == "UNKNOWN"
    end

    test "returns UNKNOWN for empty binary" do
      assert DuidFormat.format!(<<>>) == "UNKNOWN"
    end

    test "returns UNKNOWN for non-binary" do
      assert DuidFormat.format!(123) == "UNKNOWN"
    end

    test "passes options through to format/2" do
      assert DuidFormat.format!(<<0xAB, 0xCD>>, case: :lower) == "ab:cd"
    end
  end
end
