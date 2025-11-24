defmodule DNS.Message.EDNS0.Option.ExpireTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.Expire

  describe "new/1" do
    test "creates Expire option with valid expire time" do
      expire_time = 3600
      option = Expire.new(expire_time)
      assert option.code.value == <<9::16>>
      assert option.length == 4
      assert option.data == expire_time
    end

    test "creates Expire option with zero expire time" do
      option = Expire.new(0)
      assert option.code.value == <<9::16>>
      assert option.length == 4
      assert option.data == 0
    end
  end

  describe "from_iodata/1" do
    test "parses Expire option from binary" do
      expire_time = 7200
      binary = <<9::16, 4::16, expire_time::32>>
      option = Expire.from_iodata(binary)
      assert option.code.value == <<9::16>>
      assert option.length == 4
      assert option.data == expire_time
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts Expire option to iodata" do
      expire_time = 1800
      option = Expire.new(expire_time)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<9::16, 4::16, expire_time::32>>
    end
  end

  describe "String.Chars protocol" do
    test "converts Expire option to string" do
      expire_time = 3600
      option = Expire.new(expire_time)
      assert to_string(option) == "EDNS EXPIRE: 3600s"
    end
  end
end
