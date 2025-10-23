defmodule DNS.Message.EDNS0.Option.LLQTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.LLQ

  describe "new/1" do
    test "creates LLQ option with valid data" do
      option = LLQ.new({1, 1, <<1, 2, 3, 4, 5, 6, 7, 8>>, 3600})
      assert option.code.value == <<1::16>>
      assert option.length == 18
      assert option.data == {1, 1, <<1, 2, 3, 4, 5, 6, 7, 8>>, 3600}
    end
  end

  describe "from_iodata/1" do
    test "parses LLQ option from binary" do
      binary = <<1::16, 18::16, 1::16, 1::16, 1::64, 3600::32>>
      option = LLQ.from_iodata(binary)
      assert option.code.value == <<1::16>>
      assert option.length == 18
      assert option.data == {1, 1, <<0, 0, 0, 0, 0, 0, 0, 1>>, 3600}
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts LLQ option to iodata" do
      option = LLQ.new({1, 2, <<1, 2, 3, 4, 5, 6, 7, 8>>, 1800})
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<1::16, 18::16, 1::16, 2::16, 0x0102030405060708::64, 1800::32>>
    end
  end

  describe "String.Chars protocol" do
    test "converts LLQ option to string" do
      option = LLQ.new({1, 2, <<1, 2, 3, 4, 5, 6, 7, 8>>, 1800})
      assert to_string(option) == "LLQ: v1 op2 id:0102030405060708 lease:1800s"
    end
  end
end
