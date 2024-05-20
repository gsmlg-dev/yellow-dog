defmodule YellowDog.DNS.MessageTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.OpCode
  alias YellowDog.DNS.Message.RCode

  test "Test DNS message creation" do
    message = Message.new()

    assert %Message{} = message
  end

  test "Test DNS message parse name to buffer" do
    name = "root.com"

    buffer_name = Message.name_to_buffer(name)

    assert buffer_name == <<4, "root", 3, "com", 0>>
  end

  test "Test DNS message get name from buffer" do
    buffer_name = <<3, "com", 0>>

    parsed_name = Message.name_from_buffer(buffer_name)

    assert parsed_name == "com."

    buffer_name = <<0>>

    parsed_name = Message.name_from_buffer(buffer_name)

    assert parsed_name == "."
  end
end
