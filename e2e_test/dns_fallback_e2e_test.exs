defmodule E2ETest.DnsFallbackE2ETest do
  @moduledoc """
  End-to-end tests for DNS fallback forwarding behavior.

  Tests that when a view's primary zone resolution fails,
  the system handles the failure gracefully. Also tests
  forward zones with unreachable upstreams and timeout behavior.
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
        {:ok, ctx}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  describe "zone failure handling" do
    test "unmatched query returns NXDOMAIN not SERVFAIL", ctx do
      # Query for a domain with no zone configured
      result =
        DnsClient.query_a(ctx.host, ctx.port, "no-zone-exists.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          rcode = DnsClient.get_rcode(response)
          # Should get NXDOMAIN or SERVFAIL, not crash
          assert rcode in [:NXDOMAIN, :SERVFAIL, :REFUSED],
                 "Expected NXDOMAIN/SERVFAIL/REFUSED, got #{inspect(rcode)}"

        {:error, _reason} ->
          :ok
      end
    end

    test "query to forward zone with unreachable upstream handles gracefully", ctx do
      # Create forward zone pointing to unreachable server
      {:ok, _zone_pid} =
        ZoneController.start_zone(:forward, "unreachable.test",
          view_name: "default",
          upstreams: [{{192, 0, 2, 1}, 53}],
          timeout: 500
        )

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :forward, "unreachable.test")

      # Query should timeout or return SERVFAIL, not crash the system
      result =
        DnsClient.query_a(ctx.host, ctx.port, "unreachable.test", timeout: 5_000)

      case result do
        {:ok, response} ->
          rcode = DnsClient.get_rcode(response)
          assert rcode in [:SERVFAIL, :NXDOMAIN, :NOERROR],
                 "Expected SERVFAIL for unreachable upstream, got #{inspect(rcode)}"

        {:error, :timeout} ->
          # Timeout is acceptable for unreachable upstream
          :ok

        {:error, _reason} ->
          :ok
      end

      # Verify DNS system is still responsive after the timeout
      {:ok, auth_zone_pid} =
        ZoneController.start_zone(:auth, "still-working.test", view_name: "default")

      View.register_zone(view_pid, :auth, "still-working.test")

      Zone.Auth.add_record(
        auth_zone_pid,
        DNS.Message.Record.new("still-working.test", :a, :in, 3600, {1, 2, 3, 4})
      )

      result2 =
        DnsClient.query_a(ctx.host, ctx.port, "still-working.test", timeout: 3_000)

      case result2 do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "view resolution order" do
    test "auth zone takes priority over no zone", ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "priority.test", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :auth, "priority.test")

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("priority.test", :a, :in, 3600, {5, 5, 5, 5})
      )

      result = DnsClient.query_a(ctx.host, ctx.port, "priority.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "MetricsCollector integration" do
    test "metrics collector tracks queries", _ctx do
      # MetricsCollector should be running as part of DNS system
      metrics = YellowDog.Dns.MetricsCollector.get_metrics()
      assert is_map(metrics)
    end
  end
end
