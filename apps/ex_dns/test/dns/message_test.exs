defmodule DNS.MessageTest do
  use ExUnit.Case

  alias DNS.Message
  alias DNS.Message.Domain
  # alias DNS.Message.Question
  # alias DNS.Message.Record
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Class

  test "DNS message query with cookie from_iodata/1" do
    raw =
      <<118, 11, 1, 32, 0, 1, 0, 0, 0, 0, 0, 1, 3, 119, 119, 119, 6, 103, 111, 111, 103, 108, 101,
        3, 99, 111, 109, 0, 0, 1, 0, 1, 0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 12, 0, 10, 0, 8, 210,
        213, 222, 136, 249, 150, 28, 88>>

    msg = Message.from_iodata(raw)

    [qd] = msg.qdlist
    [opt | _] = msg.arlist

    assert to_string(qd.name) == "www.google.com."
    assert to_string(qd.type) == "A"
    assert to_string(qd.class) == "IN"

    assert opt.name == Domain.new(".")
    assert opt.type == RRType.new(41)

    edns0 = DNS.Message.EDNS0.from_iodata(DNS.to_iodata(opt))

    assert edns0.version == 0
    assert edns0.udp_payload == 1232
    assert edns0.do_bit == 0
    assert edns0.extended_rcode == 0
    assert Enum.map(edns0.options, &to_string/1) == ["COOKIE: D2D5DE88F9961C58"]

    # IO.inspect(msg, limit: :infinity)
    # IO.puts("#{to_string(msg)}")
  end

  test "DNS message mdns response from_iodata/1" do
    raw1 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 0, 12, 49, 48, 45, 49, 48, 48, 45, 49, 48, 45, 53, 50,
        5, 108, 111, 99, 97, 108, 0, 0, 1, 128, 1, 0, 0, 14, 16, 0, 4, 10, 100, 10, 52>>

    msg = Message.from_iodata(raw1)

    [an | _rest] = msg.anlist

    assert to_string(an.name) == "10-100-10-52.local."
    assert to_string(an.type) == "A"
    assert to_string(an.class) =~ "IN"

    # IO.inspect(msg, limit: :infinity)
    # IO.puts("#{to_string(msg)}")

    raw2 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 1, 35, 69, 65, 55, 68, 57, 55, 57, 70, 66, 55, 70, 66,
        64, 74, 111, 110, 97, 116, 104, 97, 110, 39, 115, 32, 77, 97, 99, 66, 111, 111, 107, 32,
        80, 114, 111, 5, 95, 114, 97, 111, 112, 4, 95, 116, 99, 112, 5, 108, 111, 99, 97, 108, 0,
        0, 16, 128, 1, 0, 0, 17, 148, 0, 189, 10, 99, 110, 61, 48, 44, 49, 44, 50, 44, 51, 7, 100,
        97, 61, 116, 114, 117, 101, 8, 101, 116, 61, 48, 44, 51, 44, 53, 24, 102, 116, 61, 48,
        120, 52, 65, 55, 70, 67, 70, 68, 53, 44, 48, 120, 66, 56, 49, 55, 52, 70, 68, 69, 8, 115,
        102, 61, 48, 120, 50, 48, 52, 8, 109, 100, 61, 48, 44, 49, 44, 50, 17, 97, 109, 61, 77,
        97, 99, 66, 111, 111, 107, 80, 114, 111, 49, 56, 44, 52, 67, 112, 107, 61, 55, 53, 57, 56,
        97, 55, 56, 100, 98, 99, 100, 97, 54, 102, 52, 97, 57, 97, 48, 97, 97, 48, 57, 100, 102,
        55, 51, 97, 53, 100, 50, 55, 48, 57, 52, 51, 48, 52, 55, 48, 102, 49, 97, 98, 53, 102, 98,
        57, 99, 99, 52, 102, 98, 97, 52, 55, 98, 54, 54, 98, 99, 100, 54, 49, 6, 116, 112, 61, 85,
        68, 80, 8, 118, 110, 61, 54, 53, 53, 51, 55, 10, 118, 115, 61, 56, 52, 53, 46, 53, 46, 49,
        4, 118, 118, 61, 48, 192, 12, 0, 47, 128, 1, 0, 0, 17, 148, 0, 9, 192, 12, 0, 5, 0, 0,
        128, 0, 64>>

    msg = Message.from_iodata(raw2)

    [an1 | _] = msg.anlist
    [an2 | _] = msg.arlist

    assert an1.name == Domain.new("EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local.")
    assert an1.type == RRType.new(16)
    assert an1.class == Class.new(0x8001)
    assert an1.ttl == 4500

    assert an2.name.value ==
             Domain.new("EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local.").value

    assert an2.name.size == 2
    assert an2.type == RRType.new(47)
    assert an2.class == Class.new(0x8001)
    assert an2.ttl == 4500
    assert to_string(an2.data) == "EA7D979FB7FB@Jonathan's MacBook Pro._raop._tcp.local. TXT SRV"

    # IO.puts("#{to_string(msg)}")
  end

  test "DNS message [z.cn] large nslist from_iodata/1" do
    raw =
      <<44, 76, 129, 128, 0, 1, 0, 1, 0, 8, 0, 12, 1, 122, 2, 99, 110, 0, 0, 1, 0, 1, 192, 12, 0,
        1, 0, 1, 0, 0, 1, 213, 0, 4, 54, 222, 60, 252, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 20,
        3, 110, 115, 50, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99, 110, 3, 110, 101, 116, 0,
        192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 17, 3, 110, 115, 49, 10, 97, 109, 122, 110, 100,
        110, 115, 45, 99, 110, 192, 14, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 20, 3, 110, 115,
        49, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99, 110, 3, 99, 111, 109, 0, 192, 12, 0, 2,
        0, 1, 0, 0, 26, 113, 0, 20, 3, 110, 115, 50, 10, 97, 109, 122, 110, 100, 110, 115, 45, 99,
        110, 3, 98, 105, 122, 0, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 50, 192,
        86, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 50, 192, 115, 192, 12, 0, 2, 0,
        1, 0, 0, 26, 113, 0, 6, 3, 110, 115, 49, 192, 54, 192, 12, 0, 2, 0, 1, 0, 0, 26, 113, 0,
        6, 3, 110, 115, 49, 192, 147, 192, 82, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 67, 10,
        192, 82, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 32, 1, 5, 2, 70, 18, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        16, 192, 229, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 66, 10, 192, 229, 0, 28, 0, 1, 0,
        0, 4, 96, 0, 16, 38, 16, 0, 161, 16, 21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 192, 111, 0, 1, 0,
        1, 0, 0, 4, 96, 0, 4, 156, 154, 64, 10, 192, 111, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 32, 1,
        5, 2, 243, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 192, 211, 0, 1, 0, 1, 0, 0, 18, 112, 0, 4,
        156, 154, 65, 10, 192, 211, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 38, 16, 0, 161, 16, 20, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 16, 192, 175, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 204, 74, 120, 1, 192,
        175, 0, 28, 0, 1, 0, 0, 4, 96, 0, 16, 38, 16, 0, 161, 50, 209, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        83, 192, 143, 0, 1, 0, 1, 0, 0, 4, 96, 0, 4, 156, 154, 150, 1, 192, 143, 0, 28, 0, 1, 0,
        0, 4, 96, 0, 16, 38, 16, 0, 161, 49, 209, 0, 0, 0, 0, 0, 0, 0, 0, 0, 83>>

    msg = Message.from_iodata(raw)

    assert msg.header.id == 44 * 256 + 76
    assert msg.header.qdcount == 1
    assert msg.header.ancount == 1
    assert msg.header.nscount == 8
    assert msg.header.arcount == 12

    assert length(msg.anlist) == 1
    assert length(msg.nslist) == 8
    assert length(msg.arlist) == 12
    # IO.puts(msg)
  end

  test "DNS message protocol DNS.to_iodata/1" do
    raw1 =
      <<0, 0, 132, 0, 0, 0, 0, 1, 0, 0, 0, 0, 12, 49, 48, 45, 49, 48, 48, 45, 49, 48, 45, 53, 50,
        5, 108, 111, 99, 97, 108, 0, 0, 1, 128, 1, 0, 0, 14, 16, 0, 4, 10, 100, 10, 52>>

    msg = Message.from_iodata(raw1)

    iodata = DNS.to_iodata(msg)

    assert raw1 == iodata
  end
end
