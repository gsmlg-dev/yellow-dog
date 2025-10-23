defmodule DNS.Message.EDNS0.Option.DHUTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.DHU

  describe "new/1" do
    test "creates DHU option with algorithm list" do
      algorithms = [1, 2, 4]
      option = DHU.new(algorithms)
      assert option.code.value == <<6::16>>
      assert option.length == 3
      assert option.data == algorithms
    end

    test "creates DHU option with empty list" do
      option = DHU.new([])
      assert option.code.value == <<6::16>>
      assert option.length == 0
      assert option.data == []
    end
  end

  describe "from_iodata/1" do
    test "parses DHU option from binary" do
      algorithms = [1, 2, 4]
      binary = <<6::16, 3::16, 1, 2, 4>>
      option = DHU.from_iodata(binary)
      assert option.code.value == <<6::16>>
      assert option.length == 3
      assert option.data == algorithms
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts DHU option to iodata" do
      algorithms = [1, 2, 4]
      option = DHU.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<6::16, 3::16, 1, 2, 4>>
    end
  end

  describe "String.Chars protocol" do
    test "converts DHU option to string" do
      algorithms = [1, 2, 4]
      option = DHU.new(algorithms)
      assert to_string(option) == "DHU: [1,2,4]"
    end
  end
end
