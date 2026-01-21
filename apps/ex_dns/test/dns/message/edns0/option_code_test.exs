defmodule DNS.Message.EDNS0.OptionCodeTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.OptionCode.

  Tests cover:
  - Module structure and exports
  - Creation from integer and binary
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  - All defined option codes
  - RFC compliance verification
  - Concurrent operations
  - Edge cases and boundary conditions
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.OptionCode

  # ============================================================================
  # Standard Option Codes per IANA Registry
  # ============================================================================

  @standard_codes %{
    0 => "Reserved(0)",
    1 => "LLQ",
    2 => "Update Lease",
    3 => "NSID",
    4 => "Reserved(4)",
    5 => "DAU",
    6 => "DHU",
    7 => "N3U",
    8 => "edns-client-subnet",
    9 => "EDNS EXPIRE",
    10 => "COOKIE",
    11 => "edns-tcp-keepalive",
    12 => "Padding",
    13 => "CHAIN",
    14 => "edns-key-tag",
    15 => "Extended DNS Error",
    16 => "EDNS-Client-Tag",
    17 => "EDNS-Server-Tag",
    18 => "Report-Channel"
  }

  @special_codes %{
    20292 => "Umbrella Ident",
    26946 => "DeviceID",
    65535 => "Reserved for future expansion"
  }

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(OptionCode)
    end

    test "exports new/1" do
      Code.ensure_loaded!(OptionCode)
      assert Kernel.function_exported?(OptionCode, :new, 1)
    end

    test "defines struct with value field" do
      oc = %OptionCode{}
      assert Map.has_key?(oc, :value)
    end

    test "default value is <<0::16>>" do
      oc = %OptionCode{}
      assert oc.value == <<0, 0>>
    end
  end

  describe "new/1 from integer" do
    test "creates OptionCode from integer 0" do
      oc = OptionCode.new(0)
      assert oc.value == <<0, 0>>
    end

    test "creates OptionCode from small integer" do
      oc = OptionCode.new(10)
      assert oc.value == <<0, 10>>
    end

    test "creates OptionCode from larger integer" do
      oc = OptionCode.new(1000)
      assert oc.value == <<3, 232>>
    end

    test "creates OptionCode from max value" do
      oc = OptionCode.new(65535)
      assert oc.value == <<255, 255>>
    end

    test "creates all standard option codes" do
      codes = [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]

      for code <- codes do
        oc = OptionCode.new(code)
        <<value::16>> = oc.value
        assert value == code
      end
    end
  end

  describe "new/1 from binary" do
    test "creates OptionCode from binary" do
      oc = OptionCode.new(<<0, 10>>)
      assert oc.value == <<0, 10>>
    end

    test "preserves binary exactly" do
      oc = OptionCode.new(<<255, 255>>)
      assert oc.value == <<255, 255>>
    end
  end

  describe "DNS.Parameter protocol" do
    test "implements DNS.Parameter protocol" do
      oc = OptionCode.new(10)

      binary = DNS.Parameter.to_iodata(oc)
      assert is_binary(binary)
    end

    test "to_iodata returns 2-byte binary" do
      oc = OptionCode.new(10)

      binary = DNS.Parameter.to_iodata(oc)
      assert byte_size(binary) == 2
    end

    test "to_iodata encodes value correctly" do
      oc = OptionCode.new(1000)

      binary = DNS.Parameter.to_iodata(oc)
      assert binary == <<3, 232>>
    end
  end

  describe "String.Chars protocol - standard codes" do
    test "formats Reserved(0)" do
      oc = OptionCode.new(0)
      assert to_string(oc) == "Reserved(0)"
    end

    test "formats LLQ (1)" do
      oc = OptionCode.new(1)
      assert to_string(oc) == "LLQ"
    end

    test "formats Update Lease (2)" do
      oc = OptionCode.new(2)
      assert to_string(oc) == "Update Lease"
    end

    test "formats NSID (3)" do
      oc = OptionCode.new(3)
      assert to_string(oc) == "NSID"
    end

    test "formats Reserved(4)" do
      oc = OptionCode.new(4)
      assert to_string(oc) == "Reserved(4)"
    end

    test "formats DAU (5)" do
      oc = OptionCode.new(5)
      assert to_string(oc) == "DAU"
    end

    test "formats DHU (6)" do
      oc = OptionCode.new(6)
      assert to_string(oc) == "DHU"
    end

    test "formats N3U (7)" do
      oc = OptionCode.new(7)
      assert to_string(oc) == "N3U"
    end

    test "formats edns-client-subnet (8)" do
      oc = OptionCode.new(8)
      assert to_string(oc) == "edns-client-subnet"
    end

    test "formats EDNS EXPIRE (9)" do
      oc = OptionCode.new(9)
      assert to_string(oc) == "EDNS EXPIRE"
    end

    test "formats COOKIE (10)" do
      oc = OptionCode.new(10)
      assert to_string(oc) == "COOKIE"
    end

    test "formats edns-tcp-keepalive (11)" do
      oc = OptionCode.new(11)
      assert to_string(oc) == "edns-tcp-keepalive"
    end

    test "formats Padding (12)" do
      oc = OptionCode.new(12)
      assert to_string(oc) == "Padding"
    end

    test "formats CHAIN (13)" do
      oc = OptionCode.new(13)
      assert to_string(oc) == "CHAIN"
    end

    test "formats edns-key-tag (14)" do
      oc = OptionCode.new(14)
      assert to_string(oc) == "edns-key-tag"
    end

    test "formats Extended DNS Error (15)" do
      oc = OptionCode.new(15)
      assert to_string(oc) == "Extended DNS Error"
    end

    test "formats EDNS-Client-Tag (16)" do
      oc = OptionCode.new(16)
      assert to_string(oc) == "EDNS-Client-Tag"
    end

    test "formats EDNS-Server-Tag (17)" do
      oc = OptionCode.new(17)
      assert to_string(oc) == "EDNS-Server-Tag"
    end

    test "formats Report-Channel (18)" do
      oc = OptionCode.new(18)
      assert to_string(oc) == "Report-Channel"
    end
  end

  describe "String.Chars protocol - special codes" do
    test "formats Umbrella Ident (20292)" do
      oc = OptionCode.new(20292)
      assert to_string(oc) == "Umbrella Ident"
    end

    test "formats DeviceID (26946)" do
      oc = OptionCode.new(26946)
      assert to_string(oc) == "DeviceID"
    end

    test "formats Reserved for future expansion (65535)" do
      oc = OptionCode.new(65535)
      assert to_string(oc) == "Reserved for future expansion"
    end
  end

  describe "String.Chars protocol - unassigned ranges" do
    test "formats unassigned code in 19-20291 range" do
      oc = OptionCode.new(100)
      assert to_string(oc) == "Unassigned(100)"
    end

    test "formats unassigned code in 20293-26945 range" do
      oc = OptionCode.new(25000)
      assert to_string(oc) == "Unassigned(25000)"
    end

    test "formats unassigned code in 26947-65000 range" do
      oc = OptionCode.new(30000)
      assert to_string(oc) == "Unassigned(30000)"
    end
  end

  describe "String.Chars protocol - experimental range" do
    test "formats experimental code 65001" do
      oc = OptionCode.new(65001)
      assert to_string(oc) == "Reserved for Local/Experimental Use(65001)"
    end

    test "formats experimental code 65534" do
      oc = OptionCode.new(65534)
      assert to_string(oc) == "Reserved for Local/Experimental Use(65534)"
    end

    test "formats experimental code in middle of range" do
      oc = OptionCode.new(65100)
      assert to_string(oc) == "Reserved for Local/Experimental Use(65100)"
    end
  end

  describe "edge cases" do
    test "round-trip from integer to binary and back" do
      for code <- [0, 1, 10, 100, 1000, 10000, 65535] do
        oc = OptionCode.new(code)
        binary = DNS.Parameter.to_iodata(oc)
        <<value::16>> = binary
        assert value == code
      end
    end

    test "all codes in range produce valid strings" do
      # Test sampling of codes across entire range
      codes = [0, 1, 10, 15, 18, 19, 100, 1000, 20292, 26946, 30000, 65001, 65534, 65535]

      for code <- codes do
        oc = OptionCode.new(code)
        string = to_string(oc)
        assert is_binary(string)
        assert String.length(string) > 0
      end
    end
  end

  # ============================================================================
  # RFC Compliance Tests
  # ============================================================================

  describe "RFC 6891 compliance (EDNS0)" do
    test "option codes use 16-bit unsigned integer range" do
      # RFC 6891 specifies option codes are 16-bit unsigned integers (0-65535)
      oc_min = OptionCode.new(0)
      oc_max = OptionCode.new(65535)

      assert oc_min.value == <<0, 0>>
      assert oc_max.value == <<255, 255>>
    end

    test "reserved code 0 per RFC 6891" do
      oc = OptionCode.new(0)
      assert to_string(oc) == "Reserved(0)"
    end

    test "reserved code 65535 per RFC 6891" do
      oc = OptionCode.new(65535)
      assert to_string(oc) == "Reserved for future expansion"
    end

    test "experimental range 65001-65534 per RFC 6891" do
      for code <- [65001, 65100, 65200, 65300, 65400, 65500, 65534] do
        oc = OptionCode.new(code)
        string = to_string(oc)
        assert String.starts_with?(string, "Reserved for Local/Experimental Use")
        assert String.contains?(string, "(#{code})")
      end
    end
  end

  describe "RFC 5001 compliance (NSID)" do
    test "NSID option code is 3" do
      oc = OptionCode.new(3)
      assert to_string(oc) == "NSID"
    end

    test "NSID code serializes correctly" do
      oc = OptionCode.new(3)
      binary = DNS.Parameter.to_iodata(oc)
      assert binary == <<0, 3>>
    end
  end

  describe "RFC 6975 compliance (DAU, DHU, N3U)" do
    test "DAU option code is 5" do
      oc = OptionCode.new(5)
      assert to_string(oc) == "DAU"
    end

    test "DHU option code is 6" do
      oc = OptionCode.new(6)
      assert to_string(oc) == "DHU"
    end

    test "N3U option code is 7" do
      oc = OptionCode.new(7)
      assert to_string(oc) == "N3U"
    end

    test "DNSSEC algorithm signaling codes are consecutive" do
      dau = OptionCode.new(5)
      dhu = OptionCode.new(6)
      n3u = OptionCode.new(7)

      <<dau_val::16>> = dau.value
      <<dhu_val::16>> = dhu.value
      <<n3u_val::16>> = n3u.value

      assert dhu_val == dau_val + 1
      assert n3u_val == dhu_val + 1
    end
  end

  describe "RFC 7871 compliance (edns-client-subnet)" do
    test "edns-client-subnet option code is 8" do
      oc = OptionCode.new(8)
      assert to_string(oc) == "edns-client-subnet"
    end

    test "ECS code serializes correctly" do
      oc = OptionCode.new(8)
      binary = DNS.Parameter.to_iodata(oc)
      assert binary == <<0, 8>>
    end
  end

  describe "RFC 7873 compliance (COOKIE)" do
    test "COOKIE option code is 10" do
      oc = OptionCode.new(10)
      assert to_string(oc) == "COOKIE"
    end

    test "COOKIE code serializes correctly" do
      oc = OptionCode.new(10)
      binary = DNS.Parameter.to_iodata(oc)
      assert binary == <<0, 10>>
    end
  end

  describe "RFC 7828 compliance (TCP keepalive)" do
    test "edns-tcp-keepalive option code is 11" do
      oc = OptionCode.new(11)
      assert to_string(oc) == "edns-tcp-keepalive"
    end
  end

  describe "RFC 7830 compliance (Padding)" do
    test "Padding option code is 12" do
      oc = OptionCode.new(12)
      assert to_string(oc) == "Padding"
    end
  end

  describe "RFC 7901 compliance (CHAIN)" do
    test "CHAIN option code is 13" do
      oc = OptionCode.new(13)
      assert to_string(oc) == "CHAIN"
    end
  end

  describe "RFC 8145 compliance (edns-key-tag)" do
    test "edns-key-tag option code is 14" do
      oc = OptionCode.new(14)
      assert to_string(oc) == "edns-key-tag"
    end
  end

  describe "RFC 8914 compliance (Extended DNS Error)" do
    test "Extended DNS Error option code is 15" do
      oc = OptionCode.new(15)
      assert to_string(oc) == "Extended DNS Error"
    end

    test "EDE code serializes correctly" do
      oc = OptionCode.new(15)
      binary = DNS.Parameter.to_iodata(oc)
      assert binary == <<0, 15>>
    end
  end

  describe "RFC 8764 compliance (LLQ)" do
    test "LLQ option code is 1" do
      oc = OptionCode.new(1)
      assert to_string(oc) == "LLQ"
    end
  end

  describe "RFC 7314 compliance (EDNS EXPIRE)" do
    test "EDNS EXPIRE option code is 9" do
      oc = OptionCode.new(9)
      assert to_string(oc) == "EDNS EXPIRE"
    end
  end

  describe "RFC 9567 compliance (Report-Channel)" do
    test "Report-Channel option code is 18" do
      oc = OptionCode.new(18)
      assert to_string(oc) == "Report-Channel"
    end
  end

  # ============================================================================
  # All Standard Codes Verification
  # ============================================================================

  describe "all standard option codes" do
    test "all IANA assigned codes 0-18 format correctly" do
      Enum.each(@standard_codes, fn {code, expected_name} ->
        oc = OptionCode.new(code)
        assert to_string(oc) == expected_name,
               "Expected code #{code} to format as '#{expected_name}', got '#{to_string(oc)}'"
      end)
    end

    test "all special codes format correctly" do
      Enum.each(@special_codes, fn {code, expected_name} ->
        oc = OptionCode.new(code)
        assert to_string(oc) == expected_name,
               "Expected code #{code} to format as '#{expected_name}', got '#{to_string(oc)}'"
      end)
    end
  end

  # ============================================================================
  # Unassigned Range Tests
  # ============================================================================

  describe "unassigned code ranges" do
    test "codes 19-20291 are unassigned" do
      sample_codes = [19, 50, 100, 500, 1000, 5000, 10000, 15000, 20000, 20291]

      for code <- sample_codes do
        oc = OptionCode.new(code)
        assert to_string(oc) == "Unassigned(#{code})"
      end
    end

    test "codes 20293-26945 are unassigned" do
      sample_codes = [20293, 22000, 24000, 26000, 26945]

      for code <- sample_codes do
        oc = OptionCode.new(code)
        assert to_string(oc) == "Unassigned(#{code})"
      end
    end

    test "codes 26947-65000 are unassigned" do
      sample_codes = [26947, 30000, 40000, 50000, 60000, 65000]

      for code <- sample_codes do
        oc = OptionCode.new(code)
        assert to_string(oc) == "Unassigned(#{code})"
      end
    end

    test "boundary codes around special assignments" do
      # Just before Umbrella Ident
      assert to_string(OptionCode.new(20291)) == "Unassigned(20291)"
      # Umbrella Ident
      assert to_string(OptionCode.new(20292)) == "Umbrella Ident"
      # Just after Umbrella Ident
      assert to_string(OptionCode.new(20293)) == "Unassigned(20293)"

      # Just before DeviceID
      assert to_string(OptionCode.new(26945)) == "Unassigned(26945)"
      # DeviceID
      assert to_string(OptionCode.new(26946)) == "DeviceID"
      # Just after DeviceID
      assert to_string(OptionCode.new(26947)) == "Unassigned(26947)"
    end
  end

  # ============================================================================
  # Binary Format Tests
  # ============================================================================

  describe "binary representation" do
    test "value is stored as big-endian 16-bit" do
      # 256 in big-endian is <<1, 0>>
      oc = OptionCode.new(256)
      assert oc.value == <<1, 0>>
    end

    test "value byte order is network order (big-endian)" do
      oc = OptionCode.new(0x0102)  # 258 decimal
      assert oc.value == <<1, 2>>
    end

    test "high byte encodes correctly" do
      oc = OptionCode.new(0xFF00)  # 65280 decimal
      assert oc.value == <<255, 0>>
    end

    test "low byte encodes correctly" do
      oc = OptionCode.new(0x00FF)  # 255 decimal
      assert oc.value == <<0, 255>>
    end

    test "both bytes encode correctly" do
      oc = OptionCode.new(0xABCD)  # 43981 decimal
      assert oc.value == <<171, 205>>
    end
  end

  # ============================================================================
  # Creation Edge Cases
  # ============================================================================

  describe "creation edge cases" do
    test "creates from exact 2-byte binary" do
      oc = OptionCode.new(<<0xAB, 0xCD>>)
      assert oc.value == <<0xAB, 0xCD>>
    end

    test "creates from zero binary" do
      oc = OptionCode.new(<<0, 0>>)
      assert oc.value == <<0, 0>>
    end

    test "creates from max binary" do
      oc = OptionCode.new(<<255, 255>>)
      assert oc.value == <<255, 255>>
    end

    test "default struct has zero value" do
      oc = %OptionCode{}
      assert oc.value == <<0, 0>>
    end

    test "integer 0 and binary <<0,0>> produce same result" do
      from_int = OptionCode.new(0)
      from_bin = OptionCode.new(<<0, 0>>)
      assert from_int.value == from_bin.value
    end
  end

  # ============================================================================
  # Concurrent Operations Tests
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent creation of option codes" do
      tasks =
        for code <- 0..100 do
          Task.async(fn ->
            OptionCode.new(code)
          end)
        end

      results = Task.await_many(tasks)

      assert length(results) == 101

      Enum.each(Enum.with_index(results), fn {oc, index} ->
        <<value::16>> = oc.value
        assert value == index
      end)
    end

    test "concurrent string formatting" do
      codes = [0, 1, 3, 5, 6, 7, 8, 10, 12, 13, 14, 15]

      tasks =
        for code <- codes do
          Task.async(fn ->
            oc = OptionCode.new(code)
            {code, to_string(oc)}
          end)
        end

      results = Task.await_many(tasks)

      Enum.each(results, fn {code, string} ->
        expected = Map.get(@standard_codes, code)
        assert string == expected
      end)
    end

    test "concurrent serialization" do
      tasks =
        for code <- [1, 10, 100, 1000, 10000] do
          Task.async(fn ->
            oc = OptionCode.new(code)
            binary = DNS.Parameter.to_iodata(oc)
            <<value::16>> = binary
            {code, value}
          end)
        end

      results = Task.await_many(tasks)

      Enum.each(results, fn {original, serialized} ->
        assert original == serialized
      end)
    end
  end

  # ============================================================================
  # Comparison and Equality Tests
  # ============================================================================

  describe "comparison and equality" do
    test "same integer creates equal option codes" do
      oc1 = OptionCode.new(10)
      oc2 = OptionCode.new(10)
      assert oc1 == oc2
    end

    test "different integers create different option codes" do
      oc1 = OptionCode.new(10)
      oc2 = OptionCode.new(11)
      assert oc1 != oc2
    end

    test "integer and equivalent binary create equal option codes" do
      from_int = OptionCode.new(256)
      from_bin = OptionCode.new(<<1, 0>>)
      assert from_int == from_bin
    end

    test "option codes can be compared in maps" do
      oc = OptionCode.new(10)
      map = %{oc => "cookie"}
      assert map[oc] == "cookie"
    end

    test "option codes can be used in MapSets" do
      codes = [1, 2, 3, 1, 2, 3]
      option_codes = Enum.map(codes, &OptionCode.new/1)
      unique = MapSet.new(option_codes)
      assert MapSet.size(unique) == 3
    end
  end

  # ============================================================================
  # Practical Usage Tests
  # ============================================================================

  describe "practical usage scenarios" do
    test "creating EDNS0 cookie option code" do
      cookie_code = OptionCode.new(10)
      assert to_string(cookie_code) == "COOKIE"
      assert DNS.Parameter.to_iodata(cookie_code) == <<0, 10>>
    end

    test "creating EDNS client subnet option code" do
      ecs_code = OptionCode.new(8)
      assert to_string(ecs_code) == "edns-client-subnet"
      assert DNS.Parameter.to_iodata(ecs_code) == <<0, 8>>
    end

    test "parsing option code from wire format" do
      wire_data = <<0, 12>>  # Padding option code
      oc = OptionCode.new(wire_data)
      assert to_string(oc) == "Padding"
    end

    test "building option code for DNS message" do
      # Simulate building an EDNS0 option
      nsid_code = OptionCode.new(3)
      code_binary = DNS.Parameter.to_iodata(nsid_code)

      # In a real message, this would be followed by length and data
      assert byte_size(code_binary) == 2
      assert code_binary == <<0, 3>>
    end

    test "iterating over all standard codes" do
      standard_code_numbers = 0..18

      codes_and_names =
        Enum.map(standard_code_numbers, fn num ->
          oc = OptionCode.new(num)
          {num, to_string(oc)}
        end)

      # Verify we have names for all standard codes
      assert length(codes_and_names) == 19

      # Verify none are "Unassigned"
      Enum.each(codes_and_names, fn {_num, name} ->
        refute String.starts_with?(name, "Unassigned")
      end)
    end
  end

  # ============================================================================
  # Vendor-Specific Codes Tests
  # ============================================================================

  describe "vendor-specific option codes" do
    test "Cisco Umbrella Ident code 20292" do
      oc = OptionCode.new(20292)
      assert to_string(oc) == "Umbrella Ident"

      # Verify binary encoding
      <<value::16>> = oc.value
      assert value == 20292
    end

    test "Cisco DeviceID code 26946" do
      oc = OptionCode.new(26946)
      assert to_string(oc) == "DeviceID"

      # Verify binary encoding
      <<value::16>> = oc.value
      assert value == 26946
    end

    test "vendor codes are properly isolated" do
      # Codes around vendor assignments should be unassigned
      assert String.starts_with?(to_string(OptionCode.new(20291)), "Unassigned")
      assert to_string(OptionCode.new(20292)) == "Umbrella Ident"
      assert String.starts_with?(to_string(OptionCode.new(20293)), "Unassigned")

      assert String.starts_with?(to_string(OptionCode.new(26945)), "Unassigned")
      assert to_string(OptionCode.new(26946)) == "DeviceID"
      assert String.starts_with?(to_string(OptionCode.new(26947)), "Unassigned")
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "creating many option codes is efficient" do
      {time, codes} =
        :timer.tc(fn ->
          Enum.map(0..10000, &OptionCode.new/1)
        end)

      assert length(codes) == 10001
      # Should complete in under 50ms
      assert time < 50000
    end

    test "formatting many option codes is efficient" do
      codes = Enum.map(0..1000, &OptionCode.new/1)

      {time, strings} =
        :timer.tc(fn ->
          Enum.map(codes, &to_string/1)
        end)

      assert length(strings) == 1001
      # Should complete in under 50ms
      assert time < 50000
    end

    test "serializing many option codes is efficient" do
      codes = Enum.map(0..1000, &OptionCode.new/1)

      {time, binaries} =
        :timer.tc(fn ->
          Enum.map(codes, &DNS.Parameter.to_iodata/1)
        end)

      assert length(binaries) == 1001
      # Should complete in under 50ms
      assert time < 50000
    end
  end
end
