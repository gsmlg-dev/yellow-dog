defmodule DNS.Message.EDNS0.Option.DHUTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.DHU.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with algorithm list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6975)
  - DS Hash Understood semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.DHU
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DHU)
    end

    test "exports new/1" do
      Code.ensure_loaded!(DHU)
      assert Kernel.function_exported?(DHU, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(DHU)
      assert Kernel.function_exported?(DHU, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(DHU)
      assert is_struct(DHU.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %DHU{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %DHU{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %DHU{}
      assert Map.has_key?(option, :data)
    end

    test "default code is DHU (6)" do
      option = %DHU{}
      assert option.code == OptionCode.new(6)
    end

    test "default length is nil" do
      option = %DHU{}
      assert option.length == nil
    end

    test "default data is empty list" do
      assert %DHU{}.data == []
    end
  end

  describe "new/1" do
    test "creates DHU option with algorithm list" do
      option = DHU.new([1, 2, 4])
      assert %DHU{} = option
    end

    test "stores algorithm list" do
      algorithms = [1, 2, 4]
      option = DHU.new(algorithms)
      assert option.data == algorithms
    end

    test "creates option with empty list" do
      option = DHU.new([])
      assert option.data == []
    end

    test "creates option with single algorithm" do
      option = DHU.new([2])
      assert option.data == [2]
    end

    test "creates option with SHA-1 (1)" do
      option = DHU.new([1])
      assert 1 in option.data
    end

    test "creates option with SHA-256 (2)" do
      option = DHU.new([2])
      assert 2 in option.data
    end

    test "creates option with GOST R 34.11-94 (3)" do
      option = DHU.new([3])
      assert 3 in option.data
    end

    test "creates option with SHA-384 (4)" do
      option = DHU.new([4])
      assert 4 in option.data
    end

    test "option code is DHU (6)" do
      option = DHU.new([1, 2])
      assert option.code.value == <<6::16>>
    end

    test "option length matches algorithm count" do
      option = DHU.new([1, 2, 4])
      assert option.length == 3
    end

    test "empty list has zero length" do
      option = DHU.new([])
      assert option.length == 0
    end

    test "creates option with many algorithms" do
      algorithms = Enum.to_list(1..10)
      option = DHU.new(algorithms)
      assert option.data == algorithms
      assert option.length == 10
    end
  end

  describe "from_iodata/1" do
    test "parses DHU option from binary" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert %DHU{} = option
    end

    test "parses algorithm list correctly" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert option.data == [1, 2, 4]
    end

    test "parses empty algorithm list" do
      binary = <<6::16, 0::16>>
      option = DHU.from_iodata(binary)
      assert option.data == []
    end

    test "parses single algorithm" do
      binary = <<6::16, 1::16, 2>>
      option = DHU.from_iodata(binary)
      assert option.data == [2]
    end

    test "parses length correctly" do
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert option.length == 3
    end

    test "parses all standard DS algorithms" do
      binary = <<6::16, 4::16, 1, 2, 3, 4>>
      option = DHU.from_iodata(binary)
      assert option.data == [1, 2, 3, 4]
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = DHU.new([1, 2, 4])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<6::16, 3::16, 1, 2, 4>>
    end

    test "wire format starts with option code 6" do
      option = DHU.new([1, 2])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 6
    end

    test "wire format has correct length" do
      option = DHU.new([1, 2, 4])
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 3
    end

    test "encodes empty list" do
      option = DHU.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<6::16, 0::16>>
    end

    test "encodes algorithm values as bytes" do
      option = DHU.new([1, 2, 4])
      <<_code::16, _length::16, a1, a2, a3>> = DNS.Parameter.to_iodata(option)
      assert [a1, a2, a3] == [1, 2, 4]
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'DHU: [a1,a2,...]'" do
      option = DHU.new([1, 2, 4])
      assert to_string(option) == "DHU: [1,2,4]"
    end

    test "formats empty list" do
      option = DHU.new([])
      assert to_string(option) == "DHU: []"
    end

    test "formats single algorithm" do
      option = DHU.new([2])
      assert to_string(option) == "DHU: [2]"
    end

    test "includes all algorithms" do
      option = DHU.new([1, 2, 3, 4])
      str = to_string(option)
      assert str =~ "1"
      assert str =~ "2"
      assert str =~ "3"
      assert str =~ "4"
    end

    test "string interpolation works" do
      option = DHU.new([1, 2])
      result = "Option: #{option}"
      assert result =~ "DHU:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = DHU.new([1, 2, 4])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves empty list" do
      original = DHU.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves algorithm order" do
      original = DHU.new([4, 2, 1])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = DHU.from_iodata(iodata)
      assert parsed.data == [4, 2, 1]
    end
  end

  describe "DS Hash algorithm semantics" do
    test "algorithm 1 is SHA-1" do
      option = DHU.new([1])
      assert 1 in option.data
    end

    test "algorithm 2 is SHA-256" do
      option = DHU.new([2])
      assert 2 in option.data
    end

    test "algorithm 3 is GOST R 34.11-94" do
      option = DHU.new([3])
      assert 3 in option.data
    end

    test "algorithm 4 is SHA-384" do
      option = DHU.new([4])
      assert 4 in option.data
    end

    test "common modern configuration includes SHA-256 and SHA-384" do
      option = DHU.new([2, 4])
      assert 2 in option.data
      assert 4 in option.data
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = DHU.new([1, 2])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all byte values" do
      algorithms = [0, 127, 255]
      option = DHU.new(algorithms)
      assert option.data == algorithms
    end

    test "preserves order of algorithms" do
      option = DHU.new([4, 2, 1, 3])
      assert option.data == [4, 2, 1, 3]
    end

    test "handles duplicate algorithms" do
      option = DHU.new([1, 1, 2, 2])
      assert option.data == [1, 1, 2, 2]
    end
  end
end
