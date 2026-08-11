defmodule YellowDog.Netman.SynchronousActivationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.ReconciliationEngine
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  test "waits for the selected connection to reach activated" do
    suffix = System.unique_integer([:positive])
    interface = "syncok#{suffix}" |> String.slice(0, 15)
    profile = profile("sync-activate-#{suffix}", interface, :disabled)

    MockNetlink.link_up(interface, carrier: true)
    assert :ok = ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      MockNetlink.link_removed(interface)
      ProfileStore.delete(profile.id)
    end)

    assert :ok = Netman.activate(profile.id)
    assert {:ok, %{state: :activated}} = connection_state(interface)
    assert {:ok, desired_revision} = ProfileStore.revision(profile.id)
    assert {:ok, %{active_revision: ^desired_revision}} = ProfileStore.state(profile.id)
  end

  test "returns a structured terminal failure for an unavailable selected interface" do
    suffix = System.unique_integer([:positive])
    interface = "missing#{suffix}" |> String.slice(0, 15)
    profile = profile("sync-unavailable-#{suffix}", interface, :disabled)

    assert :ok = ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      ProfileStore.delete(profile.id)
    end)

    assert {:error,
            {:activation_failed,
             %{
               profile_id: profile_id,
               interface: ^interface,
               state: :unavailable
             }}} = Netman.activate(profile.id)

    assert profile_id == profile.id
    assert {:ok, %{active_revision: nil}} = ProfileStore.state(profile.id)
  end

  test "waits for every interface selected by a wildcard profile" do
    suffix = System.unique_integer([:positive])
    interfaces = ["synca#{suffix}", "syncb#{suffix}"] |> Enum.map(&String.slice(&1, 0, 15))
    profile = %{profile("sync-all-#{suffix}", List.first(interfaces), :disabled) | interface: nil}

    Enum.each(interfaces, &MockNetlink.link_up(&1, carrier: true))
    assert :ok = ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.list_connections()
      |> Enum.filter(&(&1.profile_id == profile.id))
      |> Enum.each(&Connection.Supervisor.stop_connection(&1.interface))

      Enum.each(interfaces, &MockNetlink.link_removed/1)
      ProfileStore.delete(profile.id)
    end)

    assert {:ok, activated} =
             ReconciliationEngine.activate_and_wait(profile.id, timeout: 1_000)

    activated_interfaces = MapSet.new(activated, & &1.interface)
    assert Enum.all?(interfaces, &MapSet.member?(activated_interfaces, &1))
    assert Enum.all?(activated, &(&1.state == :activated and &1.profile_id == profile.id))
  end

  test "honors a short injected timeout without claiming activation" do
    suffix = System.unique_integer([:positive])
    interface = "syncto#{suffix}" |> String.slice(0, 15)
    profile = profile("sync-timeout-#{suffix}", interface, :manual)

    MockNetlink.link_up(interface, carrier: true)
    assert :ok = ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      MockNetlink.link_removed(interface)
      ProfileStore.delete(profile.id)
    end)

    assert {:error,
            {:activation_timeout,
             %{
               profile_id: profile_id,
               pending: [%{interface: ^interface, state: pending_state}],
               timeout_ms: 10
             }}} = ReconciliationEngine.activate_and_wait(profile.id, timeout: 10)

    assert profile_id == profile.id
    assert pending_state in [:prepare, :configuring, :ip_check]
  end

  test "connection deactivation waits until cleanup reaches disconnected" do
    suffix = System.unique_integer([:positive])
    interface = "syncdown#{suffix}" |> String.slice(0, 15)
    profile = profile("sync-deactivate-#{suffix}", interface, :disabled)

    MockNetlink.link_up(interface, carrier: true)
    assert :ok = ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      MockNetlink.link_removed(interface)
      ProfileStore.delete(profile.id)
    end)

    assert {:ok, [%{interface: ^interface, state: :activated}]} =
             ReconciliationEngine.activate_connection_and_wait(profile.id, interface,
               timeout: 1_000
             )

    assert {:ok, %{profile_id: profile_id, interface: ^interface, state: :deactivated}} =
             ReconciliationEngine.deactivate_connection_and_wait(profile.id, interface,
               timeout: 1_000
             )

    assert profile_id == profile.id
    assert {:ok, %{state: :disconnected}} = connection_state(interface)
  end

  defp connection_state(interface) do
    with {:ok, pid} <- Connection.Supervisor.find_connection(interface) do
      Connection.FSM.get_state(pid)
    end
  end

  defp profile(id, interface, ipv4_method) do
    ipv4 =
      case ipv4_method do
        :manual ->
          %{
            method: :manual,
            address: "192.0.2.10/24",
            gateway: nil,
            dns: [],
            dns_search: []
          }

        :disabled ->
          %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
      end

    %Profile{
      id: id,
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      zone: "default",
      ethernet: %{mtu: nil},
      ipv4: ipv4,
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }
  end
end
