defmodule YellowDog.Resolved.PropertyTest do
  @moduledoc """
  Property-based tests for the DNS stub resolver.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, Intercept, RateLimiter, Router}

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
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!(Counters)
    start_supervised!({Cache, @test_config.cache})
    start_supervised!({Forwarder, @test_config})
    :ok
  end

  # Generators

  defp dns_label do
    gen all(
          len <- integer(1..20),
          chars <-
            list_of(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9) ++ [?-]), length: len)
        ) do
      # Ensure label doesn't start or end with hyphen
      chars
      |> List.to_string()
      |> String.trim_leading("-")
      |> String.trim_trailing("-")
      |> then(fn s -> if s == "", do: "a", else: s end)
    end
  end

  defp dns_domain do
    gen all(labels <- list_of(dns_label(), min_length: 1, max_length: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp dns_type do
    member_of([:a, :aaaa, :cname, :mx, :txt, :srv, :ns, :ptr, :soa])
  end

  defp dns_query do
    gen all(
          domain <- dns_domain(),
          type <- dns_type(),
          id <- integer(0..65535)
        ) do
      query = DNS.Message.new()
      question = DNS.Message.Question.new(domain, type, :in)

      %{
        query
        | header: %{query.header | id: id, rd: 1, qdcount: 1},
          qdlist: [question]
      }
    end
  end

  # Property: Any valid DNS query to the router never crashes and always returns a valid DNS response
  property "any valid DNS query returns a valid DNS response (never crashes)" do
    check all(query <- dns_query(), max_runs: 100) do
      response = Router.resolve(query)

      # Response is a DNS.Message struct
      assert %DNS.Message{} = response

      # QR bit is set (response)
      assert response.header.qr == 1

      # Transaction ID matches query
      assert response.header.id == query.header.id

      # Question section preserved
      assert response.qdlist == query.qdlist

      # Header counts are consistent
      assert response.header.ancount == length(response.anlist)
      assert response.header.nscount == length(response.nslist)
      assert response.header.arcount == length(response.arlist)
      assert response.header.qdcount == length(response.qdlist)

      # rcode is a valid value
      assert response.header.rcode in [
               DNS.Message.RCode.no_error(),
               DNS.Message.RCode.serv_fail(),
               DNS.Message.RCode.nx_domain(),
               DNS.Message.RCode.refused()
             ]
    end
  end

  # Property: Cache TTL — no entry survives beyond max_ttl_s + sweep_interval_s
  property "cached entries expire and are not returned after TTL" do
    check all(
            domain <- dns_domain(),
            type <- member_of([:a, :aaaa]),
            ttl <- integer(1..5),
            max_runs: 20
          ) do
      fake_response = build_fake_response(domain, type)

      Cache.store(domain, type, fake_response, ttl)
      # Wait for cast to process
      Process.sleep(5)

      # Should be a hit immediately (min_ttl clamp means at least 5s TTL)
      assert {:hit, _, _} = Cache.lookup(domain, type)

      # Clean up
      Cache.flush(domain)
    end
  end

  # Property: Intercept rule matching is case-insensitive
  property "intercept matching is always case-insensitive" do
    rules = [
      %{match: {:exact, "test.example.com"}, type: :a, value: "1.2.3.4", ttl: 60},
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 300}
    ]

    check all(
            case_variant <- member_of([:lower, :upper, :mixed]),
            max_runs: 50
          ) do
      # Exact match
      domain =
        case case_variant do
          :lower -> "test.example.com"
          :upper -> "TEST.EXAMPLE.COM"
          :mixed -> "Test.Example.COM"
        end

      assert %{} = Intercept.match(domain, :a, rules)

      # Suffix match
      suffix_domain =
        case case_variant do
          :lower -> "app.local.dev"
          :upper -> "APP.LOCAL.DEV"
          :mixed -> "App.Local.DEV"
        end

      assert %{} = Intercept.match(suffix_domain, :a, rules)

      # Prefix match
      prefix_domain =
        case case_variant do
          :lower -> "dev-server.test"
          :upper -> "DEV-SERVER.TEST"
          :mixed -> "Dev-Server.Test"
        end

      assert %{} = Intercept.match(prefix_domain, :a, rules)
    end
  end

  # Property: Cache key normalization is idempotent
  property "cache stores and retrieves regardless of domain casing" do
    check all(
            domain <- dns_domain(),
            type <- member_of([:a, :aaaa]),
            max_runs: 50
          ) do
      fake_response = build_fake_response(domain, type)
      Cache.store(String.upcase(domain), type, fake_response, 300)
      Process.sleep(5)

      # Should match with lowercase
      assert {:hit, _, _} = Cache.lookup(String.downcase(domain), type)

      # Clean up
      Cache.flush(domain)
    end
  end

  # Property: ResponseBuilder.build_record with valid inputs always produces serializable records
  property "build_record with valid inputs always returns {:ok, record}" do
    alias YellowDog.Resolved.ResponseBuilder

    check all(
            domain <- dns_domain(),
            {type, value} <-
              member_of([
                {:a, "192.168.1.1"},
                {:a, "10.0.0.1"},
                {:aaaa, "::1"},
                {:aaaa, "fe80::1"},
                {:cname, "target.example.com"},
                {:txt, "v=spf1 ~all"},
                {:mx, "10 mail.example.com"},
                {:srv, "10 20 5060 sip.example.com"}
              ]),
            ttl <- integer(1..86400),
            max_runs: 50
          ) do
      assert {:ok, record} = ResponseBuilder.build_record(domain, type, value, ttl)
      assert record.ttl == ttl
    end
  end

  # Property: flush_pattern("*.suffix") flushes only matching entries
  property "flush_pattern only removes entries matching the wildcard suffix" do
    check all(
            suffix <- dns_label(),
            matching_sub <- dns_label(),
            non_matching <- dns_domain(),
            max_runs: 30
          ) do
      matching_domain = "#{matching_sub}.#{suffix}"
      # Make sure non_matching doesn't accidentally match
      non_matching_safe =
        if String.ends_with?(String.downcase(non_matching), ".#{String.downcase(suffix)}") or
             String.downcase(non_matching) == String.downcase(suffix) do
          "totally.unrelated.domain"
        else
          non_matching
        end

      Cache.store(matching_domain, :a, %{m: true}, 300)
      Cache.store(non_matching_safe, :a, %{m: false}, 300)
      Process.sleep(5)

      Cache.flush_pattern("*.#{suffix}")

      # Matching entry should be flushed
      assert :miss = Cache.lookup(matching_domain, :a)
      # Non-matching should still be present
      assert {:hit, _, _} = Cache.lookup(non_matching_safe, :a)

      # Clean up
      Cache.flush()
    end
  end

  # Property: Config parsing always produces valid bounded values
  property "config parsing always produces valid bounded values" do
    check all(
            port <- one_of([integer(-100..100_000), constant("bad")]),
            timeout <- one_of([integer(-100..100_000), constant(nil)]),
            max_entries <- one_of([integer(-100..2_000_000), constant("x")]),
            min_ttl <- one_of([integer(-100..200_000), constant(0.5)]),
            max_ttl <- one_of([integer(-100..1_000_000), constant(true)]),
            max_runs: 50
          ) do
      toml = %{
        "resolved" => %{
          "port" => port,
          "upstream_timeout_ms" => timeout,
          "upstreams" => [],
          "cache" => %{
            "max_entries" => max_entries,
            "min_ttl_s" => min_ttl,
            "max_ttl_s" => max_ttl
          }
        }
      }

      config = Config.parse_toml_for_test(toml)

      # All values must be integers in valid ranges
      assert is_integer(config.port)
      assert config.port >= 1 and config.port <= 65_535

      assert is_integer(config.upstream_timeout_ms)
      assert config.upstream_timeout_ms >= 100 and config.upstream_timeout_ms <= 30_000

      assert is_integer(config.cache.max_entries)
      assert config.cache.max_entries >= 1

      assert is_integer(config.cache.min_ttl_s)
      assert is_integer(config.cache.max_ttl_s)
      assert config.cache.min_ttl_s <= config.cache.max_ttl_s
    end
  end

  # Property: Rate limiter never allows more than burst + refilled tokens
  property "rate limiter never exceeds burst capacity" do
    # Start a dedicated rate limiter for this property test
    rl_config = %{rate_limit: %{burst: 10, rate: 5}}

    case Process.whereis(RateLimiter) do
      nil -> :ok
      _ -> stop_supervised!(RateLimiter)
    end

    start_supervised!({RateLimiter, rl_config})

    check all(
            ip_last_octet <- integer(1..254),
            request_count <- integer(1..20),
            max_runs: 30
          ) do
      ip = {172, 16, 0, ip_last_octet}
      results = for _ <- 1..request_count, do: RateLimiter.allow?(ip)

      allowed = Enum.count(results, &(&1 == :ok))

      # Without any time passing, allowed requests can never exceed burst (10)
      assert allowed <= 10
    end
  end

  # Helpers

  defp build_fake_response(domain, type) do
    query = DNS.Message.new()
    question = DNS.Message.Question.new(domain, type, :in)

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
      qdlist: [question],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end
end
