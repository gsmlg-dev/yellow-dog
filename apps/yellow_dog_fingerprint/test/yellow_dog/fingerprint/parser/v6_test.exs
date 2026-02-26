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

    test "handles nil vendor class and FQDN" do
      metadata = %{option_6: [23, 24]}

      assert {:ok, fp} = V6.extract(metadata)
      assert fp.vendor_class == nil
      assert fp.hostname_pattern == nil
    end

    test "timestamps are set to current UTC time" do
      before = DateTime.utc_now()
      {:ok, fp} = V6.extract(%{option_6: [23, 24]})
      after_time = DateTime.utc_now()

      assert DateTime.compare(fp.first_seen, before) in [:eq, :gt]
      assert DateTime.compare(fp.first_seen, after_time) in [:eq, :lt]
      assert fp.first_seen == fp.last_seen
    end

    test "different option lists produce different IDs" do
      {:ok, fp1} = V6.extract(%{option_6: [23, 24]})
      {:ok, fp2} = V6.extract(%{option_6: [23, 24, 39]})
      assert fp1.id != fp2.id
    end

    test "vendor class affects fingerprint ID" do
      {:ok, fp1} = V6.extract(%{option_6: [23, 24], option_16: %{enterprise_id: 1, data: "a"}})
      {:ok, fp2} = V6.extract(%{option_6: [23, 24], option_16: %{enterprise_id: 2, data: "b"}})
      assert fp1.id != fp2.id
    end

    test "FQDN normalization replaces numbers with wildcards" do
      metadata = %{option_6: [23, 24], option_39: "HOST123.example456.com"}

      assert {:ok, fp} = V6.extract(metadata)
      assert fp.hostname_pattern == "host*.example*.com"
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

    test "handles empty option data" do
      options = [%{option_code: 6, option_data: <<>>}]
      assert V6.extract_option_6(options) == []
    end

    test "handles single option code" do
      options = [%{option_code: 6, option_data: <<0, 23>>}]
      assert V6.extract_option_6(options) == [23]
    end

    test "handles odd-length binary (trailing byte)" do
      options = [%{option_code: 6, option_data: <<0, 23, 0, 24, 0xFF>>}]
      assert V6.extract_option_6(options) == [23, 24]
    end

    test "decodes large option codes (>255)" do
      options = [%{option_code: 6, option_data: <<1, 0, 2, 0>>}]
      assert V6.extract_option_6(options) == [256, 512]
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

    test "returns nil for binary shorter than 4 bytes" do
      options = [%{option_code: 16, option_data: <<0, 1, 2>>}]
      assert V6.extract_option_16(options) == nil
    end

    test "enterprise ID only (no vendor data)" do
      options = [%{option_code: 16, option_data: <<0, 0, 0, 1>>}]
      result = V6.extract_option_16(options)
      assert result.enterprise_id == 1
      assert result.data == ""
    end

    test "large enterprise ID (Microsoft = 311)" do
      options = [%{option_code: 16, option_data: <<0, 0, 1, 55, "MSFT">>}]
      result = V6.extract_option_16(options)
      assert result.enterprise_id == 311
      assert result.data == "MSFT"
    end
  end

  describe "extract_option_39/1" do
    test "extracts client FQDN with flags byte" do
      options = [%{option_code: 39, option_data: <<0, "host.local", 0>>}]
      result = V6.extract_option_39(options)
      assert result == "host.local"
    end

    test "returns nil when missing" do
      assert V6.extract_option_39([]) == nil
    end

    test "returns nil for flags-only (empty FQDN)" do
      options = [%{option_code: 39, option_data: <<0>>}]
      assert V6.extract_option_39(options) == nil
    end

    test "returns nil for flags + null byte only" do
      options = [%{option_code: 39, option_data: <<0, 0>>}]
      assert V6.extract_option_39(options) == nil
    end

    test "strips trailing null bytes" do
      options = [%{option_code: 39, option_data: <<1, "myhost.domain.com", 0, 0>>}]
      result = V6.extract_option_39(options)
      assert result == "myhost.domain.com"
    end

    test "handles non-zero flags byte" do
      options = [%{option_code: 39, option_data: <<0b0000_0111, "host.test">>}]
      result = V6.extract_option_39(options)
      assert result == "host.test"
    end

    test "returns nil for empty binary" do
      options = [%{option_code: 39, option_data: <<>>}]
      assert V6.extract_option_39(options) == nil
    end
  end

  describe "duid_type/1" do
    test "extracts DUID-LLT type (1)" do
      assert V6.duid_type(<<0, 1, 0, 1, 0, 0, 0, 0, 0xAA, 0xBB>>) == 1
    end

    test "extracts DUID-EN type (2)" do
      assert V6.duid_type(<<0, 2, 0, 0, 0, 1, "vendor">>) == 2
    end

    test "extracts DUID-LL type (3)" do
      assert V6.duid_type(<<0, 3, 0, 1, 0xAA, 0xBB>>) == 3
    end

    test "extracts DUID-UUID type (4)" do
      assert V6.duid_type(<<0, 4, "uuid-data">>) == 4
    end

    test "returns nil for nil input" do
      assert V6.duid_type(nil) == nil
    end

    test "returns nil for empty binary" do
      assert V6.duid_type(<<>>) == nil
    end

    test "returns nil for single byte" do
      assert V6.duid_type(<<0>>) == nil
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

    test "returns defaults for empty options" do
      result = V6.extract_all_options([])
      assert result.option_6 == []
      assert result.option_16 == nil
      assert result.duid == nil
      assert result.has_ia_na == false
      assert result.has_ia_pd == false
      assert result.option_8 == nil
    end

    test "detects IA_PD (option 25)" do
      options = [
        %{option_code: 6, option_data: <<0, 23>>},
        %{option_code: 25, option_data: <<0, 0, 0, 1, 0::64>>}
      ]

      result = V6.extract_all_options(options)
      assert result.has_ia_pd == true
      assert result.has_ia_na == false
    end

    test "both IA_NA and IA_PD present" do
      options = [
        %{option_code: 6, option_data: <<0, 23>>},
        %{option_code: 3, option_data: <<0, 0, 0, 1, 0::64>>},
        %{option_code: 25, option_data: <<0, 0, 0, 2, 0::64>>}
      ]

      result = V6.extract_all_options(options)
      assert result.has_ia_na == true
      assert result.has_ia_pd == true
    end

    test "elapsed time (option 8) parses correctly" do
      options = [%{option_code: 8, option_data: <<0xFF, 0xFF>>}]
      result = V6.extract_all_options(options)
      assert result.option_8 == 65535
    end

    test "elapsed time returns nil for invalid size" do
      options = [%{option_code: 8, option_data: <<1>>}]
      result = V6.extract_all_options(options)
      assert result.option_8 == nil
    end

    test "DUID is passed through raw" do
      duid_bin = <<0, 1, 0, 1, 0x5E, 0x12, 0x34, 0x56, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      options = [
        %{option_code: 6, option_data: <<0, 23>>},
        %{option_code: 1, option_data: duid_bin}
      ]

      result = V6.extract_all_options(options)
      assert result.duid == duid_bin
    end
  end
end
