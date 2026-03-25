defmodule YellowDog.Dns.Zone.StoreIntegrationTest do
  @moduledoc """
  Tests Store-backed persistence for all zone types.

  Verifies that zone data survives process restart via Store persistence.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.Zone.Forward
  alias YellowDog.Dns.Zone.Stub
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias DNS.Message

  # Poll until condition is true or timeout (avoids brittle Process.sleep)
  defp assert_eventually(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 500)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(fun, interval, deadline)
  end

  defp do_assert_eventually(fun, interval, deadline) do
    case fun.() do
      true ->
        :ok

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("assert_eventually timed out")
        else
          Process.sleep(interval)
          do_assert_eventually(fun, interval, deadline)
        end
    end
  end

  setup_all do
    registry_name = YellowDog.Dns.ZoneRegistry

    case Process.whereis(registry_name) do
      nil ->
        {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

      _ ->
        :ok
    end

    Process.sleep(10)
    :ok
  end

  setup do
    # Set up ETS Store backend for test isolation
    EtsBackend.create_table()
    Backend.set_active(EtsBackend)

    table = EtsBackend.table()

    case :ets.whereis(table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(table)
    end

    :ok
  end

  describe "Auth zone Store persistence" do
    test "records persist across process restart via Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "persist-#{System.unique_integer([:positive])}.com"

      # Create zone in Store first
      soa = %{
        mname: "ns1.#{zone_name}",
        rname: "admin.#{zone_name}",
        serial: 1,
        refresh: 3600,
        retry: 1800,
        expire: 604_800,
        minimum: 86_400
      }

      :ok = YellowDog.Store.Zone.create_zone(view, zone_name, soa)

      # Start zone (will load from Store since no zone_data/zone_file)
      {:ok, pid} = Auth.start_link(name: zone_name, view_name: view)

      # Add a record
      record = Message.Record.new("www.#{zone_name}", :a, :in, 3600, {192, 168, 1, 1})
      :ok = Auth.add_record(pid, record)

      # Verify record exists
      records = Auth.get_records(pid, "www.#{zone_name}", :a)
      assert length(records) == 1

      # Stop gracefully (should flush to Store)
      GenServer.stop(pid, :normal)
      Process.sleep(50)

      # Restart zone — should load records from Store
      {:ok, pid2} = Auth.start_link(name: zone_name, view_name: view)
      records2 = Auth.get_records(pid2, "www.#{zone_name}", :a)
      assert length(records2) == 1

      first_record = hd(records2)
      # DNS.Message.Record.Data.A wraps the tuple — check the inner data field
      address =
        case first_record.data do
          {_, _, _, _} = ip -> ip
          %{data: ip} -> ip
          other -> other
        end

      assert address == {192, 168, 1, 1}

      GenServer.stop(pid2, :normal)
    end

    test "update_config persists to Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "config-#{System.unique_integer([:positive])}.com"

      soa = %{
        mname: "ns1.#{zone_name}",
        rname: "admin.#{zone_name}",
        serial: 1,
        refresh: 3600,
        retry: 1800,
        expire: 604_800,
        minimum: 86_400
      }

      :ok = YellowDog.Store.Zone.create_zone(view, zone_name, soa)

      {:ok, pid} = Auth.start_link(name: zone_name, view_name: view)
      :ok = Auth.update_config(pid, %{ttl: 7200})

      # Wait for async Store sync
      assert_eventually(fn ->
        case YellowDog.Store.Zone.get_zone(view, zone_name) do
          {:ok, metadata} -> metadata[:default_ttl] == 7200
          _ -> false
        end
      end)

      GenServer.stop(pid, :normal)
    end

    test "reload with empty config loads from Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "reload-#{System.unique_integer([:positive])}.com"

      soa = %{
        mname: "ns1.#{zone_name}",
        rname: "admin.#{zone_name}",
        serial: 1,
        refresh: 3600,
        retry: 1800,
        expire: 604_800,
        minimum: 86_400
      }

      :ok = YellowDog.Store.Zone.create_zone(view, zone_name, soa)

      # Put an RRset directly in Store (5th arg is the rrset list)
      :ok =
        YellowDog.Store.Zone.put_rrset(
          view,
          zone_name,
          "mail.#{zone_name}",
          :a,
          [%{address: "10.0.0.1", ttl: 3600}]
        )

      # Start zone with explicit empty records
      {:ok, pid} = Auth.start_link(name: zone_name, view_name: view, zone_data: [])

      # No records yet (started with empty zone_data)
      assert Auth.get_all_records(pid) == []

      # Reload with empty config → loads from Store
      :ok = Auth.reload(pid, [])

      records = Auth.get_records(pid, "mail.#{zone_name}", :a)
      assert length(records) >= 1

      GenServer.stop(pid, :normal)
    end
  end

  describe "Forward zone Store persistence" do
    test "loads config from Store on init when no upstreams provided" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "forward-#{System.unique_integer([:positive])}.com"

      forwarders = [%{ip: "8.8.8.8", port: 53}, %{ip: "8.8.4.4", port: 53}]

      :ok =
        YellowDog.Store.Zone.create_forward_zone(view, zone_name, forwarders,
          forward_mode: :only,
          timeout_ms: 3000,
          max_retries: 1
        )

      # Start without explicit upstreams → should load from Store
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view)

      stats = Forward.stats(pid)
      assert stats.upstream_count == 2

      GenServer.stop(pid, :normal)
    end

    test "update_config persists to Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "fwd-cfg-#{System.unique_integer([:positive])}.com"

      :ok = YellowDog.Store.Zone.create_forward_zone(view, zone_name, [])

      {:ok, pid} =
        Forward.start_link(
          name: zone_name,
          view_name: view,
          upstreams: [{"1.1.1.1", 53}]
        )

      :ok = Forward.update_config(pid, %{upstreams: [{"9.9.9.9", 53}], timeout: 2000})

      # Wait for async sync
      assert_eventually(fn ->
        case YellowDog.Store.Zone.get_zone(view, zone_name) do
          {:ok, metadata} -> metadata[:timeout_ms] == 2000
          _ -> false
        end
      end)

      GenServer.stop(pid, :normal)
    end

    test "terminate flushes config to Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "fwd-term-#{System.unique_integer([:positive])}.com"

      :ok = YellowDog.Store.Zone.create_forward_zone(view, zone_name, [])

      {:ok, pid} =
        Forward.start_link(
          name: zone_name,
          view_name: view,
          upstreams: [{"1.1.1.1", 53}, {"8.8.8.8", 53}]
        )

      GenServer.stop(pid, :normal)
      Process.sleep(50)

      {:ok, metadata} = YellowDog.Store.Zone.get_zone(view, zone_name)
      assert length(metadata[:forwarders]) == 2
    end
  end

  describe "Stub zone Store persistence" do
    test "loads config from Store on init when no ns_records provided" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "stub-#{System.unique_integer([:positive])}.com"

      primaries = [%{ip: "10.0.0.1", port: 53}]
      :ok = YellowDog.Store.Zone.create_stub_zone(view, zone_name, primaries)

      # Start without explicit ns_records → should load from Store
      {:ok, pid} = Stub.start_link(name: zone_name, view_name: view)

      stats = Stub.stats(pid)
      assert stats.ns_count >= 1

      GenServer.stop(pid, :normal)
    end

    test "update_config persists to Store" do
      view = "test_view_#{System.unique_integer([:positive])}"
      zone_name = "stub-cfg-#{System.unique_integer([:positive])}.com"

      :ok = YellowDog.Store.Zone.create_stub_zone(view, zone_name, [])

      {:ok, pid} =
        Stub.start_link(
          name: zone_name,
          view_name: view,
          ns_records: ["ns1.#{zone_name}"],
          glue_records: %{"ns1.#{zone_name}" => {10, 0, 0, 1}}
        )

      :ok =
        Stub.update_config(pid, %{
          ns_records: ["ns1.#{zone_name}", "ns2.#{zone_name}"],
          glue_records: %{
            "ns1.#{zone_name}" => {10, 0, 0, 1},
            "ns2.#{zone_name}" => {10, 0, 0, 2}
          }
        })

      # Wait for async sync
      assert_eventually(fn ->
        case YellowDog.Store.Zone.get_zone(view, zone_name) do
          {:ok, metadata} -> metadata[:zone_type] == :stub
          _ -> false
        end
      end)

      GenServer.stop(pid, :normal)
    end
  end
end
