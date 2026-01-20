defmodule DNS.Message.EDNS0.OptionCodeTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.OptionCode.

  Tests cover:
  - Module structure and exports
  - Creation from integer and binary
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  - All defined option codes
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.OptionCode

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
end
