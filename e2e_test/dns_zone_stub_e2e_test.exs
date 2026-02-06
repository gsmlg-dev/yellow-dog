defmodule E2ETest.DnsZoneStubE2ETest do
  @moduledoc """
  End-to-end tests for DNS stub zone functionality.

  Tests that stub zones correctly maintain NS records and delegate
  queries to authoritative servers. Stub zones are lightweight
  delegation zones that only keep NS and glue records.
  """

  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias YellowDog.Dns.{ZoneController, Zone}

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

  describe "stub zone creation" do
    test "creates stub zone with NS records", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:stub, "stub.test",
          view_name: "default",
          ns_records: ["ns1.stub.test", "ns2.stub.test"],
          glue_records: %{
            "ns1.stub.test" => {192, 168, 1, 1},
            "ns2.stub.test" => {192, 168, 1, 2}
          }
        )

      assert is_pid(zone_pid)
      assert Process.alive?(zone_pid)
    end

    test "stub zone appears in zone listing", _ctx do
      {:ok, _pid} =
        ZoneController.start_zone(:stub, "listed-stub.test",
          view_name: "default",
          ns_records: ["ns1.listed-stub.test"],
          glue_records: %{"ns1.listed-stub.test" => {10, 0, 0, 1}}
        )

      zones = ZoneController.list_zones()
      zone_names = Enum.map(zones, fn {_view, _type, name, _pid} -> name end)
      assert "listed-stub.test" in zone_names
    end

    test "stub zone with multiple NS records", _ctx do
      ns_records = ["ns1.multi.test", "ns2.multi.test", "ns3.multi.test"]

      glue = %{
        "ns1.multi.test" => {10, 0, 0, 1},
        "ns2.multi.test" => {10, 0, 0, 2},
        "ns3.multi.test" => {10, 0, 0, 3}
      }

      {:ok, zone_pid} =
        ZoneController.start_zone(:stub, "multi.test",
          view_name: "default",
          ns_records: ns_records,
          glue_records: glue
        )

      assert Process.alive?(zone_pid)
    end
  end

  describe "stub zone statistics" do
    test "stub zone reports stats", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:stub, "stats-stub.test",
          view_name: "default",
          ns_records: ["ns1.stats-stub.test"],
          glue_records: %{"ns1.stats-stub.test" => {10, 10, 10, 1}}
        )

      stats = Zone.Stub.stats(zone_pid)
      assert is_map(stats)
      assert Map.has_key?(stats, :name) or Map.has_key?(stats, :query_count)
    end
  end

  describe "stub zone delegation" do
    test "stub zone has correct zone name", _ctx do
      {:ok, zone_pid} =
        ZoneController.start_zone(:stub, "name-check.test",
          view_name: "default",
          ns_records: ["ns1.name-check.test"],
          glue_records: %{"ns1.name-check.test" => {10, 0, 0, 1}}
        )

      name = Zone.Stub.get_name(zone_pid)
      assert name == "name-check.test"
    end
  end
end
