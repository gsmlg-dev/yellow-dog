defmodule DNS.Message.Record.Data.OPTTest do
  use ExUnit.Case
  alias DNS.Message.Record.Data.OPT

  describe "new/1" do
    test "creates OPT record" do
      edns0 = DNS.Message.EDNS0.new()
      opt = OPT.new(edns0)

      assert opt.type.value == <<41::16>>
      assert %DNS.Message.EDNS0{} = opt.data
    end
  end

  describe "from_iodata/2" do
    test "parses OPT record" do
      # Correct EDNS0 format: root(0) type(41) udp(512) ext_rcode(0) version(0) flags(0) rdlen(0)
      raw = <<0, 0, 41, 2, 0, 0, 0, 0, 0, 0, 0>>
      opt = OPT.from_iodata(raw)

      assert opt.type.value == <<41::16>>
      assert %DNS.Message.EDNS0{} = opt.data
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts OPT record to iodata" do
      edns0 = DNS.Message.EDNS0.new()
      opt = OPT.new(edns0)
      iodata = DNS.Parameter.to_iodata(opt)

      assert is_binary(iodata)
    end
  end

  describe "String.Chars protocol" do
    test "converts OPT record to string" do
      edns0 = DNS.Message.EDNS0.new()
      opt = OPT.new(edns0)
      str = to_string(opt)

      assert is_binary(str)
    end
  end
end
