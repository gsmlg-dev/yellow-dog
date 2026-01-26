defmodule DNS.ClassTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Class.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with integer, atom, and binary values
  - Named constructor (internet/0)
  - Protocol implementations (DNS.Parameter, String.Chars, Inspect)
  - Multicast DNS cache-flush bit handling (0x8000)
  - RFC compliance for class values
  - Edge cases and boundary values
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias DNS.Class

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Class)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Class)
      assert Kernel.function_exported?(Class, :new, 1)
    end

    test "exports internet/0" do
      Code.ensure_loaded!(Class)
      assert Kernel.function_exported?(Class, :internet, 0)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Class)
      assert is_struct(Class.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      class = %Class{}
      assert Map.has_key?(class, :value)
    end

    test "default value is 16-bit zero" do
      assert %Class{}.value == <<0::16>>
    end
  end

  describe "new/1 with integer values" do
    test "creates Class from integer 1 (IN)" do
      class = Class.new(1)
      assert %Class{} = class
      assert class.value == <<1::16>>
    end

    test "creates Class from integer 3 (CH)" do
      class = Class.new(3)
      assert class.value == <<3::16>>
    end

    test "creates Class from integer 4 (HS)" do
      class = Class.new(4)
      assert class.value == <<4::16>>
    end

    test "creates Class from integer 254 (NONE)" do
      class = Class.new(254)
      assert class.value == <<254::16>>
    end

    test "creates Class from integer 255 (ANY)" do
      class = Class.new(255)
      assert class.value == <<255::16>>
    end

    test "creates Class from integer 0 (Reserved)" do
      class = Class.new(0)
      assert class.value == <<0::16>>
    end

    test "creates Class from integer 65535 (Reserved)" do
      class = Class.new(65535)
      assert class.value == <<65535::16>>
    end

    test "creates Class from mDNS cache-flush value 0x8001" do
      class = Class.new(0x8001)
      assert class.value == <<0x8001::16>>
    end
  end

  describe "new/1 with atom values" do
    test "creates Class from :in atom" do
      class = Class.new(:in)
      assert class.value == <<1::16>>
    end

    test "creates Class from :ch atom" do
      class = Class.new(:ch)
      assert class.value == <<3::16>>
    end

    test "creates Class from :hs atom" do
      class = Class.new(:hs)
      assert class.value == <<4::16>>
    end

    test "creates Class from :none atom" do
      class = Class.new(:none)
      assert class.value == <<254::16>>
    end

    test "creates Class from :any atom" do
      class = Class.new(:any)
      assert class.value == <<255::16>>
    end

    test "throws on unsupported atom" do
      assert catch_throw(Class.new(:invalid)) =~ "Unsupported atom class"
    end
  end

  describe "new/1 with binary values" do
    test "creates Class from binary value" do
      binary = <<1::16>>
      class = Class.new(binary)
      assert class.value == binary
    end

    test "creates Class from 16-bit binary" do
      binary = <<255::16>>
      class = Class.new(binary)
      assert class.value == binary
    end
  end

  describe "internet/0" do
    test "returns IN class" do
      class = Class.internet()
      assert %Class{} = class
      assert class.value == <<1::16>>
    end

    test "equals new(1)" do
      assert Class.internet() == Class.new(1)
    end

    test "equals new(:in)" do
      assert Class.internet() == Class.new(:in)
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "IN (1) displays correctly" do
      assert to_string(Class.new(1)) == "IN"
    end

    test "CH (3) displays correctly" do
      assert to_string(Class.new(3)) == "CH"
    end

    test "HS (4) displays correctly" do
      assert to_string(Class.new(4)) == "HS"
    end

    test "NONE (254) displays correctly" do
      assert to_string(Class.new(254)) == "NONE"
    end

    test "ANY (255) displays correctly" do
      assert to_string(Class.new(255)) == "ANY"
    end

    test "mDNS IN with cache-flush (0x8001) displays as IN+" do
      assert to_string(Class.new(0x8001)) == "IN+"
    end

    test "Reserved (0) displays correctly" do
      assert to_string(Class.new(0)) == "Reserved(0)"
    end

    test "Reserved (65535) displays correctly" do
      assert to_string(Class.new(65535)) == "Reserved(65535)"
    end

    test "Unassigned (2) displays correctly" do
      assert to_string(Class.new(2)) == "Unassigned(2)"
    end

    test "Unassigned range (5-253) displays correctly" do
      assert to_string(Class.new(5)) == "Unassigned(5)"
      assert to_string(Class.new(100)) == "Unassigned(100)"
      assert to_string(Class.new(253)) == "Unassigned(253)"
    end

    test "Unassigned range (256-65279) displays correctly" do
      assert to_string(Class.new(256)) == "Unassigned(256)"
      assert to_string(Class.new(32000)) == "Unassigned(32000)"
      assert to_string(Class.new(65279)) == "Unassigned(65279)"
    end

    test "Private use range (65280-65534) displays correctly" do
      assert to_string(Class.new(65280)) == "Reserved_for_Private_Use(65280)"
      assert to_string(Class.new(65400)) == "Reserved_for_Private_Use(65400)"
      assert to_string(Class.new(65534)) == "Reserved_for_Private_Use(65534)"
    end

    test "string interpolation works" do
      class = Class.internet()
      assert "Class: #{class}" == "Class: IN"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "to_iodata returns 16-bit binary" do
      class = Class.internet()
      iodata = DNS.Parameter.to_iodata(class)
      assert iodata == <<1::16>>
    end

    test "to_iodata for CH returns correct binary" do
      class = Class.new(:ch)
      iodata = DNS.Parameter.to_iodata(class)
      assert iodata == <<3::16>>
    end

    test "to_iodata for ANY returns correct binary" do
      class = Class.new(:any)
      iodata = DNS.Parameter.to_iodata(class)
      assert iodata == <<255::16>>
    end

    test "to_iodata for mDNS cache-flush returns correct binary" do
      class = Class.new(0x8001)
      iodata = DNS.Parameter.to_iodata(class)
      assert iodata == <<0x8001::16>>
    end
  end

  describe "Inspect protocol" do
    test "inspect returns formatted string" do
      class = Class.internet()
      inspect_output = inspect(class)
      assert inspect_output == "#DNS.Class<IN>"
    end

    test "inspect for CH class" do
      class = Class.new(:ch)
      assert inspect(class) == "#DNS.Class<CH>"
    end

    test "inspect for unassigned class" do
      class = Class.new(100)
      assert inspect(class) == "#DNS.Class<Unassigned(100)>"
    end

    test "inspect for private use class" do
      class = Class.new(65300)
      assert inspect(class) == "#DNS.Class<Reserved_for_Private_Use(65300)>"
    end
  end

  describe "RFC compliance" do
    test "IN class is 1 per RFC 1035" do
      assert <<1::16>> = Class.new(:in).value
    end

    test "CH class is 3 per RFC" do
      assert <<3::16>> = Class.new(:ch).value
    end

    test "HS class is 4 per RFC" do
      assert <<4::16>> = Class.new(:hs).value
    end

    test "NONE is 254 per RFC 2136" do
      assert <<254::16>> = Class.new(:none).value
    end

    test "ANY is 255 per RFC 1035" do
      assert <<255::16>> = Class.new(:any).value
    end
  end

  describe "mDNS cache-flush bit" do
    test "0x8000 is the cache-flush bit" do
      # Per RFC 6762, bit 15 indicates cache-flush
      in_class = 1
      cache_flush = 0x8000
      in_with_flush = in_class ||| cache_flush

      assert in_with_flush == 0x8001
      class = Class.new(in_with_flush)
      assert to_string(class) == "IN+"
    end

    test "cache-flush only affects high bit" do
      # Verify the class value without cache-flush is extractable
      class = Class.new(0x8001)
      <<value::16>> = class.value
      # Mask off the high bit
      base_class = value &&& 0x7FFF
      assert base_class == 1
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      class = Class.internet()
      inspect_output = inspect(class)
      assert is_binary(inspect_output)
      assert String.contains?(inspect_output, "DNS.Class")
    end

    test "all standard classes create valid structs" do
      for value <- [1, 3, 4, 254, 255] do
        class = Class.new(value)
        assert is_struct(class, Class)
      end
    end

    test "atom constructors match integer constructors" do
      assert Class.new(:in) == Class.new(1)
      assert Class.new(:ch) == Class.new(3)
      assert Class.new(:hs) == Class.new(4)
      assert Class.new(:none) == Class.new(254)
      assert Class.new(:any) == Class.new(255)
    end
  end
end
