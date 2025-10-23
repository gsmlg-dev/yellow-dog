defmodule DNS.Message.EDNS0.Option.N3UTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.N3U

  describe "new/1" do
    test "creates N3U option with algorithm list" do
      algorithms = [1, 2]
      option = N3U.new(algorithms)
      assert option.code.value == <<7::16>>
      assert option.length == 2
      assert option.data == algorithms
    end

    test "creates N3U option with empty list" do
      option = N3U.new([])
      assert option.code.value == <<7::16>>
      assert option.length == 0
      assert option.data == []
    end
  end

  describe "from_iodata/1" do
    test "parses N3U option from binary" do
      algorithms = [1, 2]
      binary = <<7::16, 2::16, 1, 2>>
      option = N3U.from_iodata(binary)
      assert option.code.value == <<7::16>>
      assert option.length == 2
      assert option.data == algorithms
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts N3U option to iodata" do
      algorithms = [1, 2]
      option = N3U.new(algorithms)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<7::16, 2::16, 1, 2>>
    end
  end

  describe "String.Chars protocol" do
    test "converts N3U option to string" do
      algorithms = [1, 2]
      option = N3U.new(algorithms)
      assert to_string(option) == "N3U: [1,2]"
    end
  end
end
