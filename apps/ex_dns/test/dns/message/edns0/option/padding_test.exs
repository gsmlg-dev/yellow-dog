defmodule DNS.Message.EDNS0.Option.PaddingTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.Padding.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with binary data or integer length
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 7830)
  - Padding semantics for traffic analysis prevention
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Padding
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Padding)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Padding)
      assert Kernel.function_exported?(Padding, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Padding)
      assert Kernel.function_exported?(Padding, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Padding)
      assert is_struct(Padding.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %Padding{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %Padding{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %Padding{}
      assert Map.has_key?(option, :data)
    end

    test "default code is Padding (12)" do
      option = %Padding{}
      assert option.code == OptionCode.new(12)
    end

    test "default length is nil" do
      option = %Padding{}
      assert option.length == nil
    end

    test "default data is nil" do
      option = %Padding{}
      assert option.data == nil
    end
  end

  describe "new/1 with binary data" do
    test "creates Padding option with binary data" do
      padding_data = :binary.copy(<<0>>, 16)
      option = Padding.new(padding_data)
      assert %Padding{} = option
    end

    test "stores binary data" do
      padding_data = :binary.copy(<<0>>, 16)
      option = Padding.new(padding_data)
      assert option.data == padding_data
    end

    test "calculates length from binary" do
      padding_data = :binary.copy(<<0>>, 16)
      option = Padding.new(padding_data)
      assert option.length == 16
    end

    test "option code is Padding (12)" do
      option = Padding.new(<<0, 0, 0, 0>>)
      assert option.code.value == <<12::16>>
    end

    test "handles empty binary" do
      option = Padding.new(<<>>)
      assert option.length == 0
      assert option.data == <<>>
    end

    test "handles non-zero padding data" do
      # RFC allows any data, not just zeros
      padding_data = <<1, 2, 3, 4, 5>>
      option = Padding.new(padding_data)
      assert option.data == padding_data
      assert option.length == 5
    end
  end

  describe "new/1 with integer length" do
    test "creates Padding option with length" do
      option = Padding.new(32)
      assert %Padding{} = option
    end

    test "creates zero-filled padding" do
      option = Padding.new(32)
      assert option.data == :binary.copy(<<0>>, 32)
    end

    test "sets correct length" do
      option = Padding.new(32)
      assert option.length == 32
      assert byte_size(option.data) == 32
    end

    test "creates Padding option with zero length" do
      option = Padding.new(0)
      assert option.code.value == <<12::16>>
      assert option.length == 0
      assert option.data == ""
    end

    test "creates small padding (8 bytes)" do
      option = Padding.new(8)
      assert option.length == 8
      assert byte_size(option.data) == 8
    end

    test "creates medium padding (128 bytes)" do
      option = Padding.new(128)
      assert option.length == 128
      assert byte_size(option.data) == 128
    end

    test "creates large padding (512 bytes)" do
      option = Padding.new(512)
      assert option.length == 512
      assert byte_size(option.data) == 512
    end
  end

  describe "from_iodata/1" do
    test "parses Padding option from binary" do
      padding_data = :binary.copy(<<0>>, 16)
      binary = <<12::16, 16::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert %Padding{} = option
    end

    test "parses padding data correctly" do
      padding_data = :binary.copy(<<0>>, 16)
      binary = <<12::16, 16::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert option.data == padding_data
    end

    test "parses length correctly" do
      padding_data = :binary.copy(<<0>>, 16)
      binary = <<12::16, 16::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert option.length == 16
    end

    test "parses empty Padding option" do
      binary = <<12::16, 0::16>>
      option = Padding.from_iodata(binary)
      assert option.code.value == <<12::16>>
      assert option.length == 0
      assert option.data == ""
    end

    test "parses non-zero padding data" do
      padding_data = <<1, 2, 3, 4>>
      binary = <<12::16, 4::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert option.data == padding_data
    end

    test "parses large padding" do
      padding_data = :binary.copy(<<0xFF>>, 256)
      binary = <<12::16, 256::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert option.length == 256
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      padding_data = :binary.copy(<<0>>, 8)
      option = Padding.new(padding_data)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<12::16, 8::16, padding_data::binary>>
    end

    test "wire format starts with option code 12" do
      option = Padding.new(4)
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 12
    end

    test "wire format has correct length" do
      option = Padding.new(16)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == 16
    end

    test "encodes zero-length padding" do
      option = Padding.new(0)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<12::16, 0::16>>
    end

    test "encodes padding data correctly" do
      option = Padding.new(<<1, 2, 3, 4>>)
      <<_code::16, _length::16, data::binary>> = DNS.Parameter.to_iodata(option)
      assert data == <<1, 2, 3, 4>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'Padding: N bytes'" do
      option = Padding.new(16)
      assert to_string(option) == "Padding: 16 bytes"
    end

    test "formats zero bytes" do
      option = Padding.new(0)
      assert to_string(option) == "Padding: 0 bytes"
    end

    test "formats single byte" do
      option = Padding.new(1)
      assert to_string(option) == "Padding: 1 bytes"
    end

    test "formats large padding" do
      option = Padding.new(512)
      assert to_string(option) == "Padding: 512 bytes"
    end

    test "string interpolation works" do
      option = Padding.new(16)
      result = "Option: #{option}"
      assert result =~ "Padding:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = Padding.new(16)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Padding.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves empty padding" do
      original = Padding.new(0)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Padding.from_iodata(iodata)
      assert parsed.data == ""
      assert parsed.length == 0
    end

    test "round-trip preserves binary data" do
      original = Padding.new(<<1, 2, 3, 4, 5>>)
      iodata = DNS.Parameter.to_iodata(original)
      parsed = Padding.from_iodata(iodata)
      assert parsed.data == <<1, 2, 3, 4, 5>>
    end

    test "round-trip preserves various sizes" do
      for size <- [0, 1, 16, 64, 128, 256, 512] do
        original = Padding.new(size)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = Padding.from_iodata(iodata)
        assert parsed.length == size
      end
    end
  end

  describe "padding semantics" do
    test "padding prevents traffic analysis" do
      # Padding is used to obscure message size
      option = Padding.new(128)
      assert option.length == 128
    end

    test "common block sizes" do
      # Messages are often padded to block sizes
      for block_size <- [64, 128, 256, 468, 512] do
        option = Padding.new(block_size)
        assert option.length == block_size
      end
    end

    test "padding data should be ignored by receiver" do
      # Content doesn't matter, only length
      option1 = Padding.new(:binary.copy(<<0>>, 16))
      option2 = Padding.new(:binary.copy(<<0xFF>>, 16))
      assert option1.length == option2.length
    end

    test "zero-filled padding is common" do
      option = Padding.new(16)
      assert option.data == :binary.copy(<<0>>, 16)
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = Padding.new(16)
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles all-zero padding" do
      option = Padding.new(:binary.copy(<<0>>, 100))
      assert option.length == 100
    end

    test "handles all-FF padding" do
      option = Padding.new(:binary.copy(<<0xFF>>, 100))
      assert option.length == 100
    end

    test "handles random-like padding" do
      random_data = :crypto.strong_rand_bytes(32)
      option = Padding.new(random_data)
      assert option.data == random_data
      assert option.length == 32
    end

    test "handles large padding" do
      option = Padding.new(1000)
      assert option.length == 1000
    end
  end
end
