defmodule YellowDog.Console.Diagnostics.MdnsClientTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.MdnsClient

  describe "query/1 message building" do
    test "builds mDNS message for service discovery" do
      params = %{
        service_type: "_http._tcp.local",
        query_type: "ptr",
        timeout: "100"
      }

      {:ok, result} = MdnsClient.query(params)
      assert result.request_struct != nil
      assert byte_size(result.request_binary) > 0
    end

    test "handles different service types" do
      for service_type <- ["_http._tcp.local", "_ssh._tcp.local", "_printer._tcp.local"] do
        params = %{
          service_type: service_type,
          query_type: "ptr",
          timeout: "50"
        }

        {:ok, result} = MdnsClient.query(params)
        assert result.request_struct != nil
      end
    end

    test "handles different query types" do
      for query_type <- ["ptr", "srv", "txt", "a", "aaaa"] do
        params = %{
          service_type: "_http._tcp.local",
          query_type: query_type,
          timeout: "50"
        }

        {:ok, result} = MdnsClient.query(params)
        assert result.request_struct != nil
      end
    end

    test "returns sources list for multicast responses" do
      params = %{
        service_type: "_http._tcp.local",
        query_type: "ptr",
        timeout: "100"
      }

      {:ok, result} = MdnsClient.query(params)
      # sources should be a list (possibly empty if no responders)
      assert is_list(result.sources)
    end

    test "records latency" do
      params = %{
        service_type: "_http._tcp.local",
        query_type: "ptr",
        timeout: "50"
      }

      {:ok, result} = MdnsClient.query(params)
      assert is_integer(result.latency_ms)
      assert result.latency_ms >= 0
    end

    test "handles atom keys in params" do
      params = %{
        service_type: "_http._tcp.local",
        query_type: :ptr,
        timeout: 50
      }

      {:ok, result} = MdnsClient.query(params)
      assert result.request_struct != nil
    end

    test "handles empty service type" do
      params = %{
        service_type: "",
        query_type: "ptr",
        timeout: "50"
      }

      {:ok, result} = MdnsClient.query(params)
      # Should handle gracefully
      assert result.status in [:error, :success]
    end

    test "respects timeout" do
      start_time = System.monotonic_time(:millisecond)

      params = %{
        service_type: "_http._tcp.local",
        query_type: "ptr",
        timeout: "100"
      }

      {:ok, _result} = MdnsClient.query(params)

      elapsed = System.monotonic_time(:millisecond) - start_time
      # Should return around the timeout value (with some margin)
      assert elapsed < 500
    end
  end
end
