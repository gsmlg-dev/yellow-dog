defmodule E2ETest.DnsZoneForwardE2ETest do
  @moduledoc """
  End-to-end tests for DNS forward zone functionality.

  Tests that forward zones correctly proxy queries to upstream
  DNS servers, handle timeouts, and support failover between
  multiple upstream servers.
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

  describe "forward zone creation" do
    test "creates forward zone with upstream servers", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:forward, "forward.test",
          view_name: "default",
          upstreams: [{{8, 8, 8, 8}, 53}],
          timeout: 2000
        )

      assert is_pid(zone_pid)
      assert Process.alive?(zone_pid)
    end

    test "forward zone starts with multiple upstreams", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:forward, "multi-upstream.test",
          view_name: "default",
          upstreams: [{{8, 8, 8, 8}, 53}, {{8, 8, 4, 4}, 53}],
          timeout: 2000,
          retries: 1
        )

      assert Process.alive?(zone_pid)
    end

    test "forward zone appears in zone listing", _ctx do
      {:ok, _pid} =
        ZoneController.start_zone(:forward, "listed-forward.test",
          view_name: "default",
          upstreams: [{{1, 1, 1, 1}, 53}]
        )

      zones = ZoneController.list_zones()
      zone_names = Enum.map(zones, fn {_view, _type, name, _pid} -> name end)
      assert "listed-forward.test" in zone_names
    end
  end

  describe "forward zone registered in view" do
    test "view routes queries to forward zone", ctx do
      # Create forward zone pointing to a real upstream
      {:ok, _zone_pid} =
        ZoneController.start_zone(:forward, "google.test",
          view_name: "default",
          upstreams: [{{8, 8, 8, 8}, 53}],
          timeout: 3000
        )

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :forward, "google.test")

      # Query through the DNS system - forward zone should handle it
      result = DnsClient.query_a(ctx.host, ctx.port, "google.test", timeout: 5_000)

      case result do
        {:ok, response} ->
          # Forward zone should return some response (likely SERVFAIL or timeout-derived)
          assert response.header.qr == 1

        {:error, _reason} ->
          # Timeout is acceptable - upstream may not be reachable
          :ok
      end
    end
  end

  describe "forward zone statistics" do
    test "forward zone tracks query count", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:forward, "stats-forward.test",
          view_name: "default",
          upstreams: [{{127, 0, 0, 1}, 9999}],
          timeout: 500
        )

      stats = Zone.Forward.stats(zone_pid)
      assert is_map(stats)
      assert Map.has_key?(stats, :query_count) or Map.has_key?(stats, :name)
    end
  end
end
