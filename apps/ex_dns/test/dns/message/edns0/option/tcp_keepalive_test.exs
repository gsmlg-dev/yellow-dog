defmodule DNS.Message.EDNS0.Option.TcpKeepaliveTest do
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.TcpKeepalive

  describe "new/1" do
    test "creates TcpKeepalive option with timeout" do
      timeout = 120
      option = TcpKeepalive.new(timeout)
      assert option.code.value == <<11::16>>
      assert option.length == 2
      assert option.data == timeout
    end

    test "creates TcpKeepalive option with nil timeout" do
      option = TcpKeepalive.new(nil)
      assert option.code.value == <<11::16>>
      assert option.length == 0
      assert option.data == nil
    end

    test "creates TcpKeepalive option with default nil" do
      option = TcpKeepalive.new()
      assert option.code.value == <<11::16>>
      assert option.length == 0
      assert option.data == nil
    end
  end

  describe "from_iodata/1" do
    test "parses TcpKeepalive option with timeout from binary" do
      timeout = 120
      binary = <<11::16, 2::16, timeout::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.code.value == <<11::16>>
      assert option.length == 2
      assert option.data == timeout
    end

    test "parses TcpKeepalive option without timeout from binary" do
      binary = <<11::16, 0::16>>
      option = TcpKeepalive.from_iodata(binary)
      assert option.code.value == <<11::16>>
      assert option.length == 0
      assert option.data == nil
    end
  end

  describe "DNS.Parameter protocol" do
    test "converts TcpKeepalive option with timeout to iodata" do
      timeout = 120
      option = TcpKeepalive.new(timeout)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<11::16, 2::16, timeout::16>>
    end

    test "converts TcpKeepalive option without timeout to iodata" do
      option = TcpKeepalive.new(nil)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<11::16, 0::16>>
    end
  end

  describe "String.Chars protocol" do
    test "converts TcpKeepalive option with timeout to string" do
      timeout = 120
      option = TcpKeepalive.new(timeout)
      assert to_string(option) == "edns-tcp-keepalive: 12000ms"
    end

    test "converts TcpKeepalive option without timeout to string" do
      option = TcpKeepalive.new(nil)
      assert to_string(option) == "edns-tcp-keepalive: not specified"
    end
  end
end
