defmodule DNS.Message.EDNS0.Option.ChainTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Chain

  describe "new/1" do
    test "creates Chain option with start hash" do
      start_hash = 8
      option = Chain.new(start_hash)
      assert option.code.value == <<13::16>>
      assert option.length == 2
      assert option.data == start_hash
    end

    test "creates Chain option with zero start hash" do
      option = Chain.new(0)
      assert option.code.value == <<13::16>>
      assert option.length == 2
      assert option.data == 0
    end
  end

  describe "from_iodata/1" do
    test "parses Chain option from binary" do
      start_hash = 8
      binary = <<13::16, 2::16, start_hash::16>>
      option = Chain.from_iodata(binary)
      assert option.code.value == <<13::16>>
      assert option.length == 2
      assert option.data == start_hash
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts Chain option to iodata" do
      start_hash = 10
      option = Chain.new(start_hash)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<13::16, 2::16, start_hash::16>>
    end
  end

  describe "String.Chars protocol" do
    test "converts Chain option to string" do
      start_hash = 8
      option = Chain.new(start_hash)
      assert to_string(option) == "CHAIN: 8"
    end
  end
end
