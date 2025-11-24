defmodule DNS.Message.EDNS0.Option.DAUTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.DAU

  describe "new/1" do
    test "creates DAU option with algorithm list" do
      algorithms = [8, 10, 13, 14]
      option = DAU.new(algorithms)
      assert option.code.value == <<5::16>>
      assert option.length == 4
      assert option.data == algorithms
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
  end

  describe "from_iodata/1" do
    test "parses DAU option from binary" do
      algorithms = [8, 10, 13]
      binary = <<5::16, 3::16, 8, 10, 13>>
      option = DAU.from_iodata(binary)
      assert option.code.value == <<5::16>>
      assert option.length == 3
      assert option.data == algorithms
    end

    test "parses empty DAU option" do
      binary = <<5::16, 0::16>>
      option = DAU.from_iodata(binary)
      assert option.code.value == <<5::16>>
      assert option.length == 0
      assert option.data == []
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts DAU option to iodata" do
      algorithms = [8, 10, 13]
      option = DAU.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<5::16, 3::16, 8, 10, 13>>
    end
  end

  describe "String.Chars protocol" do
    test "converts DAU option to string" do
      algorithms = [8, 10, 13]
      option = DAU.new(algorithms)
      assert to_string(option) == "DAU: [8,10,13]"
    end
  end
end
