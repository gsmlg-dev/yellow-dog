defmodule DNS.Message.EDNS0.Option.PaddingTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Padding

  describe "new/1" do
    test "creates Padding option with binary data" do
      padding_data = :binary.copy(<<0>>, 16)
      option = Padding.new(padding_data)
      assert option.code.value == <<12::16>>
      assert option.length == 16
      assert option.data == padding_data
    end

    test "creates Padding option with length" do
      length = 32
      option = Padding.new(length)
      assert option.code.value == <<12::16>>
      assert option.length == 32
      assert byte_size(option.data) == 32
      assert option.data == :binary.copy(<<0>>, 32)
    end

    test "creates Padding option with zero length" do
      option = Padding.new(0)
      assert option.code.value == <<12::16>>
      assert option.length == 0
      assert option.data == ""
    end
  end

  describe "from_iodata/1" do
    test "parses Padding option from binary" do
      padding_data = :binary.copy(<<0>>, 16)
      binary = <<12::16, 16::16, padding_data::binary>>
      option = Padding.from_iodata(binary)
      assert option.code.value == <<12::16>>
      assert option.length == 16
      assert option.data == padding_data
    end

    test "parses empty Padding option" do
      binary = <<12::16, 0::16>>
      option = Padding.from_iodata(binary)
      assert option.code.value == <<12::16>>
      assert option.length == 0
      assert option.data == ""
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts Padding option to iodata" do
      padding_data = :binary.copy(<<0>>, 8)
      option = Padding.new(padding_data)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<12::16, 8::16, padding_data::binary>>
    end
  end

  describe "String.Chars protocol" do
    test "converts Padding option to string" do
      option = Padding.new(16)
      assert to_string(option) == "Padding: 16 bytes"
    end
  end
end
