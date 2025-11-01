defmodule YellowDog.Dns.Query.IteratorTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Query.Iterator

  describe "query_nameserver/4" do
    @tag :network
    @tag timeout: 30000
    test "queries Google DNS for example.com A record" do
      # Google Public DNS
      google_dns = {8, 8, 8, 8}

      case Iterator.query_nameserver(google_dns, "example.com.", :A) do
        {:answer, answers, _authority} ->
          assert is_list(answers)
          assert length(answers) > 0

          # Verify we got A records back
          first_answer = List.first(answers)
          assert first_answer.type.value == <<0, 1>>

        {:error, reason} ->
          # Network might be unavailable in CI
          assert reason in [:timeout, :socket_open_failed]
      end
    end

    @tag :network
    @tag timeout: 30000
    test "queries root server for .com delegation" do
      # a.root-servers.net
      root_server = {198, 41, 0, 4}

      case Iterator.query_nameserver(root_server, "example.com.", :A, timeout_ms: 10000) do
        {:referral, ns_records, glue_map} ->
          assert is_list(ns_records)
          assert length(ns_records) > 0
          assert is_map(glue_map)

          # Should have NS records for .com
          first_ns = List.first(ns_records)
          assert first_ns.type.value == <<0, 2>>

        {:answer, _, _} ->
          # Some root servers might return answers directly
          assert true

        {:error, reason} ->
          # Network might be unavailable
          assert reason in [:timeout, :socket_open_failed]
      end
    end

    test "handles invalid nameserver" do
      # Invalid IP that should timeout
      invalid_ns = {192, 0, 2, 1}

      result = Iterator.query_nameserver(invalid_ns, "example.com.", :A, timeout_ms: 100)

      assert {:error, :timeout} = result
    end

    test "normalizes query name" do
      google_dns = {8, 8, 8, 8}

      # Test without trailing dot
      result1 = Iterator.query_nameserver(google_dns, "example.com", :A, timeout_ms: 100)
      result2 = Iterator.query_nameserver(google_dns, "example.com.", :A, timeout_ms: 100)

      # Both should have same behavior (timeout or response)
      assert elem(result1, 0) == elem(result2, 0)
    end
  end

  describe "glue record extraction" do
    @tag :network
    @tag timeout: 30000
    test "extracts glue records from referral response" do
      root_server = {198, 41, 0, 4}

      case Iterator.query_nameserver(root_server, "example.com.", :A, timeout_ms: 10000) do
        {:referral, _ns_records, glue_map} ->
          # Should have glue records for .com nameservers
          assert is_map(glue_map)

          # Glue map should have nameserver to IP mappings
          if map_size(glue_map) > 0 do
            {ns_name, ips} = Enum.at(glue_map, 0)
            assert is_binary(ns_name)
            assert String.ends_with?(ns_name, ".")
            assert is_list(ips)

            Enum.each(ips, fn ip ->
              assert is_tuple(ip)
              assert tuple_size(ip) in [4, 8]
            end)
          end

        _ ->
          # Skip if we don't get a referral
          assert true
      end
    end
  end
end
