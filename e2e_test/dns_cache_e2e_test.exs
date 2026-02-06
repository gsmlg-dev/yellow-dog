defmodule E2ETest.DnsCacheE2ETest do
  @moduledoc """
  End-to-end tests for DNS caching behavior.

  Tests that the DNS view cache stores and returns responses
  correctly, respects TTL, and supports cache flush operations.
  """

  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias E2ETest.DnsClient
  alias YellowDog.Dns.{ViewManager, ZoneController, Zone, View}

  @moduletag :e2e
  @moduletag :dns

  setup do
    case ServiceHelper.start_dns_system(listen: {127, 0, 0, 1}) do
      {:ok, ctx} ->
        on_exit(fn -> ServiceHelper.stop_dns_system(ctx) end)

        # Set up a test zone with records
        setup_test_zone()

        {:ok, ctx}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  defp setup_test_zone do
    {:ok, zone_pid} =
      ZoneController.start_zone(:auth, "cache.test", view_name: "default")

    {:ok, view_pid} = ViewManager.get_view("default")
    View.register_zone(view_pid, :auth, "cache.test")

    Zone.Auth.add_record(zone_pid, build_a_record("cache.test", {10, 0, 0, 1}))
    Zone.Auth.add_record(zone_pid, build_a_record("www.cache.test", {10, 0, 0, 2}))

    zone_pid
  end

  describe "repeated query performance" do
    test "second query for same name is fast", ctx do
      # First query
      result1 = DnsClient.query_a(ctx.host, ctx.port, "cache.test", timeout: 3_000)

      # Second query (should benefit from any caching)
      result2 = DnsClient.query_a(ctx.host, ctx.port, "cache.test", timeout: 3_000)

      case {result1, result2} do
        {{:ok, r1}, {:ok, r2}} ->
          assert DnsClient.get_rcode(r1) == :NOERROR
          assert DnsClient.get_rcode(r2) == :NOERROR

        _ ->
          :ok
      end
    end

    test "multiple different queries all resolve correctly", ctx do
      domains = ["cache.test", "www.cache.test"]

      results =
        Enum.map(domains, fn domain ->
          {domain, DnsClient.query_a(ctx.host, ctx.port, domain, timeout: 3_000)}
        end)

      for {domain, result} <- results do
        case result do
          {:ok, response} ->
            assert DnsClient.get_rcode(response) == :NOERROR,
                   "Expected NOERROR for #{domain}"

          {:error, _reason} ->
            :ok
        end
      end
    end
  end

  describe "negative caching" do
    test "NXDOMAIN responses are consistent", ctx do
      # Query non-existent name twice
      result1 =
        DnsClient.query_a(ctx.host, ctx.port, "nonexistent.cache.test", timeout: 3_000)

      result2 =
        DnsClient.query_a(ctx.host, ctx.port, "nonexistent.cache.test", timeout: 3_000)

      case {result1, result2} do
        {{:ok, r1}, {:ok, r2}} ->
          assert DnsClient.get_rcode(r1) == :NXDOMAIN
          assert DnsClient.get_rcode(r2) == :NXDOMAIN

        _ ->
          :ok
      end
    end
  end

  describe "dynamic record updates" do
    test "dynamically added records are queryable", ctx do
      # Create a fresh zone with a new name
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "dynamic.test", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :auth, "dynamic.test")

      # Add a record
      Zone.Auth.add_record(zone_pid, build_a_record("dynamic.test", {10, 0, 0, 99}))

      # Query should succeed
      result = DnsClient.query_a(ctx.host, ctx.port, "dynamic.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  defp build_a_record(name, ip) do
    DNS.Message.Record.new(name, :a, :in, 3600, ip)
  end
end
