defmodule YellowDog.Worker.Dns.UpstreamTest do
  use ExUnit.Case, async: true

  alias DNS.Message
  alias DNS.Message.Record
  alias YellowDog.Worker.Dns.Upstream
  alias YellowDog.Worker.Test.FakeDnsServer

  @lo {127, 0, 0, 1}

  defp a_record(name, n),
    do: Record.new(name, <<1::16>>, <<1::16>>, 60, {10, 0, div(n, 256), rem(n, 256)})

  # Build a response to `query` with the given answers and header overrides.
  defp reply(query, answers, overrides \\ %{}) do
    header =
      Map.merge(
        %{query.header | qr: 1, ra: 1, ancount: length(answers), arcount: 0},
        overrides
      )

    DNS.to_iodata(%Message{header: header, qdlist: query.qdlist, anlist: answers})
  end

  defp start(handler) do
    {:ok, pid} = FakeDnsServer.start_link(@lo, 0, handler)
    {@lo, FakeDnsServer.port(pid)}
  end

  test "returns a normal A answer and sends EDNS0 with size 1232" do
    test = self()

    server =
      start(fn q ->
        send(test, {:query, q})
        reply(q, [a_record("example.com", 1)])
      end)

    assert {:ok, %Message{anlist: [rr]}} = Upstream.query(server, "example.com", 1, [])
    assert to_string(rr.data) =~ "10.0.0.1"
    assert_receive {:query, q}
    assert q.header.rd == 1
    assert [%{type: type, class: class}] = q.arlist
    assert type.value == <<41::16>>
    assert class.value == <<1232::16>>
  end

  test "different response id is a mismatch" do
    server = start(fn q -> reply(q, [], %{id: rem(q.header.id + 1, 65_536)}) end)
    assert {:error, :mismatch} = Upstream.query(server, "example.com", 1, [])
  end

  test "different question name is a mismatch, case is ignored" do
    other =
      start(fn q ->
        DNS.to_iodata(%Message{
          header: %{q.header | qr: 1, arcount: 0},
          qdlist: [DNS.Message.Question.new("other.com", <<1::16>>, <<1::16>>)]
        })
      end)

    assert {:error, :mismatch} = Upstream.query(other, "example.com", 1, [])

    upper =
      start(fn q ->
        DNS.to_iodata(%Message{
          header: %{q.header | qr: 1, arcount: 0},
          qdlist: [DNS.Message.Question.new("EXAMPLE.Com", <<1::16>>, <<1::16>>)]
        })
      end)

    assert {:ok, _} = Upstream.query(upper, "example.com", 1, [])
  end

  test "no reply times out" do
    server = start(fn _ -> :drop end)
    {us, result} = :timer.tc(fn -> Upstream.query(server, "example.com", 1, timeout: 200) end)
    assert result == {:error, :timeout}
    assert us >= 190_000 and us < 1_500_000
  end

  test "TC=1 over UDP retries over TCP and returns all 40 records" do
    server =
      start(fn q, {transport, _peer} ->
        case transport do
          :udp -> reply(q, [], %{tc: 1})
          :tcp -> reply(q, Enum.map(1..40, &a_record("example.com", &1)))
        end
      end)

    assert {:ok, %Message{anlist: answers}} = Upstream.query(server, "example.com", 1, [])
    assert length(answers) == 40
  end

  test "rd: false clears RD" do
    test = self()

    server =
      start(fn q ->
        send(test, {:rd, q.header.rd})
        reply(q, [])
      end)

    assert {:ok, _} = Upstream.query(server, "example.com", 1, rd: false)
    assert_receive {:rd, 0}
  end

  test "a reply from a different source port is ignored" do
    server =
      start(fn q, {:udp, peer} ->
        {cip, cport} = peer
        {:ok, other} = :gen_udp.open(0, [:binary, ip: @lo])
        :gen_udp.send(other, cip, cport, reply(q, [a_record("example.com", 1)]))
        :gen_udp.close(other)
        :drop
      end)

    assert {:error, :timeout} = Upstream.query(server, "example.com", 1, timeout: 300)
  end

  test "garbage reply is malformed" do
    server = start(fn _ -> <<1, 2, 3>> end)
    assert {:error, :malformed} = Upstream.query(server, "example.com", 1, [])
  end
end
