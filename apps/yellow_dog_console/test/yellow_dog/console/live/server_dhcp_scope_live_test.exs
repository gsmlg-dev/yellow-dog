defmodule YellowDog.Console.ServerDhcpScopeLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.Settings.AddressPool
  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)
  @observed_at "2026-08-11T03:04:05Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-server-dhcp-#{System.unique_integer([:positive])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    Application.put_env(
      :yellow_dog_management_core,
      :transport_module,
      TestManagementTransport
    )

    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    register_server("server-a", "Alpha Server", :online)
    register_server("server-b", "Beta Server", :online)
    :ok = TestManagementTransport.connect(:server, "server-a")
    :ok = TestManagementTransport.connect(:server, "server-b")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "every DHCPv4 and DHCPv6 route reads only the explicitly selected Server", %{conn: conn} do
    for family <- ["ipv4", "ipv6"], {server_id, prefix} <- server_prefixes() do
      version = family_version(family)

      {:ok, overview, _html} =
        mount_with(
          conn,
          "/server/#{server_id}/dhcp#{version}",
          overview_responses(family, prefix)
        )

      overview_html = render(overview)
      assert overview_html =~ server_name(prefix)
      assert overview_html =~ "#{prefix}-#{family}-pool"
      assert overview_html =~ "#{prefix}-#{family}-lease"
      assert overview_html =~ "#{prefix}-#{family}-activity"
      refute overview_html =~ "#{other_prefix(prefix)}-#{family}-pool"
      refute overview_html =~ "Offline cached snapshot"

      for suffix <- ["leases", "pools", "activity"] do
        assert has_element?(overview, "a[href='/server/#{server_id}/dhcp#{version}/#{suffix}']")
      end

      {:ok, leases, _html} =
        mount_with(conn, "/server/#{server_id}/dhcp#{version}/leases", [
          status(family),
          lease_list(family, prefix)
        ])

      assert render(leases) =~ "#{prefix}-#{family}-lease"
      assert has_element?(leases, "a[href='/server/#{server_id}/dhcp#{version}']")

      {:ok, pools, _html} =
        mount_with(conn, "/server/#{server_id}/dhcp#{version}/pools", [
          status(family),
          pool_list(family, prefix)
        ])

      assert render(pools) =~ "#{prefix}-#{family}-pool"

      assert has_element?(
               pools,
               "a[href='/server/#{server_id}/dhcp#{version}/pools/#{prefix}-#{family}-pool']"
             )

      {:ok, pool, _html} =
        mount_with(
          conn,
          "/server/#{server_id}/dhcp#{version}/pools/#{prefix}-#{family}-pool",
          [status(family), pool_list(family, prefix)]
        )

      assert render(pool) =~ subnet(family, prefix)
      assert has_element?(pool, "a[href='/server/#{server_id}/dhcp#{version}/pools']")
      refute has_element?(pool, "button[phx-click='release_lease']")

      {:ok, activity, _html} =
        mount_with(conn, "/server/#{server_id}/dhcp#{version}/activity", [
          status(family),
          activity_list(family, prefix)
        ])

      assert render(activity) =~ "#{prefix}-#{family}-activity"
      assert has_element?(activity, "a[href='/server/#{server_id}/dhcp#{version}']")
    end

    assert Enum.all?(request_envelopes(), fn envelope ->
             envelope.target_id in ["server-a", "server-b"]
           end)

    assert Enum.all?(request_envelopes(), fn envelope ->
             envelope.operation in [
               "server.dhcp.status.get",
               "server.dhcp.pools.list",
               "server.dhcp.leases.list",
               "server.dhcp.activity.list"
             ]
           end)
  end

  test "pool commands use exact resource digests and UUID idempotency for both families", %{
    conn: conn
  } do
    for family <- ["ipv4", "ipv6"] do
      version = family_version(family)
      original = pool(family, "alpha")
      created = pool(family, "created")
      updated = %{original | "lease_seconds" => 7_200}

      {:ok, live_view, _html} =
        mount_with(conn, "/server/server-a/dhcp#{version}/pools", [
          status(family),
          {:ok, list_result([original])}
        ])

      assert render_click(live_view, "show_new_form") =~
               "Server management stores subnet, range, and one lease duration"

      refute has_element?(live_view, "input[name='address_pool[gateway]']")
      refute has_element?(live_view, "input[name='address_pool[dns_servers_str]']")
      assert has_element?(live_view, "input[name='address_pool[network]'][required]")
      send(live_view.pid, :close_pool_form)
      render(live_view)

      before = length(request_envelopes())

      :ok = TestManagementTransport.script_request([{:ok, revisioned(created)}])
      send(live_view.pid, {:pool_saved, family_service(family), form_pool(created), :create})
      assert render(live_view) =~ "Pool created successfully"

      :ok = TestManagementTransport.script_request([{:ok, revisioned(updated)}])
      send(live_view.pid, {:pool_saved, family_service(family), form_pool(updated), :edit})
      assert render(live_view) =~ "Pool updated successfully"

      :ok = TestManagementTransport.script_request([{:ok, deleted(created, true)}])

      assert render_click(live_view, "force_delete_pool", %{
               "pool-name" => created["pool_id"]
             }) =~ "force deleted successfully"

      :ok = TestManagementTransport.script_request([{:ok, deleted(updated, false)}])

      assert render_click(live_view, "delete_pool", %{
               "pool-name" => updated["pool_id"]
             }) =~ "deleted successfully"

      commands = Enum.drop(request_envelopes(), before)

      assert Enum.map(commands, & &1.operation) == [
               "server.dhcp.pools.create",
               "server.dhcp.pools.update",
               "server.dhcp.pools.force_delete",
               "server.dhcp.pools.delete"
             ]

      assert Enum.map(commands, & &1.expected_revision) == [
               nil,
               digest!(original),
               digest!(created),
               digest!(updated)
             ]

      assert Enum.all?(commands, fn envelope ->
               envelope.target_id == "server-a" and
                 match?({:ok, _uuid}, Ecto.UUID.cast(envelope.idempotency_key))
             end)

      assert commands
             |> Enum.map(& &1.idempotency_key)
             |> Enum.uniq()
             |> length() == 4

      request_count = length(request_envelopes())

      assert render_click(live_view, "delete_pool", %{"pool-name" => "missing"}) =~
               "revision is unavailable"

      assert length(request_envelopes()) == request_count
    end
  end

  test "lease release uses the exact listed lease digest for both families", %{conn: conn} do
    for family <- ["ipv4", "ipv6"] do
      version = family_version(family)
      lease = lease(family, "alpha")

      {:ok, live_view, _html} =
        mount_with(conn, "/server/server-a/dhcp#{version}/leases", [
          status(family),
          {:ok, list_result([lease])}
        ])

      before = length(request_envelopes())
      :ok = TestManagementTransport.script_request([{:ok, released(lease)}])

      assert render_click(live_view, "release_lease", %{"lease-id" => lease["lease_id"]}) =~
               "Lease released successfully"

      assert [command] = Enum.drop(request_envelopes(), before)
      assert command.operation == "server.dhcp.leases.release"
      assert command.target_id == "server-a"
      assert command.payload == %{"family" => family, "lease_id" => lease["lease_id"]}
      assert command.expected_revision == digest!(lease)
      assert {:ok, _uuid} = Ecto.UUID.cast(command.idempotency_key)

      request_count = length(request_envelopes())

      assert render_click(live_view, "release_lease", %{"lease-id" => lease["lease_id"]}) =~
               "revision is unavailable"

      assert render_click(live_view, "release_lease", %{"lease-id" => "missing"}) =~
               "revision is unavailable"

      assert length(request_envelopes()) == request_count
    end
  end

  test "offline snapshots stay family-scoped and mutations make no request", %{conn: conn} do
    :ok =
      TestManagementTransport.script_request([
        status("ipv4"),
        pool_list("ipv4", "alpha"),
        status("ipv6"),
        pool_list("ipv6", "beta")
      ])

    assert %{status: :ok} = ServerManagement.dhcp_status_get("server-a", %{"family" => "ipv4"})
    assert %{status: :ok} = ServerManagement.dhcp_pools_list("server-a", %{"family" => "ipv4"})
    assert %{status: :ok} = ServerManagement.dhcp_status_get("server-a", %{"family" => "ipv6"})
    assert %{status: :ok} = ServerManagement.dhcp_pools_list("server-a", %{"family" => "ipv6"})

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    before = length(request_envelopes())

    {:ok, ipv4, _html} = live(conn, "/server/server-a/dhcpv4/pools")
    ipv4_html = render(ipv4)
    assert ipv4_html =~ "Offline cached snapshot"
    assert ipv4_html =~ "alpha-ipv4-pool"
    refute ipv4_html =~ "beta-ipv6-pool"
    assert has_element?(ipv4, "button[phx-click='delete_pool'][disabled]")

    assert render_click(ipv4, "delete_pool", %{"pool-name" => "alpha-ipv4-pool"}) =~
             "offline"

    {:ok, ipv6, _html} = live(conn, "/server/server-a/dhcpv6/pools")
    ipv6_html = render(ipv6)
    assert ipv6_html =~ "Offline cached snapshot"
    assert ipv6_html =~ "beta-ipv6-pool"
    refute ipv6_html =~ "alpha-ipv4-pool"
    assert has_element?(ipv6, "button[phx-click='delete_pool'][disabled]")

    assert render_click(ipv6, "delete_pool", %{"pool-name" => "beta-ipv6-pool"}) =~
             "offline"

    assert length(request_envelopes()) == before
  end

  defp mount_with(conn, path, responses) do
    :ok = TestManagementTransport.script_request(responses)
    live(conn, path)
  end

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: id,
               name: name,
               profile: :custom,
               status: status,
               last_seen_at: ~U[2026-08-11 03:04:05Z]
             })
  end

  defp overview_responses(family, prefix),
    do: [
      status(family),
      pool_list(family, prefix),
      lease_list(family, prefix),
      activity_list(family, prefix)
    ]

  defp status(family), do: {:ok, %{"family" => family, "status" => "running"}}
  defp pool_list(family, prefix), do: {:ok, list_result([pool(family, prefix)])}
  defp lease_list(family, prefix), do: {:ok, list_result([lease(family, prefix)])}
  defp activity_list(family, prefix), do: {:ok, list_result([activity(family, prefix)])}

  defp pool(family, prefix) do
    %{
      "family" => family,
      "pool_id" => "#{prefix}-#{family}-pool",
      "subnet" => subnet(family, prefix),
      "start_address" => start_address(family, prefix),
      "end_address" => end_address(family, prefix),
      "lease_seconds" => 3_600
    }
  end

  defp lease(family, prefix) do
    %{
      "family" => family,
      "lease_id" => "#{prefix}-#{family}-lease",
      "address" => start_address(family, prefix),
      "state" => "active"
    }
  end

  defp activity(family, prefix) do
    %{
      "activity_id" => "#{prefix}-#{family}-activity",
      "family" => family,
      "action" => "lease_granted",
      "occurred_at" => @observed_at
    }
  end

  defp form_pool(resource) do
    family = resource["family"]
    lease_seconds = resource["lease_seconds"]

    %AddressPool{
      id: resource["pool_id"],
      name: resource["pool_id"],
      protocol: if(family == "ipv4", do: :ipv4, else: :ipv6),
      network: resource["subnet"],
      range_start: resource["start_address"],
      range_end: resource["end_address"],
      lease_time: lease_seconds,
      preferred_lifetime: lease_seconds,
      valid_lifetime: lease_seconds
    }
  end

  defp revisioned(resource) do
    %{
      "resource_type" => "dhcp_pool",
      "resource_id" => resource["pool_id"],
      "resource" => resource,
      "revision" => @revision_b
    }
  end

  defp deleted(resource, _force) do
    %{
      "resource_type" => "dhcp_pool",
      "resource_id" => resource["pool_id"],
      "resource_ref" => %{
        "family" => resource["family"],
        "pool_id" => resource["pool_id"]
      },
      "revision" => @revision_b
    }
  end

  defp released(lease) do
    %{
      "family" => lease["family"],
      "lease_id" => lease["lease_id"],
      "address" => lease["address"],
      "released" => true
    }
  end

  defp list_result(items),
    do: %{"items" => items, "revision" => @revision_a, "observed_at" => @observed_at}

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp digest!(resource) do
    assert {:ok, revision} = Digest.calculate(resource)
    revision
  end

  defp server_prefixes, do: [{"server-a", "alpha"}, {"server-b", "beta"}]
  defp server_name("alpha"), do: "Alpha Server"
  defp server_name("beta"), do: "Beta Server"
  defp other_prefix("alpha"), do: "beta"
  defp other_prefix("beta"), do: "alpha"
  defp family_version("ipv4"), do: "v4"
  defp family_version("ipv6"), do: "v6"
  defp family_service("ipv4"), do: :dhcpv4
  defp family_service("ipv6"), do: :dhcpv6

  defp subnet("ipv4", "alpha"), do: "192.0.2.0/24"
  defp subnet("ipv4", "beta"), do: "198.51.100.0/24"
  defp subnet("ipv4", "created"), do: "203.0.113.0/24"
  defp subnet("ipv6", "alpha"), do: "2001:db8:1::/64"
  defp subnet("ipv6", "beta"), do: "2001:db8:2::/64"
  defp subnet("ipv6", "created"), do: "2001:db8:3::/64"

  defp start_address("ipv4", "alpha"), do: "192.0.2.10"
  defp start_address("ipv4", "beta"), do: "198.51.100.10"
  defp start_address("ipv4", "created"), do: "203.0.113.10"
  defp start_address("ipv6", "alpha"), do: "2001:db8:1::10"
  defp start_address("ipv6", "beta"), do: "2001:db8:2::10"
  defp start_address("ipv6", "created"), do: "2001:db8:3::10"

  defp end_address("ipv4", "alpha"), do: "192.0.2.99"
  defp end_address("ipv4", "beta"), do: "198.51.100.99"
  defp end_address("ipv4", "created"), do: "203.0.113.99"
  defp end_address("ipv6", "alpha"), do: "2001:db8:1::99"
  defp end_address("ipv6", "beta"), do: "2001:db8:2::99"
  defp end_address("ipv6", "created"), do: "2001:db8:3::99"

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
