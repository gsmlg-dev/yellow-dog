defmodule YellowDog.DNS.MessageTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.Question
  # alias YellowDog.DNS.Message.OpCode
  # alias YellowDog.DNS.Message.RCode
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Class

  import YellowDog.DNS.Message.NameUtils

  test "Test DNS message creation" do
    message = Message.new()

    assert %Message{} = message
  end

  test "Test DNS message update Header" do
    message =
      Message.new()
      |> Message.update_header(%Header{qr: 1})

    assert message.header.qr == 1

    message =
      message
      |> Message.update_header_attr(:rd, 1)
      |> Message.update_header_attr(:ra, 1)
      |> Message.update_header_attr(:aa, 1)

    assert message.header.rd == 1
    assert message.header.ra == 1
    assert message.header.aa == 1
  end

  test "Test DNS message add Question" do
    message =
      Message.new()
      |> Message.add_question(Question.new("a.root-servers.net", RType.a(), Class.internet()))

    assert [%Question{name: name}] = message.qdlist
    assert "a.root-servers.net." == name
  end

  test "Test DNS message parse name to buffer" do
    name = "root.com"

    buffer_name = name_to_buffer(name)

    assert buffer_name == <<4, "root", 3, "com", 0>>
  end

  test "Test DNS message get name from buffer" do
    buffer_name = <<1, "a", 12, "root-servers", 3, "net", 0, RType.a()::16, Class.internet()::16>>
    {name_size, parsed_name} = name_from_buffer(buffer_name)

    assert name_size == 20
    assert parsed_name == "a.root-servers.net."

    buffer_name = <<3, "com", 0>>

    {name_size, parsed_name} = name_from_buffer(buffer_name)

    assert name_size == 5
    assert parsed_name == "com."

    buffer_name = <<0>>

    {name_size, parsed_name} = name_from_buffer(buffer_name)

    assert name_size == 1
    assert parsed_name == "."
  end
end
