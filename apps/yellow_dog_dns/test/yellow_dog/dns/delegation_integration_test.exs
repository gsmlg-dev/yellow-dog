defmodule YellowDog.Dns.DelegationIntegrationTest do
  @moduledoc """
  Integration tests for DNS view-based resolution with zone delegation.

  Tests the full resolution pipeline: ViewManager → View → ZoneController → Zone.Auth
  with real processes (not mocks).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Dns.Zone.Auth
  alias DNS.Message
  alias DNS.Message.Header

  setup do
    # Stop any externally-owned registries and start fresh ones under ExUnit supervision.
    # This eliminates the TOCTOU race where ensure_registry sees a registry owned by
    # another test's supervisor, which may be killed between the check and our start_zone call.
    for name <- [YellowDog.Dns.ZoneRegistry, YellowDog.Dns.ViewRegistry] do
      if pid = Process.whereis(name), do: GenServer.stop(pid, :normal, 500)
      start_supervised!({Registry, keys: :unique, name: name})
    end

    # Start the global ZoneController (View.resolve_in_zone uses ZoneController module name)
    zc_pid =
      case DynamicSupervisor.start_link(
             strategy: :one_for_one,
             name: YellowDog.Dns.ZoneController
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    # Start a test-specific ViewManager
    vm_name = :"vm_#{:erlang.unique_integer([:positive])}"
    {:ok, vm_pid} = ViewManager.start_link(name: vm_name)

    on_exit(fn ->
      # Stop views first, then zones, then supervisors
      try do
        if Process.alive?(vm_pid), do: DynamicSupervisor.stop(vm_pid)
      catch
        :exit, _ -> :ok
      end

      # Terminate all children of the global ZoneController
      try do
        for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(zc_pid),
            is_pid(pid) do
          DynamicSupervisor.terminate_child(zc_pid, pid)
        end
      catch
        :exit, _ -> :ok
      end
    end)

    %{vm: vm_pid, vm_name: vm_name}
  end

  describe "view-based zone resolution" do
    test "auth zone resolves A record through view", %{vm: vm} do
      view_name = "test_view_#{:erlang.unique_integer([:positive])}"

      # Start zone under the global ZoneController
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "example.com",
          view_name: view_name,
          zone_data: [
            %{name: "example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 10}},
            %{name: "www.example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 20}}
          ]
        )

      # Start view and register the zone
      {:ok, view_pid} =
        ViewManager.start_view(vm, %{
          name: view_name,
          priority: 10,
          acl: :any,
          zones: [{:auth, "example.com"}],
          recursion_enabled: false
        })

      # Build and resolve query
      query = build_query("www.example.com", :a)
      {:ok, response} = View.resolve(view_pid, self(), 1, query)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert length(response.anlist) >= 1

      GenServer.stop(zone_pid)
      GenServer.stop(view_pid)
    end

    test "auth zone returns NXDOMAIN for non-existent name", %{vm: vm} do
      view_name = "test_nxd_#{:erlang.unique_integer([:positive])}"

      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "example.com",
          view_name: view_name,
          zone_data: [
            %{name: "example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 10}}
          ]
        )

      {:ok, view_pid} =
        ViewManager.start_view(vm, %{
          name: view_name,
          priority: 10,
          acl: :any,
          zones: [{:auth, "example.com"}],
          recursion_enabled: false
        })

      query = build_query("nonexistent.example.com", :a)
      {:ok, response} = View.resolve(view_pid, self(), 1, query)

      # NXDOMAIN response
      assert response.header.qr == 1
      assert response.anlist == []

      GenServer.stop(zone_pid)
      GenServer.stop(view_pid)
    end

    test "view refuses query for domain outside its zones", %{vm: vm} do
      view_name = "test_refuse_#{:erlang.unique_integer([:positive])}"

      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "example.com",
          view_name: view_name,
          zone_data: [
            %{name: "example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 10}}
          ]
        )

      {:ok, view_pid} =
        ViewManager.start_view(vm, %{
          name: view_name,
          priority: 10,
          acl: :any,
          zones: [{:auth, "example.com"}],
          recursion_enabled: false
        })

      # Query for a domain not in any zone
      query = build_query("other.net", :a)
      result = View.resolve(view_pid, self(), 1, query)

      assert result == {:error, :refused}

      GenServer.stop(zone_pid)
      GenServer.stop(view_pid)
    end

    test "zone apex query returns correct records", %{vm: vm} do
      view_name = "test_apex_#{:erlang.unique_integer([:positive])}"

      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "example.com",
          view_name: view_name,
          zone_data: [
            %{name: "example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 10}},
            %{name: "example.com", type: :ns, class: :in, ttl: 86400, rdata: "ns1.example.com"},
            %{name: "example.com", type: :ns, class: :in, ttl: 86400, rdata: "ns2.example.com"}
          ]
        )

      {:ok, view_pid} =
        ViewManager.start_view(vm, %{
          name: view_name,
          priority: 10,
          acl: :any,
          zones: [{:auth, "example.com"}],
          recursion_enabled: false
        })

      # Query for zone apex NS records
      query = build_query("example.com", :ns)
      {:ok, response} = View.resolve(view_pid, self(), 1, query)

      assert response.header.qr == 1
      assert length(response.anlist) == 2

      GenServer.stop(zone_pid)
      GenServer.stop(view_pid)
    end

    test "subdomain query finds records in parent zone", %{vm: vm} do
      view_name = "test_sub_#{:erlang.unique_integer([:positive])}"

      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "example.com",
          view_name: view_name,
          zone_data: [
            %{name: "example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 10}},
            %{name: "sub.example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 20}},
            %{
              name: "deep.sub.example.com",
              type: :a,
              class: :in,
              ttl: 3600,
              rdata: {192, 168, 1, 30}
            }
          ]
        )

      {:ok, view_pid} =
        ViewManager.start_view(vm, %{
          name: view_name,
          priority: 10,
          acl: :any,
          zones: [{:auth, "example.com"}],
          recursion_enabled: false
        })

      # Query for subdomain
      query = build_query("sub.example.com", :a)
      {:ok, response} = View.resolve(view_pid, self(), 1, query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1

      # Query for deep subdomain
      query2 = build_query("deep.sub.example.com", :a)
      {:ok, response2} = View.resolve(view_pid, self(), 2, query2)

      assert response2.header.qr == 1
      assert length(response2.anlist) == 1

      GenServer.stop(zone_pid)
      GenServer.stop(view_pid)
    end
  end

  describe "zone CRUD through ZoneController" do
    test "can start and stop zones dynamically" do
      view_name = "crud_view_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} =
        ZoneController.start_zone(:auth, "test.com",
          view_name: view_name,
          zone_data: [
            %{name: "test.com", type: :a, class: :in, ttl: 3600, rdata: {1, 2, 3, 4}}
          ]
        )

      assert Process.alive?(pid)

      # Find the zone
      {:ok, found_pid} = ZoneController.find_zone(view_name, :auth, "test.com")
      assert found_pid == pid

      # Stop the zone
      :ok = ZoneController.stop_zone(view_name, :auth, "test.com")
      refute Process.alive?(pid)
    end

    test "lists zones from the controller" do
      v1 = "list_v1_#{:erlang.unique_integer([:positive])}"
      v2 = "list_v2_#{:erlang.unique_integer([:positive])}"

      {:ok, z1} =
        ZoneController.start_zone(:auth, "a.com", view_name: v1, zone_data: [])

      {:ok, z2} =
        ZoneController.start_zone(:auth, "b.com", view_name: v1, zone_data: [])

      {:ok, z3} =
        ZoneController.start_zone(:auth, "c.com", view_name: v2, zone_data: [])

      all_zones = ZoneController.list_zones()
      # Filter to only our test zones (other tests may have zones running)
      our_zones =
        Enum.filter(all_zones, fn {view, _type, _name, _pid} ->
          view == v1 or view == v2
        end)

      assert length(our_zones) == 3

      v1_zones = ZoneController.list_zones_for_view(v1)
      assert length(v1_zones) == 2

      v2_zones = ZoneController.list_zones_for_view(v2)
      assert length(v2_zones) == 1

      GenServer.stop(z1)
      GenServer.stop(z2)
      GenServer.stop(z3)
    end

    test "auth zone supports add and remove records dynamically" do
      view_name = "dyn_view_#{:erlang.unique_integer([:positive])}"

      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "dynamic.com",
          view_name: view_name,
          zone_data: []
        )

      # Add a record
      record = %{name: "www.dynamic.com", type: :a, class: :in, ttl: 3600, rdata: {10, 0, 0, 1}}
      :ok = Auth.add_record(zone_pid, record)

      # Verify the record exists
      records = Auth.get_records(zone_pid, "www.dynamic.com", :a)
      assert length(records) == 1

      # Remove the record
      :ok = Auth.remove_record(zone_pid, "www.dynamic.com", :a)

      records_after = Auth.get_records(zone_pid, "www.dynamic.com", :a)
      assert records_after == []

      GenServer.stop(zone_pid)
    end
  end

  # Helper functions

  defp build_query(name, type) do
    %Message{
      header: %Header{
        id: :rand.uniform(65535),
        qr: false,
        opcode: 0,
        aa: false,
        tc: false,
        rd: true,
        ra: false,
        z: 0,
        rcode: DNS.Message.RCode.no_error()
      },
      qdlist: [
        %{name: name, type: type, class: :in}
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end
end
