defmodule YellowDog.Netman.Control.ProfileActivationResultTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Control.Profiles
  alias YellowDog.Netman.Kernel.LinkMonitor
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  test "wildcard activation returns one explicit result per selected interface" do
    suffix = System.unique_integer([:positive])
    MockNetlink.link_up("stale#{suffix}" |> String.slice(0, 15), carrier: true)
    isolate_link_table()

    profile_id = "control-wildcard-#{suffix}"
    interfaces = ["wc-a#{suffix}", "wc-b#{suffix}"] |> Enum.map(&String.slice(&1, 0, 15))

    Enum.each(interfaces, &MockNetlink.link_up(&1, carrier: true))

    on_exit(fn ->
      Enum.each(interfaces, &Connection.Supervisor.stop_connection/1)
      Netman.delete_profile(profile_id)
      Enum.each(interfaces, &MockNetlink.link_removed/1)
    end)

    assert {:ok, created} =
             Profiles.dispatch(
               "netman.profiles.put",
               wire_profile(profile_id),
               mutation_context(:must_be_missing)
             )

    revision = created["desired_revision"]

    assert {:ok, activated} =
             Profiles.dispatch(
               "netman.profiles.activate",
               %{"profile_id" => profile_id},
               mutation_context({:revision, revision}, revision)
             )

    assert activated["profile_id"] == profile_id
    assert activated["desired_revision"] == revision
    assert activated["active_revision"] == revision
    assert activated["state"] == "activated"

    assert activated["connections"] ==
             Enum.map(interfaces, fn interface ->
               %{
                 "profile_id" => profile_id,
                 "interface" => interface,
                 "state" => "activated"
               }
             end)

    assert {:ok, operation} = NetmanOperation.fetch("netman.profiles.activate")
    assert {:ok, ^activated} = Operation.validate_result(operation, activated)
  end

  defp isolate_link_table do
    LinkMonitor.list_links()
    |> Enum.each(&MockNetlink.link_removed(&1.interface))

    assert LinkMonitor.list_links() == []
  end

  defp mutation_context(precondition, current_revision \\ :missing) do
    %{
      expected_revision: if(is_binary(current_revision), do: current_revision, else: nil),
      current_revision: current_revision,
      precondition: precondition,
      config_version: nil
    }
  end

  defp wire_profile(profile_id) do
    %{
      "profile_id" => profile_id,
      "type" => "ethernet",
      "interface" => nil,
      "autoconnect" => false,
      "autoconnect_priority" => 10,
      "zone" => "default",
      "ethernet" => %{"mtu" => nil},
      "ipv4" => %{
        "method" => "disabled",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      },
      "ipv6" => %{
        "method" => "disabled",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      }
    }
  end
end
