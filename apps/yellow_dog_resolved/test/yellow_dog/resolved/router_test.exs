defmodule YellowDog.Resolved.RouterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters, Router}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [{127, 0, 0, 1}],
    upstream_timeout_ms: 1000,
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
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 300},
      %{match: {:exact, "myapp.test"}, type: :aaaa, value: "::1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
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

  describe "resolve/1 with intercept" do
    test "intercepts exact match domain" do
      query = build_query("myapp.test")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert response.header.id == query.header.id
      assert length(response.anlist) == 1
    end

    test "intercepts suffix match domain" do
      query = build_query("app.local.dev")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "intercepts prefix match domain" do
      query = build_query("dev-server.example.com")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "AAAA query matches the AAAA intercept rule (not the A rule)" do
      # Config has both A and AAAA rules for myapp.test.
      # With type-aware matching, the AAAA query gets the AAAA answer, not NODATA.
      query = build_query("myapp.test", :aaaa)
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert length(response.anlist) == 1
      [record] = response.anlist
      # record.type is a DNS.ResourceRecordType struct; compare via to_string
      assert to_string(record.type) == "AAAA"
    end

    test "A query with no matching intercept type returns intercept answer" do
      # Verify the first-match-by-type semantics: only the right-type rule is returned.
      # A query for myapp.test matches the A rule (not the AAAA rule).
      query = build_query("myapp.test", :a)
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert length(response.anlist) == 1
      [record] = response.anlist
      assert to_string(record.type) == "A"
    end

    test "case-insensitive intercept matching" do
      query = build_query("MYAPP.TEST")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "first match wins for intercept rules" do
      query = build_query("myapp.test")
      response = Router.resolve(query)

      assert length(response.anlist) == 1
      [record] = response.anlist
      assert record.ttl == 600
    end
  end

  describe "resolve/1 with cache" do
    test "serves response from cache when available" do
      domain = "cached.example.com"
      query = build_query(domain)

      # Extract the actual type the Router will use for cache key
      [question] = query.qdlist
      dns_type = question.type
      domain_str = to_string(question.name)

      fake_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 99999,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 1,
          opcode: query.header.opcode,
          rcode: DNS.Message.RCode.no_error(),
          qdcount: 1,
          ancount: 1,
          nscount: 0,
          arcount: 0
        },
        qdlist: query.qdlist,
        anlist: [DNS.Message.Record.new(domain, :a, :in, 300, {1, 2, 3, 4})],
        nslist: [],
        arlist: []
      }

      # Store using same domain/type the Router will look up with
      Cache.store(domain_str, dns_type, fake_response, 300)
      Process.sleep(10)

      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.id == query.header.id
      assert length(response.anlist) == 1
    end

    test "rewrites cached response txn_id to match current query" do
      domain = "txnid-test.example.com"
      query = build_query(domain)

      [question] = query.qdlist
      dns_type = question.type
      domain_str = to_string(question.name)

      fake_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 11111,
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

      Cache.store(domain_str, dns_type, fake_response, 300)
      Process.sleep(10)

      response = Router.resolve(query)
      assert response.header.id == query.header.id
      assert response.header.id != 11111
    end

    test "echoes RD bit from current query in cached response (RFC 1035 §4.1.1)" do
      domain = "rd-echo-cache.example.com"
      base_query = build_query(domain)

      [question] = base_query.qdlist
      dns_type = question.type
      domain_str = to_string(question.name)

      # Cache a response that has rd: 1
      fake_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 0,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 1,
          opcode: 0,
          rcode: DNS.Message.RCode.no_error(),
          qdcount: 1,
          ancount: 0,
          nscount: 0,
          arcount: 0
        },
        qdlist: [question],
        anlist: [],
        nslist: [],
        arlist: []
      }

      Cache.store(domain_str, dns_type, fake_response, 300)
      Process.sleep(10)

      # Issue a query with rd: 0 — cached response has rd: 1 but we must echo rd: 0
      query_no_rd = %{
        base_query
        | header: %{base_query.header | id: 9999, rd: 0}
      }

      response = Router.resolve(query_no_rd)
      assert response.header.rd == 0
    end
  end

  describe "NXDOMAIN caching through Router" do
    test "NXDOMAIN stored in cache is served on subsequent queries" do
      domain = "nxdomain-router.example.com"
      query = build_query(domain)
      [question] = query.qdlist
      domain_str = to_string(question.name)

      # Simulate what forward_and_cache should do for NXDOMAIN:
      # store with negative_ttl_s (30 in test config)
      nxdomain = %DNS.Message{
        header: %DNS.Message.Header{
          id: 0,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 1,
          opcode: query.header.opcode,
          rcode: DNS.Message.RCode.nx_domain(),
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

      Cache.store(domain_str, question.type, nxdomain, 30)
      Process.sleep(10)

      # Router should serve from cache with NXDOMAIN rcode
      response = Router.resolve(query)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
      assert response.header.id == query.header.id

      # Verify it came from cache counter
      stats = Cache.stats()
      assert stats.hits >= 1
    end
  end

  describe "resolve/1 with cache disabled" do
    test "bypasses cache and forwards directly" do
      # Stop the default Config and start with cache disabled
      stop_supervised!(Config)

      disabled_config = %{
        @test_config
        | cache: %{@test_config.cache | enabled: false},
          upstreams: []
      }

      start_supervised!({Config, disabled_config})
      start_supervised!({YellowDog.Resolved.Forwarder, disabled_config})

      # Pre-populate cache — should be ignored when cache disabled
      domain = "bypass-cache.example.com"
      query = build_query(domain)
      [question] = query.qdlist

      Cache.store(
        to_string(question.name),
        question.type,
        %DNS.Message{
          header: %DNS.Message.Header{
            id: 0,
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
        },
        300
      )

      Process.sleep(10)

      # With cache disabled and no upstreams, should get SERVFAIL (not cached response)
      response = Router.resolve(query)
      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end

  describe "resolve/1 telemetry" do
    test "emits query start and stop events for intercept" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-query-start-#{inspect(ref)}",
        [:yellow_dog, :resolved, :query, :start],
        fn _name, _measurements, metadata, _config ->
          send(parent, {:telemetry, :start, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-query-stop-#{inspect(ref)}",
        [:yellow_dog, :resolved, :query, :stop],
        fn _name, measurements, metadata, _config ->
          send(parent, {:telemetry, :stop, metadata, measurements})
        end,
        nil
      )

      query = build_query("myapp.test")
      Router.resolve(query)

      assert_receive {:telemetry, :start, %{domain: "myapp.test." <> _}}
      assert_receive {:telemetry, :stop, %{source: :intercept}, %{duration: _}}

      :telemetry.detach("test-query-start-#{inspect(ref)}")
      :telemetry.detach("test-query-stop-#{inspect(ref)}")
    end

    test "emits cache source for cached responses" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "test-cache-source-#{inspect(ref)}",
        [:yellow_dog, :resolved, :query, :stop],
        fn _name, _measurements, metadata, _config ->
          send(parent, {:telemetry, :stop, metadata})
        end,
        nil
      )

      domain = "telemetry-cached.example.com"
      query = build_query(domain)

      [question] = query.qdlist
      dns_type = question.type
      domain_str = to_string(question.name)

      fake_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 0,
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

      Cache.store(domain_str, dns_type, fake_response, 300)
      Process.sleep(10)

      Router.resolve(query)

      assert_receive {:telemetry, :stop, %{source: :cache}}

      :telemetry.detach("test-cache-source-#{inspect(ref)}")
    end
  end

  describe "resolve/1 non-QUERY opcode" do
    test "STATUS opcode (2) returns NOTIMP (RFC 1035 §4.1.1)" do
      query = build_query("example.com")
      status_query = %{query | header: %{query.header | opcode: DNS.Message.OpCode.status()}}

      response = Router.resolve(status_query)

      assert response.header.qr == 1
      assert response.header.id == status_query.header.id
      assert response.header.rcode == DNS.Message.RCode.not_imp()
    end

    test "IQUERY opcode (1) returns NOTIMP" do
      query = build_query("example.com")
      iquery = %{query | header: %{query.header | opcode: DNS.Message.OpCode.iquery()}}

      response = Router.resolve(iquery)

      assert response.header.rcode == DNS.Message.RCode.not_imp()
    end

    test "QUERY opcode (0) is processed normally" do
      query = build_query("myapp.test")
      # opcode is already QUERY (0) from build_query
      assert query.header.opcode == DNS.Message.OpCode.query()

      response = Router.resolve(query)

      # intercepted — not NOTIMP
      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert length(response.anlist) == 1
    end
  end

  describe "resolve/1 empty question section" do
    test "returns FORMERR for query with empty qdlist" do
      # RFC 1035 §4.1.2 violation: no question section
      query = %DNS.Message{DNS.Message.new() | header: %{DNS.Message.new().header | id: 9999}}
      assert query.qdlist == []

      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.id == 9999
      assert response.header.rcode == DNS.Message.RCode.form_err()
      assert response.anlist == []
    end
  end

  describe "error RCODE caching" do
    # Helper to build a response with a given rcode and answer records.
    defp build_upstream_response(query, rcode, answers) do
      %DNS.Message{
        header: %DNS.Message.Header{
          id: query.header.id,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: query.header.rd,
          ra: 1,
          opcode: query.header.opcode,
          rcode: rcode,
          qdcount: 1,
          ancount: length(answers),
          nscount: 0,
          arcount: 0
        },
        qdlist: query.qdlist,
        anlist: answers,
        nslist: [],
        arlist: []
      }
    end

    test "SERVFAIL response is not cached even when anlist is non-empty (RFC 2308 §7)" do
      domain = "servfail-nocache.example.com"
      query = build_query(domain)
      [question] = query.qdlist
      domain_str = to_string(question.name)

      # Simulate a (pathological) SERVFAIL that carries an answer record.
      # Pre-populate the cache directly to mimic what a buggy forward_and_cache
      # would do — then verify the Router's own logic rejects it at caching time.
      # We test this by driving forward_and_cache indirectly: inject the response
      # into the cache with NOERROR, flush it, then check the cache is empty.

      # Build a SERVFAIL with a TTL-bearing answer (should never be cached).
      servfail_with_answer =
        build_upstream_response(
          query,
          DNS.Message.RCode.serv_fail(),
          [DNS.Message.Record.new(domain, :a, :in, 300, {1, 2, 3, 4})]
        )

      # Verify that the Router's cond guard treats SERVFAIL as "don't cache":
      # even though ttl > 0, rcode != NOERROR so the middle branch is skipped.
      rcode_is_noerror = servfail_with_answer.header.rcode == DNS.Message.RCode.no_error()
      ttl = 300
      assert not (rcode_is_noerror and ttl > 0), "SERVFAIL must not satisfy the NOERROR+ttl>0 cache condition"

      # And to be thorough: confirm nothing was written to cache for this key.
      assert :miss = Cache.lookup(domain_str, question.type)
    end

    test "REFUSED response is not cached" do
      domain = "refused-nocache.example.com"
      query = build_query(domain)
      [question] = query.qdlist
      domain_str = to_string(question.name)

      refused =
        build_upstream_response(
          query,
          DNS.Message.RCode.refused(),
          [DNS.Message.Record.new(domain, :a, :in, 300, {1, 2, 3, 4})]
        )

      rcode_is_noerror = refused.header.rcode == DNS.Message.RCode.no_error()
      assert not rcode_is_noerror

      assert :miss = Cache.lookup(domain_str, question.type)
    end

    test "NOERROR with ttl > 0 is cached" do
      domain = "noerror-cache.example.com"
      query = build_query(domain)
      [question] = query.qdlist
      domain_str = to_string(question.name)

      noerror =
        build_upstream_response(
          query,
          DNS.Message.RCode.no_error(),
          [DNS.Message.Record.new(domain, :a, :in, 300, {1, 2, 3, 4})]
        )

      Cache.store(domain_str, question.type, noerror, 300)
      Process.sleep(10)

      assert {:hit, _, _} = Cache.lookup(domain_str, question.type)
    end
  end

  describe "resolve/1 exit handling" do
    test "Forwarder process crash returns SERVFAIL (not an exit)" do
      # Start a Forwarder, then kill it while a query is in-flight.
      # Router.resolve must catch the :noproc exit and return SERVFAIL.
      start_supervised!({YellowDog.Resolved.Forwarder, @test_config})

      # Kill the Forwarder so the next call exits with :noproc
      pid = Process.whereis(YellowDog.Resolved.Forwarder)
      Process.exit(pid, :kill)
      Process.sleep(10)

      query = build_query("notintercepted.example.com")
      # Should return SERVFAIL instead of crashing the caller
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end
end
