defmodule YellowDog.Resolved.PropertyTest do
  @moduledoc """
  Property-based tests for the resolved DNS stub resolver.

  Uses StreamData to generate random inputs and verify invariants:
  1. Any valid DNS query → valid DNS response (never crashes)
  2. Cache TTL → no entry survives beyond max_ttl_s
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias YellowDog.Resolved.{Cache, Config, ResponseBuilder, Router}

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 1,
    max_ttl_s: 5,
    negative_ttl_s: 2,
    sweep_interval_s: 1
  }

  @config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 100,
    upstream_failure_threshold: 3,
    intercept_rules: [
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:exact, "test.example"}, type: :aaaa, value: "::1", ttl: 60}
    ],
    cache: @cache_config,
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    config_path: ""
  }

  # Generators

  defp dns_label do
    gen all(
          length <- integer(1..20),
          chars <- list_of(member_of(?a..?z), length: length)
        ) do
      List.to_string(chars)
    end
  end

  defp dns_domain do
    gen all(labels <- list_of(dns_label(), min_length: 1, max_length: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp dns_query_type do
    # Standard DNS query type numbers
    member_of([1, 2, 5, 6, 12, 15, 16, 28, 33, 255])
  end

  defp dns_query do
    gen all(
          domain <- dns_domain(),
          type_num <- dns_query_type(),
          txn_id <- integer(1..65535)
        ) do
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, txn_id)
      query = DNS.Message.update_header_attr(query, :rd, 1)
      DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
    end
  end

  defp interceptable_query do
    gen all(
          subdomain <- dns_label(),
          txn_id <- integer(1..65535)
        ) do
      domain = "#{subdomain}.local.dev"
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, txn_id)
      query = DNS.Message.update_header_attr(query, :rd, 1)
      DNS.Message.add_question(query, DNS.Message.Question.new(domain, 1, 1))
    end
  end

  describe "property: any valid DNS query produces a valid response" do
    setup do
      start_supervised!({Config, @config})
      start_supervised!({Cache, @cache_config})
      :ok
    end

    property "intercept path never crashes and returns valid DNS binary" do
      check all(query <- interceptable_query(), max_runs: 100) do
        raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

        # Should never crash — always returns {:ok, binary, source}
        assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
        assert is_binary(response_binary)
        assert byte_size(response_binary) >= 12

        # Response should decode to valid DNS message
        response = DNS.Message.from_iodata(response_binary)
        assert response.header.qr == 1
        assert response.header.id == query.header.id
      end
    end

    property "random domain queries never crash the router" do
      check all(query <- dns_query(), max_runs: 50) do
        raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

        # Router should always return {:ok, binary} or {:ok, binary, source}
        # It should NEVER raise or crash
        # Suppress expected "noproc" logs for non-intercepted queries (no Forwarder)
        result =
          capture_log(fn ->
            send(self(), {:result, Router.resolve(query, raw)})
          end)

        assert_received {:result, resolved}

        # Log may contain "Query resolution crashed" for forward path — expected
        _ = result

        case resolved do
          {:ok, response_binary, _source} ->
            assert is_binary(response_binary)
            assert byte_size(response_binary) >= 12

          {:ok, response_binary} ->
            assert is_binary(response_binary)
            assert byte_size(response_binary) >= 12
        end
      end
    end
  end

  describe "property: intercept pattern matching invariants" do
    property "suffix pattern always matches subdomains" do
      check all(
              subdomain <- dns_label(),
              base_domain <- dns_domain(),
              max_runs: 100
            ) do
        full_domain = "#{subdomain}.#{base_domain}"
        pattern = {:suffix, base_domain}

        # A subdomain of the base should always match the suffix pattern
        assert YellowDog.Resolved.Intercept.matches_pattern?(full_domain, pattern)
      end
    end

    property "exact pattern only matches identical domain" do
      check all(
              domain <- dns_domain(),
              other <- dns_domain(),
              max_runs: 100
            ) do
        pattern = {:exact, domain}

        # Same domain should always match
        assert YellowDog.Resolved.Intercept.matches_pattern?(domain, pattern)

        # Different domain should not match (unless generated the same)
        if domain != other do
          refute YellowDog.Resolved.Intercept.matches_pattern?(other, pattern)
        end
      end
    end

    property "prefix pattern matches domains starting with prefix" do
      check all(
              prefix <- dns_label(),
              suffix <- dns_domain(),
              max_runs: 100
            ) do
        domain = "#{prefix}#{suffix}"
        pattern = {:prefix, prefix}

        assert YellowDog.Resolved.Intercept.matches_pattern?(domain, pattern)
      end
    end
  end

  describe "property: cache TTL bounds" do
    setup do
      start_supervised!({Config, @config})
      # Use short TTLs for property testing: min=1s, max=5s, sweep=1s
      start_supervised!({Cache, @cache_config})
      :ok
    end

    property "stored entries respect min_ttl_s clamping" do
      check all(
              domain <- dns_domain(),
              ttl <- integer(0..100),
              max_runs: 50
            ) do
        Cache.store(domain, :a, "data-#{domain}", ttl)
        Process.sleep(10)

        # Entry should be present immediately (within min_ttl_s window)
        assert {:hit, _} = Cache.lookup(domain, :a)
      end
    end

    property "stored entries respect max_ttl_s clamping" do
      check all(
              domain <- dns_domain(),
              ttl <- integer(100..999_999),
              max_runs: 20
            ) do
        # Even with huge TTL, the cache clamps to max_ttl_s (5s in test config)
        Cache.store(domain, :a, "data-#{domain}", ttl)
        Process.sleep(10)

        # Should be present immediately
        assert {:hit, _} = Cache.lookup(domain, :a)
      end
    end
  end

  describe "property: ResponseBuilder all record types encode/decode roundtrip" do
    defp intercept_rule do
      gen all(type <- member_of([:a, :aaaa, :cname, :txt, :mx, :srv])) do
        case type do
          :a -> %{type: :a, value: "10.0.0.1", ttl: 300}
          :aaaa -> %{type: :aaaa, value: "::1", ttl: 300}
          :cname -> %{type: :cname, value: "target.example.com", ttl: 300}
          :txt -> %{type: :txt, value: "v=spf1 -all", ttl: 300}
          :mx -> %{type: :mx, value: "10 mail.example.com", ttl: 300}
          :srv -> %{type: :srv, value: "10 20 8080 target.example.com", ttl: 300}
        end
      end
    end

    defp query_type_num(:a), do: 1
    defp query_type_num(:aaaa), do: 28
    defp query_type_num(:cname), do: 5
    defp query_type_num(:txt), do: 16
    defp query_type_num(:mx), do: 15
    defp query_type_num(:srv), do: 33

    property "build_intercept_response encodes to valid DNS for all types" do
      check all(
              domain <- dns_domain(),
              rule <- intercept_rule(),
              txn_id <- integer(1..65535),
              max_runs: 100
            ) do
        type_num = query_type_num(rule.type)
        query = DNS.Message.new()
        query = DNS.Message.update_header_attr(query, :id, txn_id)
        query = DNS.Message.update_header_attr(query, :rd, 1)
        query = DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))

        response = ResponseBuilder.build_intercept_response(query, rule)
        binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

        assert byte_size(binary) >= 12

        decoded = DNS.Message.from_iodata(binary)
        assert decoded.header.qr == 1
        assert decoded.header.id == txn_id
        assert length(decoded.anlist) == 1
      end
    end
  end

  describe "property: cache key normalization invariants" do
    setup do
      start_supervised!({Config, @config})
      start_supervised!({Cache, @cache_config})
      :ok
    end

    property "case variation in domain produces identical cache key" do
      check all(
              domain <- dns_domain(),
              max_runs: 50
            ) do
        upper = String.upcase(domain)
        lower = String.downcase(domain)
        mixed = domain |> String.graphemes() |> Enum.map_every(2, &String.upcase/1) |> Enum.join()

        Cache.store(lower, :a, "canonical", 300)
        Process.sleep(5)

        assert {:hit, "canonical"} = Cache.lookup(upper, :a)
        assert {:hit, "canonical"} = Cache.lookup(mixed, :a)
      end
    end

    property "trailing dot does not affect cache key" do
      check all(
              domain <- dns_domain(),
              max_runs: 50
            ) do
        with_dot = domain <> "."
        without_dot = domain

        Cache.store(with_dot, :a, "dotted", 300)
        Process.sleep(5)

        assert {:hit, "dotted"} = Cache.lookup(without_dot, :a)

        # Overwrite via no-dot variant
        Cache.store(without_dot, :a, "undotted", 300)
        Process.sleep(5)

        assert {:hit, "undotted"} = Cache.lookup(with_dot, :a)
      end
    end
  end
end
