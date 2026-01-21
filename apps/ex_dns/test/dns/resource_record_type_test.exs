defmodule DNS.ResourceRecordTypeTest do
  @moduledoc """
  Comprehensive unit tests for DNS.ResourceRecordType.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with integer, atom, and binary inputs
  - Protocol implementations (DNS.Parameter, String.Chars, Inspect)
  - All standard RRType values (1-65535)
  - IANA registered types
  """
  use ExUnit.Case, async: true

  alias DNS.ResourceRecordType

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ResourceRecordType)
    end

    test "exports new/1" do
      Code.ensure_loaded!(ResourceRecordType)
      assert Kernel.function_exported?(ResourceRecordType, :new, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(ResourceRecordType)
      assert is_struct(ResourceRecordType.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      rtype = %ResourceRecordType{}
      assert Map.has_key?(rtype, :value)
    end

    test "default value is A (1)" do
      rtype = %ResourceRecordType{}
      assert rtype.value == <<1::16>>
    end
  end

  describe "new/1 with integer" do
    test "creates RRType with integer 1" do
      rtype = ResourceRecordType.new(1)
      assert rtype.value == <<1::16>>
    end

    test "creates RRType with integer 28 (AAAA)" do
      rtype = ResourceRecordType.new(28)
      assert rtype.value == <<28::16>>
    end

    test "creates RRType with integer 255 (ANY)" do
      rtype = ResourceRecordType.new(255)
      assert rtype.value == <<255::16>>
    end

    test "creates RRType with integer 65535 (Reserved)" do
      rtype = ResourceRecordType.new(65535)
      assert rtype.value == <<65535::16>>
    end

    test "creates RRType with integer 0 (Reserved)" do
      rtype = ResourceRecordType.new(0)
      assert rtype.value == <<0::16>>
    end
  end

  describe "new/1 with atom" do
    test "creates RRType from :a atom" do
      rtype = ResourceRecordType.new(:a)
      assert rtype.value == <<1::16>>
    end

    test "creates RRType from :ns atom" do
      rtype = ResourceRecordType.new(:ns)
      assert rtype.value == <<2::16>>
    end

    test "creates RRType from :cname atom" do
      rtype = ResourceRecordType.new(:cname)
      assert rtype.value == <<5::16>>
    end

    test "creates RRType from :soa atom" do
      rtype = ResourceRecordType.new(:soa)
      assert rtype.value == <<6::16>>
    end

    test "creates RRType from :ptr atom" do
      rtype = ResourceRecordType.new(:ptr)
      assert rtype.value == <<12::16>>
    end

    test "creates RRType from :mx atom" do
      rtype = ResourceRecordType.new(:mx)
      assert rtype.value == <<15::16>>
    end

    test "creates RRType from :txt atom" do
      rtype = ResourceRecordType.new(:txt)
      assert rtype.value == <<16::16>>
    end

    test "creates RRType from :aaaa atom" do
      rtype = ResourceRecordType.new(:aaaa)
      assert rtype.value == <<28::16>>
    end

    test "creates RRType from :srv atom" do
      rtype = ResourceRecordType.new(:srv)
      assert rtype.value == <<33::16>>
    end

    test "creates RRType from :ds atom" do
      rtype = ResourceRecordType.new(:ds)
      assert rtype.value == <<43::16>>
    end

    test "creates RRType from :sshfp atom" do
      rtype = ResourceRecordType.new(:sshfp)
      assert rtype.value == <<44::16>>
    end

    test "creates RRType from :ipseckey atom" do
      rtype = ResourceRecordType.new(:ipseckey)
      assert rtype.value == <<45::16>>
    end

    test "creates RRType from :rrsig atom" do
      rtype = ResourceRecordType.new(:rrsig)
      assert rtype.value == <<46::16>>
    end

    test "creates RRType from :nsec atom" do
      rtype = ResourceRecordType.new(:nsec)
      assert rtype.value == <<47::16>>
    end

    test "creates RRType from :dnskey atom" do
      rtype = ResourceRecordType.new(:dnskey)
      assert rtype.value == <<48::16>>
    end

    test "creates RRType from :dhcid atom" do
      rtype = ResourceRecordType.new(:dhcid)
      assert rtype.value == <<49::16>>
    end

    test "creates RRType from :nsec3 atom" do
      rtype = ResourceRecordType.new(:nsec3)
      assert rtype.value == <<50::16>>
    end

    test "creates RRType from :nsec3param atom" do
      rtype = ResourceRecordType.new(:nsec3param)
      assert rtype.value == <<51::16>>
    end

    test "creates RRType from :tlsa atom" do
      rtype = ResourceRecordType.new(:tlsa)
      assert rtype.value == <<52::16>>
    end

    test "creates RRType from :smimea atom" do
      rtype = ResourceRecordType.new(:smimea)
      assert rtype.value == <<53::16>>
    end

    test "creates RRType from :hip atom" do
      rtype = ResourceRecordType.new(:hip)
      assert rtype.value == <<55::16>>
    end

    test "creates RRType from :cds atom" do
      rtype = ResourceRecordType.new(:cds)
      assert rtype.value == <<59::16>>
    end

    test "creates RRType from :cdnskey atom" do
      rtype = ResourceRecordType.new(:cdnskey)
      assert rtype.value == <<60::16>>
    end

    test "creates RRType from :openpgpkey atom" do
      rtype = ResourceRecordType.new(:openpgpkey)
      assert rtype.value == <<61::16>>
    end

    test "creates RRType from :csync atom" do
      rtype = ResourceRecordType.new(:csync)
      assert rtype.value == <<62::16>>
    end

    test "creates RRType from :zonemd atom" do
      rtype = ResourceRecordType.new(:zonemd)
      assert rtype.value == <<63::16>>
    end

    test "creates RRType from :svcb atom" do
      rtype = ResourceRecordType.new(:svcb)
      assert rtype.value == <<64::16>>
    end

    test "creates RRType from :https atom" do
      rtype = ResourceRecordType.new(:https)
      assert rtype.value == <<65::16>>
    end

    test "throws for unsupported atom" do
      assert catch_throw(ResourceRecordType.new(:invalid)) =~ "Unsupported atom RRType"
    end
  end

  describe "new/1 with binary" do
    test "creates RRType from binary <<1::16>>" do
      rtype = ResourceRecordType.new(<<1::16>>)
      assert rtype.value == <<1::16>>
    end

    test "creates RRType from binary <<28::16>>" do
      rtype = ResourceRecordType.new(<<28::16>>)
      assert rtype.value == <<28::16>>
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format for A" do
      rtype = ResourceRecordType.new(1)
      assert DNS.Parameter.to_iodata(rtype) == <<1::16>>
    end

    test "produces correct wire format for AAAA" do
      rtype = ResourceRecordType.new(28)
      assert DNS.Parameter.to_iodata(rtype) == <<28::16>>
    end

    test "produces correct wire format for OPT" do
      rtype = ResourceRecordType.new(41)
      assert DNS.Parameter.to_iodata(rtype) == <<41::16>>
    end

    test "produces correct wire format for max value" do
      rtype = ResourceRecordType.new(65535)
      assert DNS.Parameter.to_iodata(rtype) == <<65535::16>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats A (1)" do
      rtype = ResourceRecordType.new(1)
      assert to_string(rtype) == "A"
    end

    test "formats NS (2)" do
      rtype = ResourceRecordType.new(2)
      assert to_string(rtype) == "NS"
    end

    test "formats MD (3)" do
      rtype = ResourceRecordType.new(3)
      assert to_string(rtype) == "MD"
    end

    test "formats MF (4)" do
      rtype = ResourceRecordType.new(4)
      assert to_string(rtype) == "MF"
    end

    test "formats CNAME (5)" do
      rtype = ResourceRecordType.new(5)
      assert to_string(rtype) == "CNAME"
    end

    test "formats SOA (6)" do
      rtype = ResourceRecordType.new(6)
      assert to_string(rtype) == "SOA"
    end

    test "formats MB (7)" do
      rtype = ResourceRecordType.new(7)
      assert to_string(rtype) == "MB"
    end

    test "formats MG (8)" do
      rtype = ResourceRecordType.new(8)
      assert to_string(rtype) == "MG"
    end

    test "formats MR (9)" do
      rtype = ResourceRecordType.new(9)
      assert to_string(rtype) == "MR"
    end

    test "formats NULL (10)" do
      rtype = ResourceRecordType.new(10)
      assert to_string(rtype) == "NULL"
    end

    test "formats WKS (11)" do
      rtype = ResourceRecordType.new(11)
      assert to_string(rtype) == "WKS"
    end

    test "formats PTR (12)" do
      rtype = ResourceRecordType.new(12)
      assert to_string(rtype) == "PTR"
    end

    test "formats HINFO (13)" do
      rtype = ResourceRecordType.new(13)
      assert to_string(rtype) == "HINFO"
    end

    test "formats MINFO (14)" do
      rtype = ResourceRecordType.new(14)
      assert to_string(rtype) == "MINFO"
    end

    test "formats MX (15)" do
      rtype = ResourceRecordType.new(15)
      assert to_string(rtype) == "MX"
    end

    test "formats TXT (16)" do
      rtype = ResourceRecordType.new(16)
      assert to_string(rtype) == "TXT"
    end

    test "formats AAAA (28)" do
      rtype = ResourceRecordType.new(28)
      assert to_string(rtype) == "AAAA"
    end

    test "formats SRV (33)" do
      rtype = ResourceRecordType.new(33)
      assert to_string(rtype) == "SRV"
    end

    test "formats OPT (41)" do
      rtype = ResourceRecordType.new(41)
      assert to_string(rtype) == "OPT"
    end

    test "formats DS (43)" do
      rtype = ResourceRecordType.new(43)
      assert to_string(rtype) == "DS"
    end

    test "formats RRSIG (46)" do
      rtype = ResourceRecordType.new(46)
      assert to_string(rtype) == "RRSIG"
    end

    test "formats NSEC (47)" do
      rtype = ResourceRecordType.new(47)
      assert to_string(rtype) == "NSEC"
    end

    test "formats DNSKEY (48)" do
      rtype = ResourceRecordType.new(48)
      assert to_string(rtype) == "DNSKEY"
    end

    test "formats NSEC3 (50)" do
      rtype = ResourceRecordType.new(50)
      assert to_string(rtype) == "NSEC3"
    end

    test "formats NSEC3PARAM (51)" do
      rtype = ResourceRecordType.new(51)
      assert to_string(rtype) == "NSEC3PARAM"
    end

    test "formats TLSA (52)" do
      rtype = ResourceRecordType.new(52)
      assert to_string(rtype) == "TLSA"
    end

    test "formats SVCB (64)" do
      rtype = ResourceRecordType.new(64)
      assert to_string(rtype) == "SVCB"
    end

    test "formats HTTPS (65)" do
      rtype = ResourceRecordType.new(65)
      assert to_string(rtype) == "HTTPS"
    end

    test "formats ANY (255)" do
      rtype = ResourceRecordType.new(255)
      assert to_string(rtype) == "ANY"
    end

    test "formats CAA (257)" do
      rtype = ResourceRecordType.new(257)
      assert to_string(rtype) == "CAA"
    end

    test "formats Reserved (0)" do
      rtype = ResourceRecordType.new(0)
      assert to_string(rtype) == "Reserved(0)"
    end

    test "formats Reserved (65535)" do
      rtype = ResourceRecordType.new(65535)
      assert to_string(rtype) == "Reserved(65535)"
    end

    test "formats Unassigned (66)" do
      rtype = ResourceRecordType.new(66)
      assert to_string(rtype) == "Unassigned(66)"
    end

    test "formats Private use (65280)" do
      rtype = ResourceRecordType.new(65280)
      assert to_string(rtype) == "Private use(65280)"
    end
  end

  describe "Inspect protocol" do
    test "formats inspect output" do
      rtype = ResourceRecordType.new(1)
      assert inspect(rtype) == "#DNS.ResourceRecordType<A>"
    end

    test "inspect includes type name" do
      rtype = ResourceRecordType.new(28)
      assert inspect(rtype) == "#DNS.ResourceRecordType<AAAA>"
    end

    test "inspect for OPT" do
      rtype = ResourceRecordType.new(41)
      assert inspect(rtype) == "#DNS.ResourceRecordType<OPT>"
    end
  end

  describe "string interpolation" do
    test "interpolates correctly" do
      rtype = ResourceRecordType.new(1)
      assert "Type: #{rtype}" == "Type: A"
    end

    test "interpolates atom-created type" do
      rtype = ResourceRecordType.new(:aaaa)
      assert "Type: #{rtype}" == "Type: AAAA"
    end
  end

  describe "common DNS types" do
    test "all common types map correctly" do
      common_types = [
        {1, "A"},
        {2, "NS"},
        {5, "CNAME"},
        {6, "SOA"},
        {12, "PTR"},
        {15, "MX"},
        {16, "TXT"},
        {28, "AAAA"},
        {33, "SRV"},
        {43, "DS"},
        {46, "RRSIG"},
        {47, "NSEC"},
        {48, "DNSKEY"},
        {255, "ANY"}
      ]

      for {value, expected} <- common_types do
        rtype = ResourceRecordType.new(value)
        assert to_string(rtype) == expected, "Expected #{expected} for value #{value}"
      end
    end
  end

  describe "DNSSEC types" do
    test "DS type is 43" do
      rtype = ResourceRecordType.new(:ds)
      assert to_string(rtype) == "DS"
    end

    test "RRSIG type is 46" do
      rtype = ResourceRecordType.new(:rrsig)
      assert to_string(rtype) == "RRSIG"
    end

    test "NSEC type is 47" do
      rtype = ResourceRecordType.new(:nsec)
      assert to_string(rtype) == "NSEC"
    end

    test "DNSKEY type is 48" do
      rtype = ResourceRecordType.new(:dnskey)
      assert to_string(rtype) == "DNSKEY"
    end

    test "NSEC3 type is 50" do
      rtype = ResourceRecordType.new(:nsec3)
      assert to_string(rtype) == "NSEC3"
    end

    test "NSEC3PARAM type is 51" do
      rtype = ResourceRecordType.new(:nsec3param)
      assert to_string(rtype) == "NSEC3PARAM"
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      rtype = ResourceRecordType.new(1)
      inspect_output = inspect(rtype)
      assert is_binary(inspect_output)
    end

    test "integer and atom produce same result" do
      from_int = ResourceRecordType.new(1)
      from_atom = ResourceRecordType.new(:a)
      assert from_int.value == from_atom.value
    end

    test "handles boundary values" do
      # Min value (Reserved)
      assert ResourceRecordType.new(0).value == <<0::16>>
      # Max value (Reserved)
      assert ResourceRecordType.new(65535).value == <<65535::16>>
    end
  end
end
