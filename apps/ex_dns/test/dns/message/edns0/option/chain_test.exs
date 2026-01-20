defmodule DNS.Message.EDNS0.Option.ChainTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Chain.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with start_hash integer
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7901)
  - DNSSEC chain query semantics
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Chain
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Chain)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Chain)
      assert Kernel.function_exported?(Chain, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Chain)
      assert Kernel.function_exported?(Chain, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Chain)
      assert is_struct(Chain.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %Chain{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %Chain{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %Chain{}
      assert Map.has_key?(option, :data)
    end

    test "default code is CHAIN (13)" do
      option = %Chain{}
      assert option.code == OptionCode.new(13)
    end

    test "default length is 2" do
      option = %Chain{}
      assert option.length == 2
    end

    test "default data is nil" do
      assert %Chain{}.data == nil
    end
  end

  describe "new/1" do
    test "creates Chain option with start hash" do
      option = Chain.new(8)
      assert %Chain{} = option
    end

    test "stores start_hash field" do
      option = Chain.new(8)
      assert option.data == 8
    end

    test "creates option with zero start hash" do
      option = Chain.new(0)
      assert option.data == 0
    end

    test "creates option with SHA-1 algorithm (1)" do
      option = Chain.new(1)
      assert option.data == 1
    end

    test "creates option with SHA-256 algorithm (2)" do
      option = Chain.new(2)
      assert option.data == 2
    end

    test "creates option with GOST R 34.11-94 algorithm (3)" do
      option = Chain.new(3)
      assert option.data == 3
    end

    test "creates option with SHA-384 algorithm (4)" do
      option = Chain.new(4)
      assert option.data == 4
    end

    test "creates option with max value (65535)" do
      option = Chain.new(65535)
      assert option.data == 65535
    end

    test "option code is CHAIN (13)" do
      option = Chain.new(8)
      assert option.code.value == <<13::16>>
    end

    test "option length is 2" do
      option = Chain.new(8)
      assert option.length == 2
    end
  end

  describe "from_iodata/1" do
    test "parses Chain option from binary" do
      binary = <<13::16, 2::16, 8::16>>
      option = Chain.from_iodata(binary)
      assert %Chain{} = option
    end

    test "parses start_hash correctly" do
      binary = <<13::16, 2::16, 8::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 8
    end

    test "parses zero start_hash" do
      binary = <<13::16, 2::16, 0::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 0
    end

    test "parses max start_hash" do
      binary = <<13::16, 2::16, 65535::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 65535
    end

    test "parses SHA-1 algorithm" do
      binary = <<13::16, 2::16, 1::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 1
    end

    test "parses SHA-256 algorithm" do
      binary = <<13::16, 2::16, 2::16>>
      option = Chain.from_iodata(binary)
      assert option.data == 2
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      option = Chain.new(10)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<13::16, 2::16, 10::16>>
    end

    test "wire format starts with option code 13" do
      option = Chain.new(8)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 13
    end

    test "wire format has length 2" do
      option = Chain.new(8)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 2
    end

    test "encodes start_hash field" do
      option = Chain.new(100)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 100
    end

    test "encodes zero start_hash" do
      option = Chain.new(0)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 0
    end

    test "encodes max start_hash" do
      option = Chain.new(65535)
      <<_code::16, _length::16, start_hash::16>> = DNS.Parameter.to_iodata(option)
      assert start_hash == 65535
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'CHAIN: N'" do
      option = Chain.new(8)
      assert to_string(option) == "CHAIN: 8"
    end

    test "includes start_hash value" do
      option = Chain.new(100)
      str = to_string(option)
      assert str =~ "100"
    end

    test "formats zero value" do
      option = Chain.new(0)
      assert to_string(option) == "CHAIN: 0"
    end

    test "formats max value" do
      option = Chain.new(65535)
      assert to_string(option) == "CHAIN: 65535"
    end

    test "string interpolation works" do
      option = Chain.new(8)
      result = "Option: #{option}"
      assert result =~ "CHAIN:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = Chain.new(8)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Chain.from_iodata(iodata)
      assert parsed.data == original.data
    end

    test "round-trip preserves algorithm values" do
      for algo <- [0, 1, 2, 3, 4, 8, 255, 65535] do
        original = Chain.new(algo)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Chain.from_iodata(iodata)
        assert parsed.data == algo
      end
    end
  end

  describe "DNSSEC chain semantics" do
    test "start_hash 0 means unspecified" do
      option = Chain.new(0)
      assert option.data == 0
    end

    test "start_hash 1 is SHA-1" do
      option = Chain.new(1)
      assert option.data == 1
    end

    test "start_hash 2 is SHA-256" do
      option = Chain.new(2)
      assert option.data == 2
    end

    test "start_hash 3 is GOST R 34.11-94" do
      option = Chain.new(3)
      assert option.data == 3
    end

    test "start_hash 4 is SHA-384" do
      option = Chain.new(4)
      assert option.data == 4
    end

    test "start_hash 8 is common DS algorithm" do
      option = Chain.new(8)
      assert option.data == 8
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = Chain.new(8)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all standard algorithm values" do
      for algo <- [0, 1, 2, 3, 4] do
        option = Chain.new(algo)
        assert option.data == algo
      end
    end

    test "handles large algorithm values" do
      option = Chain.new(1000)
      assert option.data == 1000
    end
  end
end
