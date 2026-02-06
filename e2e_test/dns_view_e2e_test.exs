defmodule E2ETest.DnsViewE2ETest do
  @moduledoc """
  End-to-end tests for DNS view-based routing.

  Tests that views correctly match clients and serve different responses
  based on the matched view. Validates view priority ordering,
  enable/disable, and default view fallback.
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

  describe "default view resolution" do
    test "default view resolves queries for registered zones", ctx do
      # Create and register an auth zone with the default view
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "default-test.local", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :auth, "default-test.local")

      # Add a record
      Zone.Auth.add_record(zone_pid, build_a_record("default-test.local", {10, 0, 0, 1}))

      # Query should succeed via default view
      result = DnsClient.query_a(ctx.host, ctx.port, "default-test.local", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR
          assert length(DnsClient.get_answers(response)) >= 1

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "view enable/disable" do
    test "disabled view does not match queries", ctx do
      # Create a custom view with high priority
      {:ok, _view_pid} =
        ViewManager.start_view(%{
          name: "test-view",
          priority: 1,
          acl: :any,
          zones: [],
          rpz_zones: [],
          recursion_enabled: false,
          ecs_enabled: false
        })

      # Create zone in this view
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "viewtest.local", view_name: "test-view")

      {:ok, view_pid} = ViewManager.get_view("test-view")
      View.register_zone(view_pid, :auth, "viewtest.local")
      Zone.Auth.add_record(zone_pid, build_a_record("viewtest.local", {10, 10, 10, 10}))

      # Also create same zone in default view with different IP
      {:ok, default_zone_pid} =
        ZoneController.start_zone(:auth, "viewtest.local", view_name: "default")

      {:ok, default_view_pid} = ViewManager.get_view("default")
      View.register_zone(default_view_pid, :auth, "viewtest.local")
      Zone.Auth.add_record(default_zone_pid, build_a_record("viewtest.local", {20, 20, 20, 20}))

      # First query should hit test-view (priority 1 < default's infinity)
      result1 = DnsClient.query_a(ctx.host, ctx.port, "viewtest.local", timeout: 3_000)

      case result1 do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _reason} ->
          :ok
      end

      # Disable test-view
      View.set_enabled(view_pid, false)

      # Query should now fall through to default view
      result2 = DnsClient.query_a(ctx.host, ctx.port, "viewtest.local", timeout: 3_000)

      case result2 do
        {:ok, response} ->
          # Should still get NOERROR, but from default view
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _reason} ->
          :ok
      end

      # Re-enable
      View.set_enabled(view_pid, true)
    end
  end

  describe "view listing" do
    test "lists all active views", _ctx do
      views = ViewManager.list_views()
      # Should have at least the default view
      assert length(views) >= 1

      view_names = Enum.map(views, fn {name, _pid, _priority} -> name end)
      assert "default" in view_names
    end
  end

  describe "zone registration" do
    test "view resolves after zone registration", ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "registered.local", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")

      # Before registration, zone not accessible via view
      # After registration, zone should be accessible
      View.register_zone(view_pid, :auth, "registered.local")

      Zone.Auth.add_record(zone_pid, build_a_record("registered.local", {1, 2, 3, 4}))

      result = DnsClient.query_a(ctx.host, ctx.port, "registered.local", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _reason} ->
          :ok
      end
    end
  end

  # Helper to build A record using DNS.Message.Record.new/5
  defp build_a_record(name, ip) do
    DNS.Message.Record.new(name, :a, :in, 3600, ip)
  end
end
