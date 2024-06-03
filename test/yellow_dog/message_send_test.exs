defmodule YellowDog.MessageSendTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.Question
  alias YellowDog.DNS.Message.OpCode
  alias YellowDog.DNS.Message.RCode
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Class

  test "Test DNS message add Question" do
    message =
      Message.new()
      |> Message.add_question(Question.new("a.root-servers.net", RType.a(), Class.internet()))

    {:ok, socket} = :gen_tcp.connect({8, 8, 8, 8}, 53, active: false)
    buffer = YellowDog.DNS.Message.to_buffer(message)
    :ok = :gen_tcp.send(socket, <<byte_size(buffer)::16, buffer::binary>>)
    {:ok, [a, b]} = :gen_tcp.recv(socket, 2)
    length = Bitwise.<<<(a, 8) |> Bitwise.bor(b)
    {:ok, data} = :gen_tcp.recv(socket, length)
    str = for byte <- data, into: <<>>, do: <<byte::8>>
    assert is_bitstring(str)
    assert is_binary(str)
    # assert <<str::binary>> == data
  end
end
