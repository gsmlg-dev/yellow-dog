defmodule DHCPv4.MessageTest do
  use ExUnit.Case

  test "new" do
    assert %DHCPv4.Message{} = DHCPv4.Message.new()
  end

  test "from_iodata 1" do
    raw =
      <<1, 1, 6, 0, 171, 205, 0, 217, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        44, 244, 50, 167, 213, 99, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 99, 130, 83, 99, 53, 1, 3, 57, 2, 5, 220, 50, 4, 10, 100, 10, 85, 54, 4, 10, 100, 0, 1,
        55, 12, 1, 3, 28, 6, 15, 44, 46, 47, 31, 33, 121, 43, 12, 10, 69, 83, 80, 95, 65, 55, 68,
        53, 54, 51, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>

    msg = DHCPv4.Message.from_iodata(raw)

    assert %DHCPv4.Message{} = msg

    assert 1 == msg.op
    assert 1 == msg.htype
    assert 6 == msg.hlen
    assert 0 == msg.hops
    assert 2_882_339_033 == msg.xid
    assert 0 == msg.secs
    assert 0 == msg.flags
    assert {0, 0, 0, 0} == msg.ciaddr
    assert {0, 0, 0, 0} == msg.yiaddr
    assert {0, 0, 0, 0} == msg.siaddr
    assert {0, 0, 0, 0} == msg.giaddr
    chaddr = msg.chaddr |> String.trim(<<0>>) |> Base.encode16()
    assert "2CF432A7D563" == chaddr
    assert 64 == byte_size(msg.sname)
    assert 128 == byte_size(msg.file)
    assert 6 == length(msg.options)

    # IO.inspect(msg, limit: :infinity)

    # IO.puts(msg)
  end

  test "from_iodata 2" do
    raw =
      <<1, 1, 6, 0, 9, 171, 153, 200, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        204, 249, 228, 97, 119, 104, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 99, 130, 83, 99, 53, 1, 3, 61, 7, 1, 204, 249, 228, 97, 119, 104, 55, 17, 1, 2, 6,
        12, 15, 26, 28, 121, 3, 33, 40, 41, 42, 119, 249, 252, 17, 57, 2, 2, 64, 50, 4, 10, 100,
        16, 177, 12, 13, 115, 117, 114, 102, 97, 99, 101, 45, 112, 114, 111, 45, 55, 255>>

    msg = DHCPv4.Message.from_iodata(raw)

    assert 1 == msg.op
    assert 1 == msg.htype
    assert 6 == msg.hlen
    assert 0 == msg.hops
    assert 162_240_968 == msg.xid
    assert 1 == msg.secs
    assert 0 == msg.flags
    assert {0, 0, 0, 0} == msg.ciaddr
    assert {0, 0, 0, 0} == msg.yiaddr
    assert {0, 0, 0, 0} == msg.siaddr
    assert {0, 0, 0, 0} == msg.giaddr
    chaddr = msg.chaddr |> String.trim(<<0>>) |> Base.encode16()
    assert "CCF9E4617768" == chaddr
    assert 64 == byte_size(msg.sname)
    assert 128 == byte_size(msg.file)
    assert 6 == length(msg.options)

    # IO.inspect(msg, limit: :infinity)

    # IO.puts(msg)
  end
end
