defmodule YellowDog.Fingerprint.Parser.V6Test do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Parser.V6

  describe "extract/1" do
    test "extracts fingerprint from metadata with option 6" do
      metadata = %{
        option_6: [23, 24, 39],
        option_16: %{enterprise_id: 43793, data: "test"},
        option_39: "host.example.com",
        duid: <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      }

      assert {:ok, fp} = V6.extract(metadata)
      assert fp.protocol == :dhcpv6
      assert fp.parameter_list == [23, 24, 39]
      assert fp.vendor_class == "43793:test"
      assert fp.hostname_pattern == "host.example.com"
      assert fp.hit_count == 1
    end

    test "returns :skip when option 6 is empty" do
      assert :skip == V6.extract(%{option_6: []})
    end

    test "returns :skip when option 6 is missing" do
      assert :skip == V6.extract(%{})
    end
  end

  describe "extract_option_6/1" do
    test "decodes 2-byte option codes from raw binary" do
      options = [
        %{option_code: 6, option_data: <<0, 23, 0, 24, 0, 39>>}
      ]

      assert V6.extract_option_6(options) == [23, 24, 39]
    end

    test "returns empty list when missing" do
      assert V6.extract_option_6([]) == []
    end
  end

  describe "extract_option_16/1" do
    test "parses vendor class with enterprise ID" do
      options = [
        %{option_code: 16, option_data: <<0, 0, 0xAB, 0x11, "vendor">>}
      ]

      result = V6.extract_option_16(options)
      assert result.enterprise_id == 0xAB11
      assert result.data == "vendor"
    end

    test "returns nil when missing" do
      assert V6.extract_option_16([]) == nil
    end
  end

  describe "duid_type/1" do
    test "extracts DUID-LLT type" do
      assert V6.duid_type(<<0, 1, 0, 1, 0, 0, 0, 0, 0xAA, 0xBB>>) == 1
    end

    test "extracts DUID-LL type" do
      assert V6.duid_type(<<0, 3, 0, 1, 0xAA, 0xBB>>) == 3
    end

    test "extracts DUID-UUID type" do
      assert V6.duid_type(<<0, 4, "uuid-data">>) == 4
    end

    test "returns nil for nil input" do
      assert V6.duid_type(nil) == nil
    end
  end

  describe "extract_all_options/1" do
    test "extracts all fingerprint-relevant DHCPv6 options" do
      options = [
        %{option_code: 6, option_data: <<0, 23, 0, 24>>},
        %{option_code: 16, option_data: <<0, 0, 0, 1, "test">>},
        %{option_code: 39, option_data: <<0, "host.local", 0>>},
        %{option_code: 1, option_data: <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>},
        %{option_code: 3, option_data: <<0, 0, 0, 1, 0::64>>},
        %{option_code: 8, option_data: <<0, 100>>}
      ]

      result = V6.extract_all_options(options)
      assert result.option_6 == [23, 24]
      assert result.option_16.enterprise_id == 1
      assert result.has_ia_na == true
      assert result.has_ia_pd == false
      assert result.option_8 == 100
    end
  end
end
