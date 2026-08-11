defmodule YellowDog.Console.Hooks.ServiceScopeTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias YellowDog.Console.Hooks.ServiceScope
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Servers
  alias YellowDog.ManagementCore

  setup do
    Servers.reset()
    Netmans.reset()

    on_exit(fn ->
      Servers.reset()
      Netmans.reset()
    end)
  end

  test "assigns only the selected Server and its connectivity metadata" do
    observed_at = ~U[2026-08-11 01:02:03Z]

    assert {:ok, server} =
             ManagementCore.register_server(%{
               id: "server-one",
               status: :online,
               last_seen_at: observed_at
             })

    assert {:cont, socket} =
             ServiceScope.on_mount(:default, %{"server_id" => server.id}, %{}, socket())

    assert socket.assigns.selected_server == server
    refute Map.has_key?(socket.assigns, :selected_netman)
    assert socket.assigns.service_online?
    assert socket.assigns.snapshot_observed_at == observed_at
    assert socket.assigns.service_scope_state == :selected
  end

  test "assigns only the selected offline Netman and keeps its observation time" do
    observed_at = ~U[2026-08-10 21:00:00Z]

    assert {:ok, netman} =
             ManagementCore.register_netman(%{
               id: "netman-one",
               status: :offline,
               last_seen_at: observed_at
             })

    assert {:cont, socket} =
             ServiceScope.on_mount(:default, %{"netman_id" => netman.id}, %{}, socket())

    assert socket.assigns.selected_netman == netman
    refute Map.has_key?(socket.assigns, :selected_server)
    refute socket.assigns.service_online?
    assert socket.assigns.snapshot_observed_at == observed_at
    assert socket.assigns.service_scope_state == :selected
  end

  test "leaves selector and global pages unselected" do
    assert {:cont, socket} = ServiceScope.on_mount(:default, %{}, %{}, socket())

    refute Map.has_key?(socket.assigns, :selected_server)
    refute Map.has_key?(socket.assigns, :selected_netman)
    refute socket.assigns.service_online?
    assert socket.assigns.snapshot_observed_at == nil
    assert socket.assigns.service_scope_state == :unscoped
  end

  test "unknown and malformed IDs halt in a stable not-found state" do
    for {params, type} <- [
          {%{"server_id" => "missing"}, :server},
          {%{"netman_id" => "missing"}, :netman},
          {%{"server_id" => String.duplicate("a", 129)}, :server},
          {%{"server_id" => "settings"}, :server},
          {%{"netman_id" => "../escape"}, :netman},
          {%{"netman_id" => "config"}, :netman}
        ] do
      assert {:halt, socket} = ServiceScope.on_mount(:default, params, %{}, socket())
      assert socket.assigns.service_scope_state == :not_found
      assert socket.assigns.service_online? == false
      assert socket.assigns.snapshot_observed_at == nil
      assert socket.redirected == {:redirect, %{to: "/service-not-found/#{type}", status: 302}}
    end
  end

  test "rejects ambiguous params instead of selecting either record" do
    assert {:halt, socket} =
             ServiceScope.on_mount(
               :default,
               %{"server_id" => "server-one", "netman_id" => "netman-one"},
               %{},
               socket()
             )

    refute Map.has_key?(socket.assigns, :selected_server)
    refute Map.has_key?(socket.assigns, :selected_netman)
    assert socket.assigns.service_scope_state == :not_found
    assert socket.redirected == {:redirect, %{to: "/service-not-found/service", status: 302}}
  end

  test "re-resolves the selected record on scoped parameter navigation" do
    assert {:ok, _first} = ManagementCore.register_server(%{id: "server-one", status: :online})
    assert {:ok, second} = ManagementCore.register_server(%{id: "server-two", status: :offline})

    assert {:cont, socket} =
             ServiceScope.on_mount(:default, %{"server_id" => "server-one"}, %{}, socket())

    assert {:cont, socket} =
             Phoenix.LiveView.Lifecycle.handle_params(
               %{"server_id" => "server-two"},
               "http://example.test/server/server-two/dashboard",
               socket
             )

    assert socket.assigns.selected_server == second
    refute socket.assigns.service_online?
  end

  defp socket do
    %Socket{
      router: YellowDog.Console.Router,
      private: %{
        lifecycle: Phoenix.LiveView.Lifecycle.build([]),
        live_temp: %{}
      }
    }
  end
end
