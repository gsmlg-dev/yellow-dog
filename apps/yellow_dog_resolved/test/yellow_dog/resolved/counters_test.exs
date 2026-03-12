defmodule YellowDog.Resolved.CountersTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, Router}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [],
    upstream_timeout_ms: 500,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 1000,
      min_ttl_s: 5,
      max_ttl_s: 3600,
      negative_ttl_s: 30,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: [
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}
    ]
  }

  setup do
    start_supervised!(Counters)
    :ok
  end

  describe "get/0" do
    test "returns zeroed counters on fresh start" do
      counters = Counters.get()

      assert counters.intercepted == 0
      assert counters.cached == 0
      assert counters.forwarded == 0
      assert counters.error == 0
      assert counters.rate_limited == 0
      assert counters.total == 0
    end

    test "total equals sum of individual counters" do
      Counters.increment(:intercepted)
      Counters.increment(:intercepted)
      Counters.increment(:cached)
      Counters.increment(:forwarded)

      counters = Counters.get()

      assert counters.total ==
               counters.intercepted + counters.cached + counters.forwarded +
                 counters.error + counters.rate_limited

      assert counters.total == 4
    end

    test "total includes rate_limited queries" do
      Counters.increment(:intercepted)
      Counters.increment(:rate_limited)
      Counters.increment(:rate_limited)

      counters = Counters.get()

      assert counters.total == 3
      assert counters.rate_limited == 2
    end
  end

  describe "increment/1" do
    test "increments :intercepted counter" do
      assert Counters.get().intercepted == 0
      assert :ok = Counters.increment(:intercepted)
      assert Counters.get().intercepted == 1
    end

    test "increments :cached counter" do
      assert Counters.get().cached == 0
      assert :ok = Counters.increment(:cached)
      assert Counters.get().cached == 1
    end

    test "increments :forwarded counter" do
      assert Counters.get().forwarded == 0
      assert :ok = Counters.increment(:forwarded)
      assert Counters.get().forwarded == 1
    end

    test "increments :error counter" do
      assert Counters.get().error == 0
      assert :ok = Counters.increment(:error)
      assert Counters.get().error == 1
    end

    test "increments :rate_limited counter" do
      assert Counters.get().rate_limited == 0
      assert :ok = Counters.increment(:rate_limited)
      assert Counters.get().rate_limited == 1
    end

    test "increments are additive" do
      Counters.increment(:intercepted)
      Counters.increment(:intercepted)
      Counters.increment(:intercepted)

      assert Counters.get().intercepted == 3
    end
  end

  describe "started_at/0" do
    test "returns an integer" do
      assert is_integer(Counters.started_at())
    end

    test "started_at is not in the future" do
      # Monotonic time has an arbitrary epoch and may be negative.
      # started_at must be <= now (the GenServer started before this assertion).
      assert Counters.started_at() <= System.monotonic_time(:second)
    end
  end

  describe "reset/0" do
    test "resets all counters to zero" do
      Counters.increment(:intercepted)
      Counters.increment(:cached)
      Counters.increment(:forwarded)
      Counters.increment(:error)
      Counters.increment(:rate_limited)

      assert :ok = Counters.reset()

      counters = Counters.get()
      assert counters.intercepted == 0
      assert counters.cached == 0
      assert counters.forwarded == 0
      assert counters.error == 0
      assert counters.rate_limited == 0
      assert counters.total == 0
    end
  end

  describe "counter accuracy through Router" do
    setup do
      start_supervised!({Config, @test_config})
      start_supervised!({Cache, @test_config.cache})
      start_supervised!({Forwarder, @test_config})
      :ok
    end

    defp build_query(domain, type \\ :a) do
      query = DNS.Message.new()
      question = DNS.Message.Question.new(domain, type, :in)

      %{
        query
        | header: %{query.header | id: :rand.uniform(65_535), rd: 1, qdcount: 1},
          qdlist: [question]
      }
    end

    test "intercepted counter increments when query matches intercept rule" do
      before = Counters.get().intercepted
      query = build_query("myapp.test")
      Router.resolve(query)

      assert Counters.get().intercepted == before + 1
    end

    test "cached counter increments when query served from cache" do
      domain = "cached.counter.test"
      query = build_query(domain)

      # Seed the cache
      fake_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 99_999,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 1,
          opcode: query.header.opcode,
          rcode: DNS.Message.RCode.no_error(),
          qdcount: 1,
          ancount: 0,
          nscount: 0,
          arcount: 0
        },
        qdlist: query.qdlist,
        anlist: [],
        nslist: [],
        arlist: []
      }

      [question] = query.qdlist
      Cache.store(to_string(question.name), question.type, fake_response, 300)
      Process.sleep(10)

      before = Counters.get().cached
      Router.resolve(query)

      assert Counters.get().cached == before + 1
    end

    test "error counter increments when query fails (no upstreams)" do
      # Non-intercepted domain with no upstreams → SERVFAIL → error counter
      before = Counters.get().error
      query = build_query("notintercepted.example.com")
      Router.resolve(query)

      assert Counters.get().error == before + 1
    end

    test "counter invariant: total equals sum of all routing outcomes" do
      Counters.reset()

      Router.resolve(build_query("myapp.test"))
      Router.resolve(build_query("myapp.test"))
      Router.resolve(build_query("notintercepted.example.com"))

      counters = Counters.get()

      assert counters.total ==
               counters.intercepted + counters.cached + counters.forwarded +
                 counters.error + counters.rate_limited

      assert counters.total == 3
    end
  end
end
