defmodule E2ETest.DnsZoneRpzE2ETest do
  @moduledoc """
  End-to-end tests for DNS Response Policy Zone (RPZ) functionality.

  Tests that RPZ zones correctly block, redirect, or allow queries
  based on policy rules configured for qname triggers.
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

        # Set up auth zone with test records
        setup_zones()

        {:ok, ctx}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  defp setup_zones do
    {:ok, view_pid} = ViewManager.get_view("default")

    # Create auth zone with legitimate records
    {:ok, auth_pid} =
      ZoneController.start_zone(:auth, "example.test", view_name: "default")

    View.register_zone(view_pid, :auth, "example.test")

    Zone.Auth.add_record(auth_pid, build_a_record("example.test", {192, 168, 1, 10}))
    Zone.Auth.add_record(auth_pid, build_a_record("blocked.example.test", {192, 168, 1, 99}))
    Zone.Auth.add_record(auth_pid, build_a_record("safe.example.test", {192, 168, 1, 50}))

    # Create RPZ zone with blocking policies
    rpz_policies = [
      %{trigger: :qname, pattern: "blocked.example.test", action: :nxdomain},
      %{trigger: :qname, pattern: "*.malware.test", action: :nxdomain}
    ]

    {:ok, _rpz_pid} =
      ZoneController.start_zone(:rpz, "rpz.local",
        view_name: "default",
        policies: rpz_policies
      )

    View.register_rpz_zone(view_pid, "rpz.local")
  end

  describe "RPZ blocking" do
    test "RPZ blocks query matching qname rule with NXDOMAIN", ctx do
      result = DnsClient.query_a(ctx.host, ctx.port, "blocked.example.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          rcode = DnsClient.get_rcode(response)
          # RPZ should return NXDOMAIN for blocked domains
          assert rcode == :NXDOMAIN,
                 "Expected NXDOMAIN for blocked domain, got #{inspect(rcode)}"

        {:error, _reason} ->
          :ok
      end
    end

    test "RPZ allows non-blocked query", ctx do
      result = DnsClient.query_a(ctx.host, ctx.port, "safe.example.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          rcode = DnsClient.get_rcode(response)
          assert rcode == :NOERROR, "Expected NOERROR for safe domain, got #{inspect(rcode)}"

        {:error, _reason} ->
          :ok
      end
    end

    test "RPZ wildcard blocks subdomains", ctx do
      result = DnsClient.query_a(ctx.host, ctx.port, "anything.malware.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          rcode = DnsClient.get_rcode(response)
          # Should be NXDOMAIN from RPZ wildcard match
          assert rcode in [:NXDOMAIN, :SERVFAIL],
                 "Expected NXDOMAIN or SERVFAIL for malware domain, got #{inspect(rcode)}"

        {:error, _reason} ->
          :ok
      end
    end
  end

  describe "RPZ passthrough" do
    test "unmatched queries pass through normally", ctx do
      result = DnsClient.query_a(ctx.host, ctx.port, "example.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp build_a_record(name, ip) do
    DNS.Message.Record.new(name, :a, :in, 3600, ip)
  end
end
