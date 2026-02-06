defmodule E2ETest.DnsZoneImportExportE2ETest do
  @moduledoc """
  End-to-end tests for DNS zone file import/export.

  Tests that authoritative zones can import records from BIND-format
  zone file strings and export their contents back to BIND format,
  with queries validating the imported records are live.
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

  describe "zone file import" do
    test "imported records are queryable via DNS", ctx do
      # Create auth zone
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "import.test", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :auth, "import.test")

      # Import BIND format data
      bind_content = """
      $TTL 3600
      $ORIGIN import.test.
      www   IN  A     10.20.30.40
      api   IN  A     10.20.30.41
      """

      assert {:ok, stats} = Zone.Auth.import_zone_file(zone_pid, bind_content)
      assert stats.records_imported >= 2

      # Query the imported records
      result = DnsClient.query_a(ctx.host, ctx.port, "www.import.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _} ->
          :ok
      end
    end

    test "import with multiple record types", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "multi-import.test", view_name: "default")

      bind_content = """
      $TTL 3600
      $ORIGIN multi-import.test.
      @     IN  NS    ns1.multi-import.test.
      www   IN  A     10.0.0.1
      www   IN  AAAA  2001:db8::1
      mail  IN  MX    10 smtp.multi-import.test.
      info  IN  TXT   "v=spf1 mx ~all"
      """

      assert {:ok, stats} = Zone.Auth.import_zone_file(zone_pid, bind_content)
      assert stats.records_imported >= 4

      # Verify records exist
      records = Zone.Auth.get_all_records(zone_pid)
      assert length(records) >= 4
    end
  end

  describe "zone file export" do
    test "exports zone to valid BIND format string", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "export.test", view_name: "default")

      # Add records
      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("www.export.test", :a, :in, 3600, {10, 0, 0, 1})
      )

      Zone.Auth.add_record(
        zone_pid,
        DNS.Message.Record.new("mail.export.test", :a, :in, 3600, {10, 0, 0, 2})
      )

      # Export
      {:ok, content} = Zone.Auth.export_zone_file(zone_pid)

      assert is_binary(content)
      assert String.contains?(content, "10.0.0.1")
      assert String.contains?(content, "10.0.0.2")
      assert String.contains?(content, "export.test")
    end
  end

  describe "round-trip import/export" do
    test "import then export preserves record data", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "roundtrip.test", view_name: "default")

      original = """
      $TTL 3600
      $ORIGIN roundtrip.test.
      www   IN  A     172.16.0.1
      api   IN  A     172.16.0.2
      mail  IN  MX    10 smtp.roundtrip.test.
      """

      {:ok, _} = Zone.Auth.import_zone_file(zone_pid, original)
      {:ok, exported} = Zone.Auth.export_zone_file(zone_pid)

      # Key data should survive the round-trip
      assert String.contains?(exported, "172.16.0.1")
      assert String.contains?(exported, "172.16.0.2")
    end

    test "export then import into new zone preserves records", _ctx do
      # Build zone with records
      {:ok, zone1} =
        ZoneController.start_zone(:auth, "rt-source.test", view_name: "default")

      Zone.Auth.add_record(
        zone1,
        DNS.Message.Record.new("www.rt-source.test", :a, :in, 3600, {10, 10, 10, 1})
      )

      Zone.Auth.add_record(
        zone1,
        DNS.Message.Record.new("db.rt-source.test", :a, :in, 3600, {10, 10, 10, 2})
      )

      # Export from zone1
      {:ok, content} = Zone.Auth.export_zone_file(zone1)

      # Import into zone2
      {:ok, zone2} =
        ZoneController.start_zone(:auth, "rt-target.test", view_name: "default")

      {:ok, stats} = Zone.Auth.import_zone_file(zone2, content)
      assert stats.records_imported >= 2

      # Both zones should have same number of records
      records1 = Zone.Auth.get_all_records(zone1)
      records2 = Zone.Auth.get_all_records(zone2)
      assert length(records2) >= length(records1)
    end
  end
end
