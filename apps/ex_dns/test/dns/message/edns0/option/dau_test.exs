defmodule DNS.Message.EDNS0.Option.DAUTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.DAU.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with algorithm list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6975)
  - DNSSEC Algorithm Understood semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.DAU
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DAU)
    end

    test "exports new/1" do
      Code.ensure_loaded!(DAU)
      assert Kernel.function_exported?(DAU, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(DAU)
      assert Kernel.function_exported?(DAU, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(DAU)
      assert is_struct(DAU.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %DAU{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %DAU{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %DAU{}
      assert Map.has_key?(option, :data)
    end

    test "default code is DAU (5)" do
      option = %DAU{}
      assert option.code == OptionCode.new(5)
    end

    test "default length is nil" do
      option = %DAU{}
      assert option.length == nil
    end

    test "default data is empty list" do
      option = %DAU{}
      assert option.data == []
    end
  end

  describe "new/1" do
    test "creates DAU option with algorithm list" do
      algorithms = [8, 10, 13, 14]
      option = DAU.new(algorithms)
      assert %DAU{} = option
    end

    test "stores algorithm list" do
      algorithms = [8, 10, 13, 14]
      option = DAU.new(algorithms)
      assert option.data == algorithms
    end

    test "calculates length from list" do
      algorithms = [8, 10, 13, 14]
      option = DAU.new(algorithms)
      assert option.length == 4
    end

    test "creates DAU option with empty list" do
      option = DAU.new([])
      assert option.code.value == <<5::16>>
      assert option.length == 0
      assert option.data == []
    end

    test "creates DAU option with single algorithm" do
      option = DAU.new([8])
      assert option.code.value == <<5::16>>
      assert option.length == 1
      assert option.data == [8]
    end

    test "option code is DAU (5)" do
      option = DAU.new([8, 10])
      assert option.code.value == <<5::16>>
    end

    test "creates DAU with RSA/SHA-256 (8)" do
      option = DAU.new([8])
      assert 8 in option.data
    end

    test "creates DAU with RSA/SHA-512 (10)" do
      option = DAU.new([10])
      assert 10 in option.data
    end

    test "creates DAU with ECDSA P-256 (13)" do
      option = DAU.new([13])
      assert 13 in option.data
    end

    test "creates DAU with ECDSA P-384 (14)" do
      option = DAU.new([14])
      assert 14 in option.data
    end

    test "creates DAU with Ed25519 (15)" do
      option = DAU.new([15])
      assert 15 in option.data
    end

    test "creates DAU with Ed448 (16)" do
      option = DAU.new([16])
      assert 16 in option.data
    end

    test "creates DAU with common modern algorithms" do
      # Common modern DNSSEC algorithms
      # RSA/SHA-256, ECDSA P-256, Ed25519
      algorithms = [8, 13, 15]
      option = DAU.new(algorithms)
      assert option.data == algorithms
      assert option.length == 3
    end

    test "creates DAU with all common algorithms" do
      algorithms = [8, 10, 13, 14, 15, 16]
      option = DAU.new(algorithms)
      assert option.length == 6
    end
  end

  describe "from_iodata/1" do
    test "parses DAU option from binary" do
      binary = <<5::16, 3::16, 8, 10, 13>>
      option = DAU.from_iodata(binary)
      assert %DAU{} = option
    end

    test "parses algorithm list correctly" do
      algorithms = [8, 10, 13]
      binary = <<5::16, 3::16, 8, 10, 13>>
      option = DAU.from_iodata(binary)
      assert option.data == algorithms
    end

    test "parses length correctly" do
      binary = <<5::16, 3::16, 8, 10, 13>>
      option = DAU.from_iodata(binary)
      assert option.length == 3
    end

    test "parses empty DAU option" do
      binary = <<5::16, 0::16>>
      option = DAU.from_iodata(binary)
      assert option.code.value == <<5::16>>
      assert option.length == 0
      assert option.data == []
    end

    test "parses single algorithm" do
      binary = <<5::16, 1::16, 8>>
      option = DAU.from_iodata(binary)
      assert option.data == [8]
    end

    test "parses many algorithms" do
      algorithms = [5, 7, 8, 10, 12, 13, 14, 15, 16]
      binary_data = :binary.list_to_bin(algorithms)
      binary = <<5::16, 9::16, binary_data::binary>>
      option = DAU.from_iodata(binary)
      assert option.data == algorithms
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      algorithms = [8, 10, 13]
      option = DAU.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<5::16, 3::16, 8, 10, 13>>
    end

    test "wire format starts with option code 5" do
      option = DAU.new([8, 10])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 5
    end

    test "wire format has correct length" do
      algorithms = [8, 10, 13, 14]
      option = DAU.new(algorithms)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 4
    end

    test "encodes empty list" do
      option = DAU.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<5::16, 0::16>>
    end

    test "encodes algorithms as bytes" do
      option = DAU.new([8, 13, 15])
      <<_code::16, _length::16, rest::binary>> = DNS.Parameter.to_iodata(option)
      assert rest == <<8, 13, 15>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'DAU: [a1,a2,...]'" do
      algorithms = [8, 10, 13]
      option = DAU.new(algorithms)
      assert to_string(option) == "DAU: [8,10,13]"
    end

    test "formats empty list" do
      option = DAU.new([])
      assert to_string(option) == "DAU: []"
    end

    test "formats single algorithm" do
      option = DAU.new([8])
      assert to_string(option) == "DAU: [8]"
    end

    test "includes all algorithms" do
      algorithms = [8, 10, 13, 14, 15]
      option = DAU.new(algorithms)
      str = to_string(option)
      assert str =~ "8"
      assert str =~ "10"
      assert str =~ "13"
      assert str =~ "14"
      assert str =~ "15"
    end

    test "string interpolation works" do
      option = DAU.new([8, 13])
      result = "Option: #{option}"
      assert result =~ "DAU:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = DAU.new([8, 10, 13])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DAU.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves empty list" do
      original = DAU.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DAU.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves algorithm order" do
      # Out of order
      original = DAU.new([13, 8, 15, 10])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DAU.from_iodata(iodata)
      # Order preserved
      assert parsed.data == [13, 8, 15, 10]
    end

    test "round-trip preserves various configurations" do
      test_cases = [
        [8],
        [8, 13],
        [8, 10, 13, 14],
        [8, 10, 13, 14, 15, 16],
        Enum.to_list(1..20)
      ]

      for algorithms <- test_cases do
        original = DAU.new(algorithms)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = DAU.from_iodata(iodata)
        assert parsed.data == algorithms
      end
    end
  end

  describe "DNSSEC algorithm semantics" do
    test "RSA/MD5 is algorithm 1 (deprecated)" do
      option = DAU.new([1])
      assert 1 in option.data
    end

    test "DSA/SHA-1 is algorithm 3 (deprecated)" do
      option = DAU.new([3])
      assert 3 in option.data
    end

    test "RSA/SHA-1 is algorithm 5" do
      option = DAU.new([5])
      assert 5 in option.data
    end

    test "RSA/SHA-256 is algorithm 8 (recommended)" do
      option = DAU.new([8])
      assert 8 in option.data
    end

    test "RSA/SHA-512 is algorithm 10" do
      option = DAU.new([10])
      assert 10 in option.data
    end

    test "ECDSA P-256 with SHA-256 is algorithm 13 (recommended)" do
      option = DAU.new([13])
      assert 13 in option.data
    end

    test "ECDSA P-384 with SHA-384 is algorithm 14" do
      option = DAU.new([14])
      assert 14 in option.data
    end

    test "Ed25519 is algorithm 15 (recommended)" do
      option = DAU.new([15])
      assert 15 in option.data
    end

    test "Ed448 is algorithm 16" do
      option = DAU.new([16])
      assert 16 in option.data
    end

    test "modern secure configuration" do
      # Recommended modern DNSSEC algorithms
      modern_algorithms = [8, 13, 15]
      option = DAU.new(modern_algorithms)
      assert option.data == modern_algorithms
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = DAU.new([8, 10])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all byte values" do
      algorithms = [0, 127, 255]
      option = DAU.new(algorithms)
      assert option.data == algorithms
    end

    test "preserves order of algorithms" do
      option = DAU.new([255, 1, 128, 64])
      assert option.data == [255, 1, 128, 64]
    end

    test "handles duplicate algorithms" do
      option = DAU.new([8, 8, 13, 13])
      assert option.data == [8, 8, 13, 13]
    end

    test "handles many algorithms" do
      algorithms = Enum.to_list(1..50)
      option = DAU.new(algorithms)
      assert option.length == 50
      assert option.data == algorithms
    end
  end
end
