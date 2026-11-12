defmodule YellowDog.Worker.Dns.CacheTest do
  use ExUnit.Case, async: true

  alias DNS.Message.Record
  alias YellowDog.Worker.Dns.Cache

  defp clock_cache(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> 1_000_000 end)
    clock = fn -> Agent.get(agent, & &1) end
    advance = fn secs -> Agent.update(agent, &(&1 + secs * 1000)) end
    {Cache.new([clock: clock] ++ opts), advance}
  end

  defp a(name, ttl, ip \\ {1, 2, 3, 4}), do: Record.new(name, 1, 1, ttl, ip)

  defp soa(ttl, minimum),
    do:
      Record.new("example.com.", 6, 1, ttl, {
        DNS.Message.Domain.new("ns.example.com."),
        DNS.Message.Domain.new("admin.example.com."),
        1,
        3600,
        600,
        86_400,
        minimum
      })

  test "hit returns remaining ttl, expires after ttl" do
    {cache, advance} = clock_cache()
    rec = a("example.com.", 300)
    :ok = Cache.put(cache, "Example.COM", 1, %{rcode: 0, answers: [rec], authority: []})

    advance.(100)
    assert {:ok, %{rcode: 0, answers: [got], authority: []}} = Cache.get(cache, "example.com", 1)
    assert got.ttl <= 200 and got.ttl > 0
    assert %{got | ttl: 300} == rec

    advance.(201)
    assert :miss = Cache.get(cache, "example.com", 1)
  end

  test "positive ttl is the minimum of answers" do
    {cache, advance} = clock_cache()
    answers = [a("x.test.", 300), a("x.test.", 30, {5, 6, 7, 8})]
    Cache.put(cache, "x.test", 1, %{rcode: 0, answers: answers, authority: []})
    advance.(31)
    assert :miss = Cache.get(cache, "x.test", 1)
  end

  test "NXDOMAIN caches for SOA minimum" do
    {cache, advance} = clock_cache()
    s = soa(3600, 60)
    Cache.put(cache, "nope.example.com", 1, %{rcode: 3, answers: [], authority: [s]})

    advance.(59)

    assert {:ok, %{rcode: 3, answers: [], authority: [%{ttl: ttl}]}} =
             Cache.get(cache, "nope.example.com", 1)

    assert ttl <= 1 and ttl >= 0
    advance.(2)
    assert :miss = Cache.get(cache, "nope.example.com", 1)
  end

  test "negative ttl is bounded by SOA ttl and negative_ttl_cap" do
    {cache, advance} = clock_cache(negative_ttl_cap: 100)
    Cache.put(cache, "a.test", 1, %{rcode: 3, answers: [], authority: [soa(20, 60)]})
    Cache.put(cache, "b.test", 1, %{rcode: 0, answers: [], authority: [soa(3600, 3600)]})
    advance.(21)
    assert :miss = Cache.get(cache, "a.test", 1)
    advance.(70)
    assert {:ok, %{rcode: 0, answers: []}} = Cache.get(cache, "b.test", 1)
    advance.(20)
    assert :miss = Cache.get(cache, "b.test", 1)
  end

  test "max_ttl caps positive ttl" do
    {cache, advance} = clock_cache(max_ttl: 10)
    Cache.put(cache, "c.test", 1, %{rcode: 0, answers: [a("c.test.", 9999)], authority: []})
    advance.(11)
    assert :miss = Cache.get(cache, "c.test", 1)
  end

  test "non-A types round-trip unchanged" do
    {cache, _} = clock_cache()

    records = [
      {16, Record.new("t.test.", 16, 1, 300, ["v=spf1", "hello world"])},
      {15, Record.new("t.test.", 15, 1, 300, {10, "mx.t.test."})},
      {65,
       Record.new(
         "t.test.",
         65,
         1,
         300,
         {1, DNS.Message.Domain.new("."), <<0, 1, 0, 3, 2, 104, 50>>}
       )},
      {65_280, Record.new("t.test.", 65_280, 1, 300, <<1, 2, 3, 4, 5>>)}
    ]

    for {type, rec} <- records do
      Cache.put(cache, "t.test", type, %{rcode: 0, answers: [rec], authority: []})
      assert {:ok, %{answers: [got]}} = Cache.get(cache, "t.test", type)
      assert %{got | ttl: rec.ttl} == rec
    end
  end

  test "entry count never exceeds max_entries" do
    {cache, _} = clock_cache(max_entries: 5)

    for i <- 1..20 do
      name = "h#{i}.test"
      Cache.put(cache, name, 1, %{rcode: 0, answers: [a(name <> ".", 300)], authority: []})
      assert :ets.info(cache.table, :size) <= 5
    end

    assert {:ok, _} = Cache.get(cache, "h20.test", 1)
    assert :miss = Cache.get(cache, "h1.test", 1)
  end

  test "repeated puts at capacity stay bounded" do
    {cache, _} = clock_cache(max_entries: 100)

    for i <- 1..1_000 do
      name = "r#{i}.test"
      Cache.put(cache, name, 1, %{rcode: 0, answers: [a(name <> ".", 300)], authority: []})
      assert :ets.info(cache.table, :size) <= 100
    end

    assert {:ok, _} = Cache.get(cache, "r1000.test", 1)
  end

  test "expired entries are evicted before live ones" do
    {cache, advance} = clock_cache(max_entries: 100)

    for i <- 1..50 do
      name = "old#{i}.test"
      Cache.put(cache, name, 1, %{rcode: 0, answers: [a(name <> ".", 10)], authority: []})
    end

    advance.(11)

    for i <- 1..60 do
      name = "new#{i}.test"
      Cache.put(cache, name, 1, %{rcode: 0, answers: [a(name <> ".", 300)], authority: []})
    end

    assert :ets.info(cache.table, :size) == 60
    assert {:ok, _} = Cache.get(cache, "new1.test", 1)
  end

  test "delete drops the table" do
    {cache, _} = clock_cache()
    assert :ok = Cache.delete(cache)
    assert :undefined = :ets.info(cache.table)
  end
end
