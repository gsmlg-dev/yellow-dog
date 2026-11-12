defmodule YellowDog.Worker.Dns.ForwarderTest do
  use ExUnit.Case, async: true

  alias DNS.Message
  alias DNS.Message.Record
  alias YellowDog.Worker.Dns.Forwarder
  alias YellowDog.Worker.Test.FakeDnsServer

  @lo {127, 0, 0, 1}

  defp start(handler) do
    {:ok, pid} = FakeDnsServer.start_link(@lo, 0, handler)
    {@lo, FakeDnsServer.port(pid)}
  end

  defp answer(q) do
    record = Record.new("corp.test", <<1::16>>, <<1::16>>, 60, {10, 1, 2, 3})
    header = %{q.header | qr: 1, ra: 1, ancount: 1, arcount: 0}
    DNS.to_iodata(%Message{header: header, qdlist: q.qdlist, anlist: [record]})
  end

  test "a timed-out first forwarder falls through to the second, which is queried with RD=1" do
    test = self()
    silent = start(fn _ -> :drop end)

    good =
      start(fn q ->
        send(test, {:rd, q.header.rd})
        answer(q)
      end)

    assert {:ok, %Message{anlist: [rr]}} =
             Forwarder.resolve([silent, good], "corp.test", 1, timeout: 200)

    assert rr.data.data == {10, 1, 2, 3}
    assert_receive {:rd, 1}
  end

  test "every forwarder timing out is a servfail" do
    servers = [start(fn _ -> :drop end), start(fn _ -> :drop end)]
    assert {:error, :servfail} = Forwarder.resolve(servers, "corp.test", 1, timeout: 200)
  end

  test "a mismatched reply is treated as a failure and the next forwarder is tried" do
    bad = start(fn q -> answer(%{q | header: %{q.header | id: rem(q.header.id + 1, 65_536)}}) end)
    good = start(&answer/1)
    assert {:ok, _} = Forwarder.resolve([bad, good], "corp.test", 1, timeout: 200)
  end

  test "an empty forwarder list is a servfail" do
    assert {:error, :servfail} = Forwarder.resolve([], "corp.test", 1, [])
  end
end
