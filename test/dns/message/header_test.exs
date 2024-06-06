defmodule YellowDog.DNS.Message.HeaderTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.OpCode
  alias YellowDog.DNS.Message.RCode

  test "Test DNS message header creation" do
    header = Header.new()

    assert header.qdcount == 0

    assert header.ancount == 0

    assert header.nscount == 0

    assert header.arcount == 0
  end

  test "Test DNS message header to_buffer/from_buffer" do
    header = Header.new()

    buffer = Header.to_buffer(header)

    parsed_header = Header.from_buffer(buffer)

    assert header.id == parsed_header.id
    assert header.qr == parsed_header.qr
    assert header.opcode == parsed_header.opcode
    assert header.aa == parsed_header.aa
    assert header.tc == parsed_header.tc
  end

  test "Test DNS message header opcode" do
    header = %Header{Header.new() | opcode: OpCode.notify()}

    assert header.opcode == 4

    header = %Header{Header.new() | opcode: OpCode.update()}

    assert header.opcode == 5
  end

  test "Test DNS message header rcode" do
    header = %Header{Header.new() | rcode: RCode.nx_domain()}

    assert header.rcode == 3
  end
end
