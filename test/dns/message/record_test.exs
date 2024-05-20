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
end
