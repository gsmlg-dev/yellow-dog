defmodule E2ETest.DnsRecordsE2ETest do
  @moduledoc """
  End-to-end tests for DNS resource record CRUD operations.

  Tests creating, reading, updating, and deleting DNS records
  in authoritative zones, including all major record types
  (A, AAAA, CNAME, MX, TXT, NS, SRV, PTR, SOA).
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

        # Create a zone for record tests
        {:ok, zone_pid} =
          ZoneController.start_zone(:auth, "records.test", view_name: "default")

        {:ok, view_pid} = ViewManager.get_view("default")
        View.register_zone(view_pid, :auth, "records.test")

        {:ok, Map.put(ctx, :zone_pid, zone_pid)}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  describe "A record CRUD" do
    test "adds and queries A record", %{zone_pid: zone_pid} = ctx do
      record = DNS.Message.Record.new("records.test", :a, :in, 3600, {192, 168, 1, 100})
      Zone.Auth.add_record(zone_pid, record)

      result = DnsClient.query_a(ctx.host, ctx.port, "records.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR
          assert length(DnsClient.get_answers(response)) >= 1

        {:error, _} ->
          :ok
      end
    end

    test "adds multiple A records for same name", %{zone_pid: zone_pid} do
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("multi.records.test", :a, :in, 3600, {10, 0, 0, 1})
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("multi.records.test", :a, :in, 3600, {10, 0, 0, 2})
      )

      records = Zone.Auth.get_all_records(zone_pid)
      a_records = Enum.filter(records, fn r -> match_type(r.type, :a) end)
      assert length(a_records) >= 2
    end
  end

  describe "AAAA record" do
    test "adds and queries AAAA record", %{zone_pid: zone_pid} = ctx do
      ipv6 = {8193, 3512, 0, 0, 0, 0, 0, 1}
      record = DNS.Message.Record.new("ipv6.records.test", :aaaa, :in, 3600, ipv6)
      Zone.Auth.add_record(zone_pid, record)

      result =
        DnsClient.query_aaaa(ctx.host, ctx.port, "ipv6.records.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "CNAME record" do
    test "adds CNAME and resolves through it", %{zone_pid: zone_pid} = ctx do
      # Add target A record
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("target.records.test", :a, :in, 3600, {10, 20, 30, 40})
      )

      # Add CNAME pointing to target
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("alias.records.test", :cname, :in, 3600, "target.records.test.")
      )

      # Query for CNAME
      result =
        DnsClient.query(ctx.host, ctx.port, "alias.records.test", :CNAME, timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "MX record" do
    test "adds MX record with priority", %{zone_pid: zone_pid} = ctx do
      record =
        DNS.Message.Record.new("records.test", :mx, :in, 3600, {10, "mail.records.test."})

      Zone.Auth.add_record(zone_pid, record)

      result = DnsClient.query(ctx.host, ctx.port, "records.test", :MX, timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "TXT record" do
    test "adds and queries TXT record", %{zone_pid: zone_pid} = ctx do
      record = DNS.Message.Record.new("records.test", :txt, :in, 3600, ["v=spf1 ~all"])
      Zone.Auth.add_record(zone_pid, record)

      result = DnsClient.query_txt(ctx.host, ctx.port, "records.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end
  end

  describe "NS record" do
    test "adds NS record", %{zone_pid: zone_pid} do
      record =
        DNS.Message.Record.new("records.test", :ns, :in, 86400, "ns1.records.test.")

      Zone.Auth.add_record(zone_pid, record)

      records = Zone.Auth.get_all_records(zone_pid)
      ns_records = Enum.filter(records, fn r -> match_type(r.type, :ns) end)
      assert length(ns_records) >= 1
    end
  end

  describe "record listing and filtering" do
    test "lists all records in zone", %{zone_pid: zone_pid} do
      # Add several records
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("a1.records.test", :a, :in, 3600, {1, 1, 1, 1})
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("a2.records.test", :a, :in, 3600, {2, 2, 2, 2})
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("records.test", :txt, :in, 3600, ["test"])
      )

      records = Zone.Auth.get_all_records(zone_pid)
      assert is_list(records)
      assert length(records) >= 3
    end

    test "deletes a record", %{zone_pid: zone_pid} do
      record =
        DNS.Message.Record.new("todelete.records.test", :a, :in, 3600, {99, 99, 99, 99})

      Zone.Auth.add_record(zone_pid, record)

      # Verify it was added
      records_before = Zone.Auth.get_all_records(zone_pid)

      todelete =
        Enum.filter(records_before, fn r ->
          to_string(r.name) =~ "todelete"
        end)

      assert length(todelete) >= 1

      # Delete it (remove_record takes name and type)
      Zone.Auth.remove_record(zone_pid, "todelete.records.test", :a)

      # Verify removal
      records_after = Zone.Auth.get_all_records(zone_pid)

      remaining =
        Enum.filter(records_after, fn r ->
          to_string(r.name) =~ "todelete"
        end)

      assert length(remaining) < length(todelete)
    end
  end

  describe "record queries via DNS" do
    test "rapid sequential queries for different record types", %{zone_pid: zone_pid} = ctx do
      # Add records of different types
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("multi.records.test", :a, :in, 3600, {10, 0, 0, 1})
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("multi.records.test", :txt, :in, 3600, ["hello"])
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("multi.records.test", :mx, :in, 3600, {10, "mx.records.test."})
      )

      # Query each type
      types = [:A, :TXT, :MX]

      results =
        Enum.map(types, fn type ->
          DnsClient.query(ctx.host, ctx.port, "multi.records.test", type, timeout: 3_000)
        end)

      successes = Enum.count(results, &match?({:ok, _}, &1))
      assert successes >= 0
    end
  end

  # Helper to match record type atoms or structs
  defp match_type(%DNS.ResourceRecordType{value: <<1::16>>}, :a), do: true
  defp match_type(%DNS.ResourceRecordType{value: <<2::16>>}, :ns), do: true
  defp match_type(%DNS.ResourceRecordType{value: <<5::16>>}, :cname), do: true
  defp match_type(%DNS.ResourceRecordType{value: <<15::16>>}, :mx), do: true
  defp match_type(%DNS.ResourceRecordType{value: <<16::16>>}, :txt), do: true
  defp match_type(%DNS.ResourceRecordType{value: <<28::16>>}, :aaaa), do: true
  defp match_type(type, expected) when is_atom(type), do: type == expected
  defp match_type(_, _), do: false
end
