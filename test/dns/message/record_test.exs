defmodule YellowDog.DNS.Message.RecordTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message.Record
  alias YellowDog.DNS.Class
  alias YellowDog.DNS.ResourceRecord.Type, as: RType

  test "Test DNS message record creation" do
    record = Record.new("a.root-servers.net", RType.a(), Class.internet(), 3600, {198, 41, 0, 4})

    assert %Record{
             name: "a.root-servers.net.",
             type: 1,
             class: 1,
             ttl: 3600,
             data: {198, 41, 0, 4}
           } = record
  end

  test "Test DNS message record a to_buffer/from_buffer" do
    record = Record.new("a.root-servers.net", RType.a(), Class.internet(), 3600, {198, 41, 0, 4})

    buffer = Record.to_buffer(record)

    assert <<1, "a", 12, "root-servers", 3, "net", 0, 1::16, 1::16, 3600::32, 4::16, 198, 41, 0,
             4>> = buffer
  end

  test "Test DNS message record a list from message" do
    # buffer from dig www.baidu.com
    message =
      <<229, 158, 129, 128, 0, 1, 0, 3, 0, 0, 0, 1, 3, 119, 119, 119, 5, 98, 97, 105, 100, 117, 3,
        99, 111, 109, 0, 0, 1, 0, 1, 192, 12, 0, 5, 0, 1, 0, 0, 3, 186, 0, 15, 3, 119, 119, 119,
        1, 97, 6, 115, 104, 105, 102, 101, 110, 192, 22, 192, 43, 0, 1, 0, 1, 0, 0, 0, 54, 0, 4,
        182, 61, 200, 7, 192, 43, 0, 1, 0, 1, 0, 0, 0, 54, 0, 4, 182, 61, 200, 6, 0, 0, 41, 16, 0,
        0, 0, 0, 0, 0, 11, 0, 8, 0, 7, 0, 1, 20, 0, 114, 249, 112>>

    {size, records} = Record.list_from_message(3, message, 31)

    assert length(records) == 3

    first = hd(records)
    second = Enum.at(records, 1)
    third = List.last(records)

    cname = RType.cname()
    a = RType.a()

    assert 59 = size

    assert %Record{
             name: "www.baidu.com.",
             type: ^cname,
             class: 1,
             ttl: 954,
             data: "www.a.shifen.com."
           } = first

    assert %Record{
             name: "www.a.shifen.com.",
             type: ^a,
             class: 1,
             ttl: 54,
             data: {182, 61, 200, 7}
           } = second

    assert %Record{
             name: "www.a.shifen.com.",
             type: ^a,
             class: 1,
             ttl: 54,
             data: {182, 61, 200, 6}
           } = third

    {size, records} = Record.list_from_message(1, message, 31 + size)

    assert 22 = size

    first = hd(records)

    opt = RType.opt()

    assert %Record{
             name: ".",
             type: ^opt,
             class: _,
             ttl: _,
             data: data
           } = first

    assert <<0, 8, 0, 7, 0, 1, 20, 0, 114, 249, 112>> = data
  end
end
