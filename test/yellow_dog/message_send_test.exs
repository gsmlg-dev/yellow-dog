defmodule YellowDog.MessageSendTest do
  use ExUnit.Case
  doctest YellowDog

  alias DNS.Message
  # alias DNS.Message.Header
  alias DNS.Message.Question
  alias DNS.Message.OpCode
  alias DNS.Message.RCode

  test "Test DNS message send udp" do
    q = Question.new("www.baidu.com", :a, :in)

    message =
      Message.new()
      |> Message.update_header_attr(:rcode, RCode.new(0))
      |> Message.update_header_attr(:opcode, OpCode.query())
      |> Message.add_question(q)

    buffer = DNS.to_iodata(message)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    :ok = :gen_udp.send(socket, {223, 5, 5, 5}, 53, buffer)
    {:ok, {_address, _port, data}} = :gen_udp.recv(socket, 0)

    resp_message = data |> Message.from_iodata()
    assert resp_message.header.ancount > 1

    # resp_message |> to_string() |> IO.puts()
  end

  test "Test DNS message send tcp" do
    q = Question.new("www.baidu.com", :a, :in)

    message =
      Message.new()
      |> Message.update_header_attr(:rcode, RCode.new(0))
      |> Message.update_header_attr(:opcode, OpCode.query())
      |> Message.add_question(q)

    buffer = DNS.to_iodata(message)

    {:ok, socket} = :gen_tcp.connect({223, 5, 5, 5}, 53, active: false, mode: :binary)
    :ok = :gen_tcp.send(socket, <<byte_size(buffer)::16, buffer::binary>>)
    {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2)
    {:ok, data} = :gen_tcp.recv(socket, length)

    :gen_tcp.close(socket)
    assert byte_size(data) == length

    resp_message = data |> Message.from_iodata()
    assert resp_message.header.ancount > 1

    # resp_message |> to_string() |> IO.puts()
  end
end
