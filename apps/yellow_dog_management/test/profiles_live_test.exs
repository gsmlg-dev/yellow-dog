defmodule YellowDog.Management.ProfilesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, Idempotency, ProfileCatalog, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  @server_keys [:dns, :mdns, :dhcpv4, :dhcpv6, :netboot, :identity, :fingerprint, :server_agent]

  @server_specs [
    {:cloud_dns, "Cloud DNS server", [:dns, :server_agent]},
    {:local_network, "Local network server", @server_keys},
    {:dns_only, "DNS-only server", [:dns, :server_agent]},
    {:dhcp_only, "DHCP-only server", [:dhcpv4, :dhcpv6, :server_agent]},
    {:netboot_only, "Netboot-only server", [:netboot, :server_agent]},
    {:custom, "Custom server", []}
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

  test "the removed Profiles route returns 404 without changing durable state", %{conn: conn} do
    before_read = {
      Domain.list_workers(),
      Repo.aggregate(Audit, :count),
      Repo.aggregate(Idempotency, :count)
    }

    refute Enum.any?(Phoenix.Router.routes(YellowDog.ManagementUI.Router), fn route ->
             route.path == "/management/profiles"
           end)

    assert get(conn, "/management/profiles").status == 404

    assert before_read == {
             Domain.list_workers(),
             Repo.aggregate(Audit, :count),
             Repo.aggregate(Idempotency, :count)
           }
  end

  test "Management pages do not expose Profiles in sidebar navigation", %{conn: conn} do
    for path <- ["/management", "/management/servers", "/management/events"] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(
               view,
               "nav[aria-label='Main navigation'] a[href='/management']",
               "Monitoring"
             )

      refute has_element?(view, "a[href='/management/profiles']")
      refute has_element?(view, ".yd-sidebar a", "Profiles")
    end
  end

  defp flags(keys, enabled), do: Map.new(keys, &{&1, &1 in enabled})
end
