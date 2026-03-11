defmodule YellowDog.Resolved.IntegrationTest do
  @moduledoc """
  Integration tests for the resolved query pipeline.
  Tests the full resolve path: intercept → cache → forward.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, Router}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [],
    upstream_timeout_ms: 500,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 100,
      min_ttl_s: 1,
      max_ttl_s: 3600,
      negative_ttl_s: 5,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: [
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
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

  defp serialize_roundtrip(response) do
    binary = DNS.to_iodata(response) |> IO.iodata_to_binary()
    DNS.Message.from_iodata(binary)
  end

  describe "end-to-end intercept" do
    test "exact match returns valid DNS response that survives serialization" do
      query = build_query("myapp.test")
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert parsed.header.aa == 1
      assert parsed.header.id == query.header.id
      assert parsed.header.rcode == DNS.Message.RCode.no_error()
      assert length(parsed.anlist) == 1
    end

    test "suffix match returns valid DNS response" do
      query = build_query("app.local.dev")
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "prefix match returns valid DNS response" do
      query = build_query("dev-myserver")
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "type mismatch returns empty NOERROR" do
      query = build_query("myapp.test", :aaaa)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.rcode == DNS.Message.RCode.no_error()
      assert parsed.anlist == []
    end
  end

  describe "end-to-end forward with no upstreams" do
    test "returns SERVFAIL when no upstreams configured" do
      query = build_query("unknown.example.com")
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert parsed.header.rcode == DNS.Message.RCode.serv_fail()
    end
  end

  describe "end-to-end cache behavior" do
    test "second query for cached entry is served from cache" do
      # Pre-populate cache with a response
      domain = "cached-e2e.example.com"
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
          z: 0,
          ad: 0,
          cd: 0,
          opcode: query.header.opcode,
          rcode: DNS.Message.RCode.no_error(),
          qdcount: 1,
          ancount: 1,
          nscount: 0,
          arcount: 0
        },
        qdlist: query.qdlist,
        anlist: [DNS.Message.Record.new(domain, :a, :in, 300, {10, 20, 30, 40})],
        nslist: [],
        arlist: []
      }

      Cache.store(domain_str, dns_type, fake_response, 300)
      Process.sleep(10)

      # First query — should hit cache
      response1 = Router.resolve(query)
      assert response1.header.id == query.header.id

      # Verify cache stats show a hit
      stats = Cache.stats()
      assert stats.hits >= 1

      # Second query — also from cache
      query2 = build_query(domain)
      response2 = Router.resolve(query2)
      assert response2.header.id == query2.header.id

      stats2 = Cache.stats()
      assert stats2.hits >= 2
    end

    test "cache flush clears entries" do
      domain = "flush-e2e.example.com"
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
          z: 0,
          ad: 0,
          cd: 0,
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

      assert {:hit, _} = Cache.lookup(domain_str, dns_type)

      Cache.flush()

      assert :miss = Cache.lookup(domain_str, dns_type)
    end
  end

  describe "config hot-reload propagation" do
    test "config update propagates to forwarder" do
      # Get initial config
      initial = Config.get()
      assert initial.upstreams == []

      # Simulate config reload by sending file_event with new config
      # We test the propagation by directly casting update_config
      new_config = %{
        upstreams: [{9, 9, 9, 9}],
        upstream_timeout_ms: 1000,
        upstream_failure_threshold: 5
      }

      GenServer.cast(Forwarder, {:update_config, new_config})
      Process.sleep(10)

      # Forwarder should still be alive after config update
      assert Process.alive?(Process.whereis(Forwarder))
    end

    test "config update propagates to cache" do
      new_cache_config = %{
        max_entries: 5000,
        min_ttl_s: 10,
        max_ttl_s: 7200,
        negative_ttl_s: 30,
        sweep_interval_s: 120
      }

      GenServer.cast(Cache, {:update_config, new_cache_config})
      Process.sleep(10)

      # Cache should still be alive and functional after config update
      assert Process.alive?(Process.whereis(Cache))

      # Verify cache still works
      Cache.store("reload-test.example.com", :a, %{}, 300)
      Process.sleep(10)
      assert {:hit, _} = Cache.lookup("reload-test.example.com", :a)
    end
  end

  describe "negative caching (NXDOMAIN)" do
    test "NXDOMAIN response is cached and served on second query" do
      domain = "nonexistent-neg-cache.example.com"
      query = build_query(domain)

      [question] = query.qdlist
      dns_type = question.type
      domain_str = to_string(question.name)

      # Simulate an NXDOMAIN response from upstream
      nxdomain_response = %DNS.Message{
        header: %DNS.Message.Header{
          id: 0,
          qr: 1,
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 1,
          z: 0,
          ad: 0,
          cd: 0,
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

      # Store with negative TTL (as Router.forward_and_cache would)
      Cache.store(domain_str, dns_type, nxdomain_response, 5)
      Process.sleep(10)

      # Should be a cache hit with NXDOMAIN rcode
      assert {:hit, cached} = Cache.lookup(domain_str, dns_type)
      assert cached.header.rcode == DNS.Message.RCode.nx_domain()

      # Query through router should return the cached NXDOMAIN
      response = Router.resolve(query)
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
      assert response.header.id == query.header.id
    end
  end

  describe "end-to-end intercept for all record types" do
    setup do
      # Override config with rules for all supported record types
      stop_supervised!(Config)

      all_types_config = %{
        @test_config
        | intercept_rules: [
            %{match: {:exact, "a.test"}, type: :a, value: "192.168.1.100", ttl: 300},
            %{match: {:exact, "aaaa.test"}, type: :aaaa, value: "::1", ttl: 300},
            %{match: {:exact, "cname.test"}, type: :cname, value: "target.test", ttl: 300},
            %{match: {:exact, "txt.test"}, type: :txt, value: "v=spf1 ~all", ttl: 300},
            %{match: {:exact, "mx.test"}, type: :mx, value: "10 mail.test", ttl: 300},
            %{match: {:exact, "srv.test"}, type: :srv, value: "10 20 5060 sip.test", ttl: 300}
          ]
      }

      start_supervised!({Config, all_types_config})
      :ok
    end

    test "A record intercept serializes correctly" do
      query = build_query("a.test", :a)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "AAAA record intercept serializes correctly" do
      query = build_query("aaaa.test", :aaaa)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "CNAME record intercept serializes correctly" do
      query = build_query("cname.test", :cname)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "TXT record intercept serializes correctly" do
      query = build_query("txt.test", :txt)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "MX record intercept serializes correctly" do
      query = build_query("mx.test", :mx)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end

    test "SRV record intercept serializes correctly" do
      query = build_query("srv.test", :srv)
      response = Router.resolve(query)
      parsed = serialize_roundtrip(response)

      assert parsed.header.qr == 1
      assert length(parsed.anlist) == 1
    end
  end

  describe "counters through full pipeline" do
    test "ping command reflects actual query routing outcomes" do
      alias YellowDog.Resolved.Management.Handler

      Counters.reset()

      # 2 intercepted queries
      Router.resolve(build_query("myapp.test"))
      Router.resolve(build_query("app.local.dev"))

      # 1 cached query
      domain = "cached-ping.example.com"
      q = build_query(domain)
      [question] = q.qdlist

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
            opcode: q.header.opcode,
            rcode: DNS.Message.RCode.no_error(),
            qdcount: 1,
            ancount: 0,
            nscount: 0,
            arcount: 0
          },
          qdlist: q.qdlist,
          anlist: [],
          nslist: [],
          arlist: []
        },
        300
      )

      Process.sleep(10)
      Router.resolve(q)

      # 1 error (no upstreams)
      Router.resolve(build_query("unknown.example.com"))

      # Now verify ping returns accurate counts
      result =
        Handler.handle_command(%{
          "type" => "ping",
          "id" => "counter-verify",
          "data" => %{"server_time" => 0}
        })

      data = result["data"]
      assert data["queries_intercepted"] == 2
      assert data["queries_cached"] == 1
      assert data["queries_forwarded"] == 0
      assert data["queries_total"] == 4
    end
  end

  describe "management command integration" do
    alias YellowDog.Resolved.Management.Handler

    test "cache_flush command clears cache and returns count" do
      # Store some entries
      Cache.store("a.example.com.", :a, %{}, 300)
      Cache.store("b.example.com.", :a, %{}, 300)
      Process.sleep(10)

      command = %{
        "type" => "cache_flush",
        "id" => "test-001",
        "data" => %{"pattern" => nil}
      }

      response = Handler.handle_command(command)

      assert response["type"] == "cache_flush_result"
      assert response["id"] == "test-001"
      assert response["data"]["flushed"] >= 2
    end

    test "cache_stats command returns statistics" do
      command = %{
        "type" => "cache_stats",
        "id" => "test-002",
        "data" => %{}
      }

      response = Handler.handle_command(command)

      assert response["type"] == "cache_stats_result"
      assert response["id"] == "test-002"
      assert is_integer(response["data"]["entries"])
      assert is_integer(response["data"]["hits"])
      assert is_integer(response["data"]["misses"])
    end

    test "ping command returns pong with stats" do
      command = %{
        "type" => "ping",
        "id" => "test-003",
        "data" => %{"server_time" => 1_706_000_000}
      }

      response = Handler.handle_command(command)

      assert response["type"] == "pong"
      assert response["id"] == "test-003"
      assert is_integer(response["data"]["uptime_s"])
      assert is_integer(response["data"]["queries_total"])
    end
  end
end
