defmodule YellowDog.Management.ProfilesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, Idempotency, ProfileCatalog, Repo}
  alias YellowDog.ManagementUI.ManagementLive.ProfilesLive

  @endpoint YellowDog.ManagementUI.Endpoint

  @server_keys [:dns, :mdns, :dhcpv4, :dhcpv6, :netboot, :identity, :fingerprint, :server_agent]
  @netman_keys [:interfaces, :dhcp_client, :dns_client, :routes, :link_state, :vpn]

  @server_specs [
    {:cloud_dns, "Cloud DNS server", [:dns, :server_agent]},
    {:local_network, "Local network server", @server_keys},
    {:dns_only, "DNS-only server", [:dns, :server_agent]},
    {:dhcp_only, "DHCP-only server", [:dhcpv4, :dhcpv6, :server_agent]},
    {:netboot_only, "Netboot-only server", [:netboot, :server_agent]},
    {:custom, "Custom server", []}
  ]

  @netman_specs [
    {:local_server, "Local server network manager",
     [:interfaces, :dhcp_client, :dns_client, :routes, :link_state], :managed},
    {:cloud_server, "Cloud server network manager",
     [:interfaces, :dhcp_client, :dns_client, :routes, :link_state], :observe_first},
    {:bare_metal, "Bare-metal network manager",
     [:interfaces, :dhcp_client, :dns_client, :routes, :link_state], :managed},
    {:vm, "Virtual machine network manager", [:interfaces, :dns_client, :routes, :link_state],
     :managed},
    {:vpn_gateway, "Future VPN gateway network manager",
     [:interfaces, :routes, :dns_client, :link_state, :vpn], :managed},
    {:observe_only, "Observe-only network manager", [:interfaces, :link_state], :observe},
    {:custom, "Custom network manager", [], :managed}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "the pure server catalog preserves every original preset and all Boolean defaults" do
    assert Code.ensure_loaded?(ProfileCatalog)
    assert ProfileCatalog.server_service_keys() == @server_keys

    expected =
      Enum.map(@server_specs, fn {name, description, enabled} ->
        %{name: name, description: description, services: flags(@server_keys, enabled)}
      end)

    assert ProfileCatalog.list_server_profiles() == expected
  end

  test "the pure Netman catalog preserves every original preset, flags and apply mode" do
    assert Code.ensure_loaded?(ProfileCatalog)
    assert ProfileCatalog.netman_feature_keys() == @netman_keys

    expected =
      Enum.map(@netman_specs, fn {name, description, enabled, apply_mode} ->
        %{
          name: name,
          description: description,
          features: flags(@netman_keys, enabled),
          apply_mode: apply_mode
        }
      end)

    assert ProfileCatalog.list_netman_profiles() == expected
  end

  test "the page loads the original catalog tables with no Workers or login", %{conn: conn} do
    assert Code.ensure_loaded?(ProfilesLive)
    assert Domain.list_workers() == []
    {:ok, view, _html} = live(conn, "/management/profiles")
    assert has_element?(view, "h1", "Management Profiles")
    assert has_element?(view, "h2", "Server Profiles")
    assert has_element?(view, "h2", "Netman Profiles")

    for {{name, description, enabled}, row_number} <- Enum.with_index(@server_specs, 1) do
      row = "#management-server-profiles > tr:nth-child(#{row_number})"
      assert has_element?(view, "#{row} > td:nth-child(1)", to_string(name))
      assert has_element?(view, "#{row} > td:nth-child(2)", description)
      assert has_element?(view, "#{row} > td:nth-child(3)", defaults(enabled))
    end

    for {{name, description, enabled, apply_mode}, row_number} <-
          Enum.with_index(@netman_specs, 1) do
      row = "#management-netman-profiles > tr:nth-child(#{row_number})"
      assert has_element?(view, "#{row} > td:nth-child(1)", to_string(name))
      assert has_element?(view, "#{row} > td:nth-child(2)", description)
      assert has_element?(view, "#{row} > td:nth-child(3)", defaults(enabled))
      assert has_element?(view, "#{row} > td:nth-child(4)", to_string(apply_mode))
    end

    refute has_element?(view, "#management-server-profiles > tr:nth-child(7)")
    refute has_element?(view, "#management-netman-profiles > tr:nth-child(8)")
    refute has_element?(view, "input[type='password']")
  end

  test "catalog metadata is explicitly read-only and never starts agents or changes desired state",
       %{
         conn: conn
       } do
    assert Code.ensure_loaded?(ProfilesLive)

    before_read = {
      Domain.list_workers(),
      Repo.aggregate(Audit, :count),
      Repo.aggregate(Idempotency, :count)
    }

    {:ok, view, html} = live(conn, "/management/profiles")
    assert has_element?(view, "#management-profiles-help", "Read-only catalog metadata")
    assert html =~ "not actual Worker runtime support"
    assert html =~ "does not start agents or enable services"
    refute has_element?(view, "#management-profiles form")
    refute has_element?(view, "#management-profiles button")

    assert before_read == {
             Domain.list_workers(),
             Repo.aggregate(Audit, :count),
             Repo.aggregate(Idempotency, :count)
           }

    started_apps = Enum.map(Application.started_applications(), &elem(&1, 0))

    for legacy_app <- [
          :yellow_dog_console,
          :yellow_dog_management_core,
          :yellow_dog_server_agent,
          :yellow_dog_netman_agent
        ] do
      refute legacy_app in started_apps
    end
  end

  defp flags(keys, enabled), do: Map.new(keys, &{&1, &1 in enabled})

  defp defaults([]), do: "—"
  defp defaults(enabled), do: enabled |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")
end
