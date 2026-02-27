defmodule YellowDog.Fingerprint.Parser.V4Test do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Parser.V4

  describe "extract/1" do
    test "extracts fingerprint from metadata with option 55" do
      metadata = %{
        option_55: [1, 3, 6, 15, 119, 252],
        option_60: "MSFT 5.0",
        option_12: "DESKTOP-ABC123"
      }

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.protocol == :dhcpv4
      assert fp.parameter_list == [1, 3, 6, 15, 119, 252]
      assert fp.vendor_class == "MSFT 5.0"
      assert fp.hostname_pattern == "desktop-abc*"
      assert fp.hit_count == 1
      assert is_binary(fp.id)
    end

    test "returns :skip when option 55 is empty" do
      assert :skip == V4.extract(%{option_55: []})
    end

    test "returns :skip when option 55 is missing" do
      assert :skip == V4.extract(%{})
    end

    test "handles nil vendor class and hostname" do
      metadata = %{option_55: [1, 3, 6]}

      assert {:ok, fp} = V4.extract(metadata)
      assert fp.vendor_class == nil
      assert fp.hostname_pattern == nil
    end
  end

  describe "extract_option_55/1" do
    test "extracts parameter request list from raw options" do
      options = [
        %{type: 53, value: <<1>>},
        %{type: 55, value: <<1, 3, 6, 15, 119>>},
        %{type: 60, value: "MSFT 5.0"}
      ]

      assert V4.extract_option_55(options) == [1, 3, 6, 15, 119]
    end

    test "returns empty list when option 55 missing" do
      options = [%{type: 53, value: <<1>>}]
      assert V4.extract_option_55(options) == []
    end
  end

  describe "extract_option_60/1" do
    test "extracts vendor class identifier" do
      options = [%{type: 60, value: "android-dhcp-14\0"}]
      assert V4.extract_option_60(options) == "android-dhcp-14"
    end

    test "returns nil when missing" do
      assert V4.extract_option_60([]) == nil
    end
  end

  describe "extract_all_options/1" do
    test "extracts all fingerprint-relevant options" do
      options = [
        %{type: 55, value: <<1, 3, 6>>},
        %{type: 60, value: "test"},
        %{type: 12, value: "host1"},
        %{type: 61, value: <<1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>},
        %{type: 57, value: <<5, 220>>},
        %{type: 93, value: <<0, 7>>}
      ]

      result = V4.extract_all_options(options)
      assert result.option_55 == [1, 3, 6]
      assert result.option_60 == "test"
      assert result.option_12 == "host1"
      assert result.option_61 == <<1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      assert result.option_57 == 1500
      assert result.option_93 == 7
    end
  end
end
