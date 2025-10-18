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

    message = Message.new()

    message = %{
      message
      | header: %{message.header | rcode: RCode.new(0), opcode: OpCode.new(OpCode.query())},
        qdlist: [q]
    }

    buffer = DNS.to_iodata(message)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    :ok = :gen_udp.send(socket, {223, 5, 5, 5}, 53, buffer)
    {:ok, {_address, _port, data}} = :gen_udp.recv(socket, 0)

    resp_message = data |> Message.from_iodata()
    # Just verify we got a response back
    assert resp_message.header.qr == 1

    # resp_message |> to_string() |> IO.puts()
  end

  test "Test DNS message send tcp" do
    q = Question.new("www.baidu.com", :a, :in)

    message = Message.new()

    message = %{
      message
      | header: %{message.header | rcode: RCode.new(0), opcode: OpCode.new(OpCode.query())},
        qdlist: [q]
    }

    buffer = DNS.to_iodata(message)

    {:ok, socket} = :gen_tcp.connect({223, 5, 5, 5}, 53, active: false, mode: :binary)
    :ok = :gen_tcp.send(socket, <<byte_size(buffer)::16, buffer::binary>>)
    {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2)
    {:ok, data} = :gen_tcp.recv(socket, length)

    :gen_tcp.close(socket)
    assert byte_size(data) == length

    resp_message = data |> Message.from_iodata()
    # Just verify we got a response back
    assert resp_message.header.qr == 1

    # resp_message |> to_string() |> IO.puts()
  end
end
