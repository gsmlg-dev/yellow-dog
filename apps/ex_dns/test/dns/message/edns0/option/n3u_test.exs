defmodule DNS.Message.EDNS0.Option.N3UTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.N3U.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with algorithm list
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6975)
  - NSEC3 Hash Understood semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.N3U
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(N3U)
    end

    test "exports new/1" do
      Code.ensure_loaded!(N3U)
      assert Kernel.function_exported?(N3U, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(N3U)
      assert Kernel.function_exported?(N3U, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(N3U)
      assert is_struct(N3U.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %N3U{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %N3U{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %N3U{}
      assert Map.has_key?(option, :data)
    end

    test "default code is N3U (7)" do
      option = %N3U{}
      assert option.code == OptionCode.new(7)
    end

    test "default length is nil" do
      option = %N3U{}
      assert option.length == nil
    end

    test "default data is empty list" do
      assert %N3U{}.data == []
    end
  end

  describe "new/1" do
    test "creates N3U option with algorithm list" do
      option = N3U.new([1, 2])
      assert %N3U{} = option
    end

    test "stores algorithm list" do
      algorithms = [1, 2]
      option = N3U.new(algorithms)
      assert option.data == algorithms
    end

    test "creates option with empty list" do
      option = N3U.new([])
      assert option.data == []
    end

    test "creates option with single algorithm" do
      option = N3U.new([1])
      assert option.data == [1]
    end

    test "creates option with SHA-1 (1)" do
      option = N3U.new([1])
      assert 1 in option.data
    end

    test "option code is N3U (7)" do
      option = N3U.new([1, 2])
      assert option.code.value == <<7::16>>
    end

    test "option length matches algorithm count" do
      option = N3U.new([1, 2])
      assert option.length == 2
    end

    test "empty list has zero length" do
      option = N3U.new([])
      assert option.length == 0
    end

    test "creates option with many algorithms" do
      algorithms = Enum.to_list(1..5)
      option = N3U.new(algorithms)
      assert option.data == algorithms
      assert option.length == 5
    end
  end

  describe "from_iodata/1" do
    test "parses N3U option from binary" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert %N3U{} = option
    end

    test "parses algorithm list correctly" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert option.data == [1, 2]
    end

    test "parses empty algorithm list" do
      binary = <<7::16, 0::16>>
      option = N3U.from_iodata(binary)
      assert option.data == []
    end

    test "parses single algorithm" do
      binary = <<7::16, 1::16, 1>>
      option = N3U.from_iodata(binary)
      assert option.data == [1]
    end

    test "parses length correctly" do
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert option.length == 2
    end

    test "parses multiple algorithms" do
      binary = <<7::16, 3::16, 1, 2, 3>>
      option = N3U.from_iodata(binary)
      assert option.data == [1, 2, 3]
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = N3U.new([1, 2])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<7::16, 2::16, 1, 2>>
    end

    test "wire format starts with option code 7" do
      option = N3U.new([1, 2])
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 7
    end

    test "wire format has correct length" do
      option = N3U.new([1, 2])
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2
    end

    test "encodes empty list" do
      option = N3U.new([])
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<7::16, 0::16>>
    end

    test "encodes algorithm values as bytes" do
      option = N3U.new([1, 2])
      <<_code::16, _length::16, a1, a2>> = DNS.Parameter.to_iodata(option)
      assert [a1, a2] == [1, 2]
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'N3U: [a1,a2,...]'" do
      option = N3U.new([1, 2])
      assert to_string(option) == "N3U: [1,2]"
    end

    test "formats empty list" do
      option = N3U.new([])
      assert to_string(option) == "N3U: []"
    end

    test "formats single algorithm" do
      option = N3U.new([1])
      assert to_string(option) == "N3U: [1]"
    end

    test "includes all algorithms" do
      option = N3U.new([1, 2, 3])
      str = to_string(option)
      assert str =~ "1"
      assert str =~ "2"
      assert str =~ "3"
    end

    test "string interpolation works" do
      option = N3U.new([1, 2])
      result = "Option: #{option}"
      assert result =~ "N3U:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = N3U.new([1, 2])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves empty list" do
      original = N3U.new([])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == []
    end

    test "round-trip preserves algorithm order" do
      original = N3U.new([2, 1])
      iodata = DNS.Parameter.to_iodata(original)
      parsed = N3U.from_iodata(iodata)
      assert parsed.data == [2, 1]
    end
  end

  describe "NSEC3 Hash algorithm semantics" do
    test "algorithm 1 is SHA-1" do
      option = N3U.new([1])
      assert 1 in option.data
    end

    test "SHA-1 is currently the only defined NSEC3 hash" do
      # Per RFC 5155, SHA-1 (1) is the only defined hash algorithm
      option = N3U.new([1])
      assert option.data == [1]
    end

    test "common configuration includes SHA-1" do
      option = N3U.new([1])
      assert 1 in option.data
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = N3U.new([1, 2])
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all byte values" do
      algorithms = [0, 127, 255]
      option = N3U.new(algorithms)
      assert option.data == algorithms
    end

    test "preserves order of algorithms" do
      option = N3U.new([2, 1])
      assert option.data == [2, 1]
    end

    test "handles duplicate algorithms" do
      option = N3U.new([1, 1])
      assert option.data == [1, 1]
    end
  end
end
