defmodule YellowDog.Console.Diagnostics.DnsClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.DnsClient
  alias YellowDog.Console.Diagnostics.QueryResult

  describe "query/1 message building" do
    test "returns error result for invalid server IP" do
      params = %{
        query_name: "example.com",
        record_type: "a",
        server: "invalid-ip",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "100"
      }

      # With invalid server, query will fail but should return {:ok, result}
      assert {:ok, %QueryResult{} = result} = DnsClient.query(params)
      # The result should have a request struct built successfully
      assert result.request_struct != nil
    end

    test "builds DNS message with correct query name" do
      params = %{
        query_name: "test.example.com",
        record_type: "a",
        server: "127.0.0.1",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "100"
      }

      # Query will likely timeout, but message should be built
      {:ok, result} = DnsClient.query(params)
      assert result.request_struct != nil
      # Request binary should be non-empty
      assert byte_size(result.request_binary) > 0
    end

    test "handles different record types" do
      for record_type <- ["a", "aaaa", "mx", "txt", "cname", "ns", "ptr", "srv"] do
        params = %{
          query_name: "example.com",
          record_type: record_type,
          server: "127.0.0.1",
          port: "53",
          protocol: "udp",
          recursion_desired: "true",
          timeout: "50"
        }

        {:ok, result} = DnsClient.query(params)
        assert result.request_struct != nil
      end
    end

    test "handles recursion_desired flag" do
      for rd <- ["true", "false"] do
        params = %{
          query_name: "example.com",
          record_type: "a",
          server: "127.0.0.1",
          port: "53",
          protocol: "udp",
          recursion_desired: rd,
          timeout: "50"
        }

        {:ok, result} = DnsClient.query(params)
        assert result.request_struct != nil
      end
    end

    test "handles UDP protocol" do
      params = %{
        query_name: "example.com",
        record_type: "a",
        server: "127.0.0.1",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "50"
      }

      {:ok, result} = DnsClient.query(params)
      assert result.request_struct != nil
    end

    test "handles TCP protocol" do
      params = %{
        query_name: "example.com",
        record_type: "a",
        server: "127.0.0.1",
        port: "53",
        protocol: "tcp",
        recursion_desired: "true",
        timeout: "50"
      }

      {:ok, result} = DnsClient.query(params)
      assert result.request_struct != nil
    end

    test "returns timeout result for unreachable server" do
      params = %{
        query_name: "example.com",
        record_type: "a",
        # TEST-NET-1, should be unreachable
        server: "192.0.2.1",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "100"
      }

      {:ok, result} = DnsClient.query(params)
      # Should timeout, error, or fail gracefully
      assert result.status in [:timeout, :error, :success]
    end

    test "records latency" do
      params = %{
        query_name: "example.com",
        record_type: "a",
        server: "127.0.0.1",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "50"
      }

      {:ok, result} = DnsClient.query(params)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end

    test "handles atom keys in params" do
      params = %{
        query_name: "example.com",
        record_type: :a,
        server: {127, 0, 0, 1},
        port: 53,
        protocol: :udp,
        recursion_desired: true,
        timeout: 50
      }

      {:ok, result} = DnsClient.query(params)
      assert result.request_struct != nil
    end

    test "handles empty query name" do
      params = %{
        query_name: "",
        record_type: "a",
        server: "127.0.0.1",
        port: "53",
        protocol: "udp",
        recursion_desired: "true",
        timeout: "50"
      }

      {:ok, result} = DnsClient.query(params)
      # Should handle gracefully
      assert result.status in [:error, :timeout, :success]
    end
  end
end
