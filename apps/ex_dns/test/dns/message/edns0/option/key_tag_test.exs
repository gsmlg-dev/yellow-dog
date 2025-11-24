defmodule DNS.Message.EDNS0.Option.KeyTagTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.KeyTag

  describe "new/1" do
    test "creates KeyTag option with key tag list" do
      key_tags = [12345, 23456, 34567]
      option = KeyTag.new(key_tags)
      assert option.code.value == <<14::16>>
      assert option.length == 6
      assert option.data == key_tags
    end

    test "creates KeyTag option with empty list" do
      option = KeyTag.new([])
      assert option.code.value == <<14::16>>
      assert option.length == 0
      assert option.data == []
    end

    test "creates KeyTag option with single key tag" do
      key_tags = [12345]
      option = KeyTag.new(key_tags)
      assert option.code.value == <<14::16>>
      assert option.length == 2
      assert option.data == key_tags
    end
  end

  describe "from_iodata/1" do
    test "parses KeyTag option from binary" do
      key_tags = [12345, 23456]
      binary = <<14::16, 4::16, 12345::16, 23456::16>>
      option = KeyTag.from_iodata(binary)
      assert option.code.value == <<14::16>>
      assert option.length == 4
      assert option.data == key_tags
    end

    test "parses empty KeyTag option" do
      binary = <<14::16, 0::16>>
      option = KeyTag.from_iodata(binary)
      assert option.code.value == <<14::16>>
      assert option.length == 0
      assert option.data == []
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts KeyTag option to iodata" do
      key_tags = [12345, 23456]
      option = KeyTag.new(key_tags)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<14::16, 4::16, 12345::16, 23456::16>>
    end
  end

  describe "String.Chars protocol" do
    test "converts KeyTag option to string" do
      key_tags = [12345, 23456]
      option = KeyTag.new(key_tags)
      assert to_string(option) == "edns-key-tag: [12345,23456]"
    end
  end
end
