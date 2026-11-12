defmodule YellowDog.Worker.Dns.RecursorTest do
  use ExUnit.Case, async: true

  alias DNS.Message
  alias DNS.Message.{Domain, Record}
  alias YellowDog.Worker.Dns.{Cache, Recursor, RootHints}
  alias YellowDog.Worker.Test.FakeDnsServer

  @root {127, 0, 0, 10}
  @tld {127, 0, 0, 11}
  @leaf {127, 0, 0, 12}
  @evil {127, 0, 0, 66}

  @https {1, Domain.new("."), <<0, 1, 0, 3, 2, 104, 50>>}

  # A fake three-level hierarchy on one shared port:
  #   127.0.0.10  root      -> refers test. to ns.test (glue 127.0.0.11)
  #   127.0.0.11  test.     -> refers example.test (in-zone glue + out-of-bailiwick ns.evil. glue),
  #                            noglue.test (NS ns.other.test, no glue), ping.test <-> pong.test;
  #                            authoritative for other.test and loop.test
  #   127.0.0.12  example.test. and noglue.test.
  #   127.0.0.66  must never be queried
  setup do
    port = start_hierarchy(self(), 5)
    %{opts: [root_hints: [{@root, port}], port: port]}
  end

  # All four servers share one port; if the root's port is taken on another
  # loopback address, start over on a new port.
  defp start_hierarchy(test, attempts) do
    {:ok, root} = FakeDnsServer.start_link(@root, 0, recorder(test, @root, &root/1))
    port = FakeDnsServer.port(root)

    started =
      Enum.reduce_while([{@tld, &tld/1}, {@leaf, &leaf/1}, {@evil, &evil/1}], [], fn
        {ip, handler}, acc ->
          case FakeDnsServer.start(ip, port, recorder(test, ip, handler)) do
            {:ok, pid} -> {:cont, [pid | acc]}
            {:error, _} -> {:halt, {:error, acc}}
          end
      end)

    case started do
      {:error, pids} when attempts > 1 ->
        Enum.each([root | pids], &GenServer.stop/1)
        start_hierarchy(test, attempts - 1)

      pids when is_list(pids) ->
        Enum.each(pids, &Process.link/1)
        port
    end
  end

  test "www.example.test A is resolved through root, test. and example.test.", %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [answer], authority: []}} =
             Recursor.resolve("www.example.test", 1, opts)

    assert to_string(answer.name) == "www.example.test."
    assert answer.data.data == {192, 0, 2, 80}
    assert Enum.map(queries(), fn {ip, _, _, _} -> ip end) == [@root, @tld, @leaf]
  end

  test "a CNAME whose target is in the same answer returns [CNAME, A]", %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [cname, a]}} =
             Recursor.resolve("alias.example.test", 1, opts)

    assert cname.type.value == <<5::16>>
    assert to_string(cname.data) =~ "www.example.test"
    assert a.data.data == {192, 0, 2, 80}
    assert_rd_zero()
  end

  test "a CNAME whose target is elsewhere is re-resolved and the chain is returned in order",
       %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [cname, a]}} =
             Recursor.resolve("chain.example.test", 1, opts)

    assert cname.type.value == <<5::16>>
    assert to_string(a.name) == "www.noglue.test."
    assert a.data.data == {192, 0, 2, 81}
    assert_rd_zero()
  end

  test "a missing name is NXDOMAIN with the zone SOA in authority", %{opts: opts} do
    assert {:ok, %{rcode: 3, answers: [], authority: [soa]}} =
             Recursor.resolve("missing.example.test", 1, opts)

    assert soa.type.value == <<6::16>>
    assert to_string(soa.name) == "example.test."
    assert_rd_zero()
  end

  test "NODATA is NOERROR with no answers and the zone SOA", %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [], authority: [soa]}} =
             Recursor.resolve("www.example.test", 28, opts)

    assert soa.type.value == <<6::16>>
  end

  test "out-of-bailiwick glue is ignored", %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [_]}} = Recursor.resolve("www.example.test", 1, opts)
    refute Enum.any?(queries(), fn {ip, _, _, _} -> ip == @evil end)
  end

  test "a glueless NS name is resolved first, then resolution continues", %{opts: opts} do
    assert {:ok, %{rcode: 0, answers: [a]}} = Recursor.resolve("www.noglue.test", 1, opts)
    assert a.data.data == {192, 0, 2, 81}

    assert Enum.map(queries(), fn {ip, name, type, _} -> {ip, name, type} end) == [
             {@root, "www.noglue.test", 1},
             {@tld, "www.noglue.test", 1},
             {@root, "ns.other.test", 1},
             {@tld, "ns.other.test", 1},
             {@leaf, "www.noglue.test", 1}
           ]
  end

  test "records outside the query name and CNAME chain are dropped", %{opts: opts} do
    assert {:ok, %{answers: answers}} = Recursor.resolve("www.example.test", 1, opts)
    assert Enum.map(answers, &to_string(&1.name)) == ["www.example.test."]
  end

  test "a CNAME loop is a servfail and finishes quickly", %{opts: opts} do
    {micros, result} = :timer.tc(fn -> Recursor.resolve("a.loop.test", 1, opts) end)
    assert result == {:error, :servfail}
    assert micros < 1_000_000
    assert_rd_zero()
  end

  test "mutual glueless referrals are a servfail within max_steps", %{opts: opts} do
    opts = Keyword.put(opts, :max_steps, 20)
    {micros, result} = :timer.tc(fn -> Recursor.resolve("www.ping.test", 1, opts) end)
    assert result == {:error, :servfail}
    assert micros < 1_000_000
    sent = queries()
    assert length(sent) <= 20
    assert Enum.all?(sent, fn {_, _, _, rd} -> rd == 0 end)
  end

  test "an exhausted deadline is a servfail" do
    {:ok, silent} = FakeDnsServer.start_link(@root, 0, fn _ -> :drop end)
    opts = [root_hints: [{@root, FakeDnsServer.port(silent)}], deadline_ms: 300]
    {micros, result} = :timer.tc(fn -> Recursor.resolve("www.example.test", 1, opts) end)
    assert result == {:error, :servfail}
    assert micros < 1_000_000
  end

  test "TXT, MX, HTTPS and type 65280 answers come back unchanged", %{opts: opts} do
    for type <- [16, 15, 65, 65_280] do
      assert {:ok, %{rcode: 0, answers: [record]}} =
               Recursor.resolve("t.example.test", type, opts)

      expected = typed_record(type)
      assert record.type.value == <<type::16>>
      assert to_string(record.name) == "t.example.test."
      assert record.ttl == expected.ttl
      assert DNS.to_iodata(record.data) == DNS.to_iodata(expected.data)
    end

    assert_rd_zero()
  end

  test "referral NS and glue are cached and reused", %{opts: opts} do
    cache = Cache.new()
    opts = Keyword.put(opts, :cache, cache)
    assert {:ok, _} = Recursor.resolve("www.example.test", 1, opts)
    queries()
    assert {:ok, %{answers: [_, _]}} = Recursor.resolve("alias.example.test", 1, opts)
    assert Enum.map(queries(), fn {ip, _, _, _} -> ip end) == [@leaf]
  end

  test "root hints list the 13 IANA root servers" do
    servers = RootHints.servers()
    assert length(servers) == 13
    assert {"a.root-servers.net", {198, 41, 0, 4}, _} = hd(servers)
    assert Enum.all?(servers, fn {_, {_, _, _, _}, {_, _, _, _, _, _, _, _}} -> true end)
  end

  ## fake servers

  defp recorder(test, ip, handler) do
    fn q ->
      [question] = q.qdlist
      name = question.name |> to_string() |> String.trim_trailing(".") |> String.downcase()
      <<type::16>> = question.type.value
      send(test, {:query, ip, name, type, q.header.rd})
      handler.({q, name, type})
    end
  end

  defp root({q, _name, _type}) do
    referral(q, "test", [{"ns.test", {127, 0, 0, 11}}])
  end

  defp tld({q, name, type}) do
    cond do
      under?(name, "example.test") ->
        referral(q, "example.test", [
          {"ns.example.test", {127, 0, 0, 12}},
          {"ns.evil", {127, 0, 0, 66}}
        ])

      under?(name, "noglue.test") ->
        referral(q, "noglue.test", [{"ns.other.test", nil}])

      under?(name, "ping.test") ->
        referral(q, "ping.test", [{"ns.pong.test", nil}])

      under?(name, "pong.test") ->
        referral(q, "pong.test", [{"ns.ping.test", nil}])

      name == "ns.other.test" and type == 1 ->
        reply(q, 0, [rr("ns.other.test", 1, {127, 0, 0, 12})])

      name == "a.loop.test" ->
        reply(q, 0, [rr("a.loop.test", 5, "b.loop.test.")])

      name == "b.loop.test" ->
        reply(q, 0, [rr("b.loop.test", 5, "a.loop.test.")])

      true ->
        reply(q, 3, [], [soa("test")])
    end
  end

  defp leaf({q, name, type}) do
    case {name, type} do
      {"www.example.test", 1} ->
        reply(q, 0, [rr("junk.example.test", 1, {192, 0, 2, 99}), www()])

      {"www.example.test", _} ->
        reply(q, 0, [], [soa("example.test")])

      {"alias.example.test", 1} ->
        reply(q, 0, [rr("alias.example.test", 5, "www.example.test."), www()])

      {"chain.example.test", 1} ->
        # Target is out of this server's zone: the A here must not be trusted.
        reply(q, 0, [
          rr("chain.example.test", 5, "www.noglue.test."),
          rr("www.noglue.test", 1, {6, 6, 6, 6})
        ])

      {"t.example.test", type} when type in [16, 15, 65, 65_280] ->
        reply(q, 0, [typed_record(type)])

      {"www.noglue.test", 1} ->
        reply(q, 0, [rr("www.noglue.test", 1, {192, 0, 2, 81})])

      _ ->
        reply(q, 3, [], [soa("example.test")])
    end
  end

  defp evil({q, name, _type}), do: reply(q, 0, [rr(name, 1, {6, 6, 6, 6})])

  defp www, do: rr("www.example.test", 1, {192, 0, 2, 80})

  defp typed_record(16), do: rr("t.example.test", 16, ["v=spf1", "hello world"])
  defp typed_record(15), do: rr("t.example.test", 15, {10, "mx.example.test."})
  defp typed_record(65), do: rr("t.example.test", 65, @https)
  defp typed_record(65_280), do: rr("t.example.test", 65_280, <<1, 2, 3, 4, 5>>)

  defp under?(name, zone), do: name == zone or String.ends_with?(name, "." <> zone)

  defp referral(q, zone, servers) do
    ns = Enum.map(servers, fn {host, _} -> rr(zone, 2, host <> ".") end)
    glue = for {host, ip} <- servers, ip != nil, do: rr(host, 1, ip)
    reply(q, 0, [], ns, glue)
  end

  defp soa(zone) do
    rr(
      zone,
      6,
      {Domain.new("ns." <> zone), Domain.new("hostmaster." <> zone), 1, 3600, 600, 86_400, 300}
    )
  end

  defp rr(name, type, data), do: Record.new(name, type, 1, 300, data)

  defp reply(q, rcode, answers, authority \\ [], additional \\ []) do
    header = %{
      q.header
      | qr: 1,
        aa: if(authority == [] or additional == [], do: 1, else: 0),
        rcode: DNS.Message.RCode.new(rcode),
        ancount: length(answers),
        nscount: length(authority),
        arcount: length(additional)
    }

    DNS.to_iodata(%Message{
      header: header,
      qdlist: q.qdlist,
      anlist: answers,
      nslist: authority,
      arlist: additional
    })
  end

  ## assertions

  defp queries(acc \\ []) do
    receive do
      {:query, ip, name, type, rd} -> queries([{ip, name, type, rd} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_rd_zero do
    sent = queries()
    assert sent != []
    assert Enum.all?(sent, fn {_, _, _, rd} -> rd == 0 end)
  end
end
