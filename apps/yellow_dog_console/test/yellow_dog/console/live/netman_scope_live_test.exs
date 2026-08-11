defmodule YellowDog.Console.NetmanScopeLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Message.ConfigState

  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)
  @revision_c String.duplicate("c", 64)
  @observed_at "2026-08-11T01:02:03Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-netman-live-#{System.unique_integer([:positive])}"
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

    register_netman("netman-a", "Alpha Netman", :observe_first, :online)
    register_netman("netman-b", "Beta Netman", :managed, :online)
    :ok = TestManagementTransport.connect(:netman, "netman-a")
    :ok = TestManagementTransport.connect(:netman, "netman-b")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "overview reads only the selected Netman and keeps every link scoped", %{conn: conn} do
    :ok = TestManagementTransport.script_request(overview_responses("alpha", "observe_first"))

    {:ok, view, _html} = live(conn, "/netman/netman-a")
    html = view |> element("#netman-overview") |> render()

    assert html =~ "Alpha Netman"
    assert html =~ "alpha-profile"
    assert html =~ "alpha0"
    assert html =~ "192.0.2.1"
    assert html =~ "observe first"
    assert html =~ "vpn gateway"
    assert html =~ "resolved"
    refute html =~ "Beta Netman"
    refute has_element?(view, "[data-vpn-action]")

    for destination <- ["config", "interfaces", "resolved", "dhcp-client"] do
      assert has_element?(view, "a[href='/netman/netman-a/#{destination}']")
    end

    assert Enum.all?(request_envelopes(), &(&1.target_id == "netman-a"))

    assert Enum.map(request_envelopes(), & &1.operation) == [
             "netman.runtime.capabilities.get",
             "netman.runtime.apply_mode.get",
             "netman.runtime.reconciliation_health.get",
             "netman.profiles.list",
             "netman.network.links.list",
             "netman.network.routes.list",
             "netman.vpn.profile.get"
           ]
  end

  test "two records render distinct selected runtime state", %{conn: conn} do
    :ok = TestManagementTransport.script_request(overview_responses("alpha", "observe_first"))
    {:ok, alpha, _html} = live(conn, "/netman/netman-a")
    alpha_html = alpha |> element("#netman-overview") |> render()

    :ok = TestManagementTransport.script_request(overview_responses("beta", "managed"))
    {:ok, beta, _html} = live(conn, "/netman/netman-b")
    beta_html = beta |> element("#netman-overview") |> render()

    assert alpha_html =~ "alpha-profile"
    assert alpha_html =~ "alpha0"
    refute alpha_html =~ "beta-profile"

    assert beta_html =~ "beta-profile"
    assert beta_html =~ "beta0"
    refute beta_html =~ "alpha-profile"

    assert Enum.map(request_envelopes(), & &1.target_id) ==
             List.duplicate("netman-a", 7) ++ List.duplicate("netman-b", 7)
  end

  test "two records isolate Resolved and DHCP snapshots while online status differs", %{
    conn: conn
  } do
    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        upstreams("beta"),
        search_domains("beta"),
        resolved_cache("beta"),
        {:ok, %{"hits" => 11, "misses" => 4}},
        {:ok, list_result([lease("beta")])}
      ])

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-b")

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.resolved_upstreams_list("netman-b")

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.resolved_search_domains_list("netman-b")

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.resolved_cache_get("netman-b")

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.resolved_counters_get("netman-b")

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.dhcp_client_leases_list("netman-b")

    :ok = TestManagementTransport.disconnect(:netman, "netman-b")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-b", :offline)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe_first"),
        upstreams("alpha"),
        search_domains("alpha"),
        resolved_cache("alpha"),
        {:ok, %{"hits" => 7, "misses" => 2}}
      ])

    {:ok, alpha_resolved, _html} = live(conn, "/netman/netman-a/resolved")
    alpha_resolved_html = render(alpha_resolved)
    assert alpha_resolved_html =~ "Connected"
    assert alpha_resolved_html =~ "192.0.2.53"
    assert alpha_resolved_html =~ "cached.alpha.example"
    refute alpha_resolved_html =~ "198.51.100.53"

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe_first"),
        {:ok, list_result([lease("alpha")])}
      ])

    {:ok, alpha_dhcp, _html} = live(conn, "/netman/netman-a/dhcp-client")
    alpha_dhcp_html = render(alpha_dhcp)
    assert alpha_dhcp_html =~ "alpha-profile"
    assert alpha_dhcp_html =~ "192.0.2.20"
    refute alpha_dhcp_html =~ "beta-profile"

    {:ok, beta_resolved, _html} = live(conn, "/netman/netman-b/resolved")
    beta_resolved_html = render(beta_resolved)
    assert beta_resolved_html =~ "Offline"
    assert beta_resolved_html =~ "198.51.100.53"
    assert beta_resolved_html =~ "cached.beta.example"
    refute beta_resolved_html =~ "192.0.2.53"

    {:ok, beta_dhcp, _html} = live(conn, "/netman/netman-b/dhcp-client")
    beta_dhcp_html = render(beta_dhcp)
    assert beta_dhcp_html =~ "beta-profile"
    assert beta_dhcp_html =~ "198.51.100.20"
    refute beta_dhcp_html =~ "alpha-profile"
  end

  test "configuration keeps runtime profile operations typed and shows observe-first policy", %{
    conn: conn
  } do
    profile = wire_profile("alpha-profile", "alpha0")
    seed_applied_profile_config("netman-a", profile, @revision_a)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe_first"),
        profile_list(profile),
        {:ok, %{"profile_id" => "alpha-profile", "valid" => true, "errors" => []}},
        {:ok, activation("alpha-profile", "activated")},
        {:ok, activation("alpha-profile", "activated")},
        {:ok, profile_history(profile)},
        {:ok,
         %{
           "profile_id" => "alpha-profile",
           "desired_revision" => @revision_a,
           "active_revision" => @revision_a
         }}
      ])

    :ok = TestManagementTransport.script_config([:ok])

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")
    html = render(view)

    assert html =~ "observe first"
    assert html =~ "Policy approval is required"
    assert html =~ "alpha-profile"
    refute html =~ "/etc/yellowdog"
    refute html =~ "Save this file"

    for form <- ["profile", "patch", "rollback"] do
      refute has_element?(view, "input[name='#{form}[expected_revision]']")
    end

    form = Map.put(profile_form("alpha-profile", "alpha0"), "expected_revision", @revision_c)
    validate_html = render_submit(view, "validate_profile", %{"profile" => form})
    assert validate_html =~ "Profile is valid"

    assert render_click(view, "activate_profile", %{
             "profile_id" => "alpha-profile",
             "expected_revision" => @revision_a
           }) =~ "Profile activated"

    assert render_submit(view, "rollback_profile", %{
             "rollback" => %{
               "profile_id" => "alpha-profile",
               "target_revision" => @revision_a,
               "expected_revision" => "tampered"
             }
           }) =~ "Profile rolled back"

    assert render_click(view, "load_history", %{"profile_id" => "alpha-profile"}) =~
             "Revision history"

    assert render_click(view, "load_active_revision", %{"profile_id" => "alpha-profile"}) =~
             "Active revision"

    assert render_click(view, "replace_profiles") =~ "Desired profile set published"

    operations = Enum.map(request_envelopes(), & &1.operation)

    assert Enum.all?(request_envelopes(), &(&1.target_id == "netman-a"))

    assert operations == [
             "netman.runtime.apply_mode.get",
             "netman.profiles.list",
             "netman.profiles.validate",
             "netman.profiles.activate",
             "netman.profiles.rollback",
             "netman.profiles.history.list",
             "netman.profiles.active_revision.get"
           ]

    revisions_by_operation =
      Map.new(request_envelopes(), &{&1.operation, &1.expected_revision})

    assert revisions_by_operation["netman.profiles.activate"] == @revision_a
    assert revisions_by_operation["netman.profiles.rollback"] == @revision_a

    assert [{:config, config_envelope}] = config_envelopes()
    assert config_envelope.target_id == "netman-a"
    assert config_envelope.operation == "netman.profiles.replace"
    assert config_envelope.expected_revision == @revision_a
  end

  test "profile save uses the Management collection revision and not a browser revision", %{
    conn: conn
  } do
    existing = wire_profile("alpha-profile", "alpha0")
    created = wire_profile("new-profile", "new0")
    seed_applied_profile_config("netman-a", existing, @revision_a)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        profile_list(existing)
      ])

    :ok = TestManagementTransport.script_config([:ok])

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")

    form =
      "new-profile"
      |> profile_form("new0")
      |> Map.put("expected_revision", @revision_c)

    assert render_submit(view, "put_profile", %{"profile" => form}) =~ "Profile saved"

    refute Enum.any?(request_envelopes(), &(&1.operation == "netman.profiles.put"))

    assert [{:config, envelope}] = config_envelopes()
    assert envelope.operation == "netman.profiles.replace"
    assert envelope.expected_revision == @revision_a

    assert Map.new(envelope.payload["profiles"], &{&1["profile_id"], &1}) == %{
             "alpha-profile" => existing,
             "new-profile" => created
           }
  end

  test "stale profile actions do not call management", %{conn: conn} do
    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        profile_list(wire_profile("alpha-profile", "alpha0"))
      ])

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")
    before = length(TestManagementTransport.recorded())

    html =
      render_submit(view, "patch_profile", %{
        "patch" => %{
          "profile_id" => "stale-profile",
          "field" => "zone",
          "value" => "guest",
          "expected_revision" => @revision_c
        }
      })

    assert html =~ "selected profile is unavailable"
    assert length(TestManagementTransport.recorded()) == before
  end

  test "conflicts are visible and observe mode blocks profile commands", %{conn: conn} do
    assert {:ok, _netman} =
             ManagementCore.register_netman(%{
               id: "netman-observe",
               name: "Observer",
               profile: :custom,
               apply_mode: :observe,
               status: :online
             })

    :ok = TestManagementTransport.connect(:netman, "netman-observe")

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe"),
        profile_list(wire_profile("observer", "obs0"))
      ])

    {:ok, observe_view, _html} = live(conn, "/netman/netman-observe/config")
    observe_html = render(observe_view)
    assert observe_html =~ "Observe mode is read-only"
    assert has_element?(observe_view, "button[phx-click='replace_profiles'][disabled]")

    before = length(TestManagementTransport.recorded())

    assert render_click(observe_view, "delete_profile", %{"profile_id" => "observer"}) =~
             "read-only"

    assert length(TestManagementTransport.recorded()) == before

    profile = wire_profile("alpha-profile", "alpha0")
    :ok = TestManagementTransport.disconnect(:netman, "netman-a")

    assert {:ok, _desired} =
             ManagementCore.publish_netman_config("netman-a", %{
               operation: "netman.profiles.replace",
               payload: %{"profiles" => [profile]},
               expected_revision: nil
             })

    :ok = TestManagementTransport.connect(:netman, "netman-a")

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe_first"),
        profile_list(profile)
      ])

    {:ok, conflict_view, _html} = live(conn, "/netman/netman-a/config")
    refute has_element?(conflict_view, "button[phx-click='replace_profiles'][disabled]")

    html =
      render_click(conflict_view, "delete_profile", %{
        "profile_id" => "alpha-profile",
        "expected_revision" => @revision_a
      })

    assert html =~ "config deployment already in flight"
    refute Enum.any?(request_envelopes(), &(&1.operation == "netman.profiles.delete"))
  end

  test "interfaces combine typed links, addresses and routes and target connection actions", %{
    conn: conn
  } do
    profile = wire_profile("alpha-profile", "alpha0")

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        links("alpha"),
        addresses("alpha"),
        routes("alpha"),
        profile_list(profile),
        {:ok,
         %{"profile_id" => "alpha-profile", "interface" => "alpha0", "state" => "activated"}},
        {:ok,
         %{"profile_id" => "alpha-profile", "interface" => "alpha0", "state" => "activated"}},
        {:ok,
         %{
           "profile_id" => "alpha-profile",
           "interface" => "alpha0",
           "state" => "deactivated"
         }}
      ])

    {:ok, view, _html} = live(conn, "/netman/netman-a/interfaces")
    html = render(view)

    assert html =~ "alpha0"
    assert html =~ "192.0.2.10/24"
    assert html =~ "192.0.2.1"
    assert has_element?(view, "a[href='/netman/netman-a']")

    ref = %{"profile_id" => "alpha-profile", "interface" => "alpha0"}
    assert render_click(view, "connection_state", ref) =~ "activated"
    assert render_click(view, "activate_connection", ref) =~ "Connection activated"
    assert render_click(view, "deactivate_connection", ref) =~ "Connection deactivated"

    assert Enum.all?(request_envelopes(), &(&1.target_id == "netman-a"))

    assert Enum.map(request_envelopes(), & &1.operation) == [
             "netman.runtime.apply_mode.get",
             "netman.network.links.list",
             "netman.network.addresses.list",
             "netman.network.routes.list",
             "netman.profiles.list",
             "netman.network.connection_state.get",
             "netman.connections.activate",
             "netman.connections.deactivate"
           ]
  end

  test "Resolved reads and every mutation stay selected and typed", %{conn: conn} do
    seed_applied_resolved_config("netman-a", @revision_b)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        upstreams("alpha"),
        search_domains("alpha"),
        resolved_cache("alpha"),
        {:ok, %{"hits" => 7, "misses" => 2}},
        {:ok, %{"cleared_entries" => 3}}
      ])

    :ok = TestManagementTransport.script_config([:ok])

    {:ok, view, _html} = live(conn, "/netman/netman-a/resolved")
    html = render(view)

    assert html =~ "192.0.2.53"
    assert html =~ "alpha.example"
    assert html =~ "cached.alpha.example"
    assert html =~ "7"

    update_html =
      render_submit(view, "update_resolved", %{
        "resolved" => %{
          "upstreams" => "203.0.113.53",
          "search_domains" => "new.alpha.example"
        }
      })

    assert update_html =~ "Desired Resolved configuration published"

    assert render_submit(view, "rollback_resolved", %{
             "rollback" => %{
               "target_revision" => @revision_a
             }
           }) =~ "config deployment already in flight"

    assert render_click(view, "flush_cache", %{"expected_revision" => @revision_a}) =~
             "Flushed 3 cache entries"

    assert Enum.all?(request_envelopes(), &(&1.target_id == "netman-a"))

    assert Enum.map(request_envelopes(), & &1.operation) == [
             "netman.runtime.apply_mode.get",
             "netman.resolved.upstreams.list",
             "netman.resolved.search_domains.list",
             "netman.resolved.cache.get",
             "netman.resolved.counters.get",
             "netman.resolved.cache.flush"
           ]

    assert Enum.map(config_envelopes(), fn {:config, envelope} -> envelope.operation end) == [
             "netman.resolved.config.update"
           ]

    assert Enum.all?(config_envelopes(), fn {:config, envelope} ->
             envelope.target_id == "netman-a" and envelope.expected_revision == @revision_b
           end)

    assert Enum.find(request_envelopes(), &(&1.operation == "netman.resolved.cache.flush"))
           |> Map.fetch!(:expected_revision) == @revision_c
  end

  test "DHCP renders lease/FSM state and releases only the selected connection", %{conn: conn} do
    lease = lease("alpha")

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        {:ok, list_result([lease])},
        {:ok, %{"profile_id" => "alpha-profile", "interface" => "alpha0", "state" => "bound"}},
        {:ok,
         %{
           "family" => "ipv4",
           "lease_id" => "alpha-profile.alpha0",
           "address" => "192.0.2.20",
           "released" => true
         }}
      ])

    {:ok, view, _html} = live(conn, "/netman/netman-a/dhcp-client")
    html = render(view)

    assert html =~ "alpha-profile"
    assert html =~ "alpha0"
    assert html =~ "192.0.2.20"

    assert has_element?(
             view,
             "button[phx-click='release_lease'][phx-value-expected_revision='#{@revision_b}']"
           )

    assert render_click(view, "inspect_fsm", %{
             "profile_id" => "alpha-profile",
             "interface" => "alpha0"
           }) =~ "bound"

    assert render_click(view, "release_lease", %{
             "profile_id" => "alpha-profile",
             "interface" => "alpha0",
             "expected_revision" => @revision_b
           }) =~ "Lease released"

    assert Enum.all?(request_envelopes(), &(&1.target_id == "netman-a"))

    assert Enum.map(request_envelopes(), & &1.operation) == [
             "netman.runtime.apply_mode.get",
             "netman.dhcp_client.leases.list",
             "netman.dhcp_client.fsm.get",
             "netman.dhcp_client.connections.release_lease"
           ]

    assert List.last(request_envelopes()).expected_revision == @revision_b
  end

  test "mutation events make no call when their exact owner revision is unavailable", %{
    conn: conn
  } do
    seed_desired_resolved_config("netman-a")

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        {:ok, Map.delete(elem(upstreams("alpha"), 1), "config_revision")},
        search_domains("alpha"),
        {:ok, Map.delete(elem(resolved_cache("alpha"), 1), "revision")},
        {:ok, %{"hits" => 7, "misses" => 2}}
      ])

    {:ok, resolved, _html} = live(conn, "/netman/netman-a/resolved")
    assert has_element?(resolved, "#resolved-config-form button[disabled]")
    assert has_element?(resolved, "#resolved-rollback-form button[disabled]")
    assert has_element?(resolved, "button[phx-click='flush_cache'][disabled]")
    before_resolved = length(TestManagementTransport.recorded())

    assert render_submit(resolved, "update_resolved", %{
             "resolved" => %{"upstreams" => "1.1.1.1", "search_domains" => "example.test"}
           }) =~ "exact configuration revision is unavailable"

    assert render_submit(resolved, "rollback_resolved", %{
             "rollback" => %{"target_revision" => @revision_a}
           }) =~ "exact configuration revision is unavailable"

    assert render_click(resolved, "flush_cache", %{}) =~
             "exact cache revision is unavailable"

    assert length(TestManagementTransport.recorded()) == before_resolved

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        {:ok, list_result([Map.delete(lease("alpha"), "revision")])}
      ])

    {:ok, dhcp, _html} = live(conn, "/netman/netman-a/dhcp-client")
    before_dhcp = length(TestManagementTransport.recorded())

    assert render_click(dhcp, "release_lease", %{
             "profile_id" => "alpha-profile",
             "interface" => "alpha0"
           }) =~ "exact lease revision is unavailable"

    assert length(TestManagementTransport.recorded()) == before_dhcp
  end

  test "offline profile create publishes the complete desired set without a runtime command", %{
    conn: conn
  } do
    existing = wire_profile("cached-profile", "cache0")
    created = wire_profile("new-profile", "new0")
    seed_applied_profile_config("netman-a", existing, @revision_a)
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(existing)])

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-a")

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.profiles_list("netman-a")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")

    refute has_element?(view, "#netman-profile-form button.btn-primary[disabled]")
    assert has_element?(view, "#netman-profile-form button.btn-ghost[disabled]")

    form = Map.put(profile_form("new-profile", "new0"), "expected_revision", @revision_c)
    assert render_submit(view, "put_profile", %{"profile" => form}) =~ "Profile saved"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.version == 2
    assert desired.operation == "netman.profiles.replace"
    assert desired.expected_revision == @revision_a

    assert Map.new(desired.payload["profiles"], &{&1["profile_id"], &1}) == %{
             "cached-profile" => existing,
             "new-profile" => created
           }

    assert length(TestManagementTransport.recorded()) == before
  end

  test "profile editing reloads the Management-owned set instead of a stale runtime snapshot", %{
    conn: conn
  } do
    managed = wire_profile("managed-profile", "managed0")
    stale = wire_profile("stale-profile", "stale0")
    created = wire_profile("new-profile", "new0")
    seed_applied_profile_config("netman-a", managed, @revision_a)
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(stale)])

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-a")

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.profiles_list("netman-a")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, html} = live(conn, "/netman/netman-a/config")

    assert html =~ "managed-profile"
    refute html =~ "stale-profile"

    assert render_submit(view, "put_profile", %{
             "profile" => profile_form("new-profile", "new0")
           }) =~ "Profile saved"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")

    assert Map.new(desired.payload["profiles"], &{&1["profile_id"], &1}) == %{
             "managed-profile" => managed,
             "new-profile" => created
           }

    assert length(TestManagementTransport.recorded()) == before
  end

  test "offline profile bootstrap starts blank and publishes without a runtime revision", %{
    conn: conn
  } do
    created = wire_profile("bootstrap-profile", "bootstrap0")
    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, html} = live(conn, "/netman/netman-a/config")

    assert html =~ "No Management-owned profiles"
    refute has_element?(view, "#managed-netman-profiles")
    refute has_element?(view, "button[phx-click='replace_profiles'][disabled]")
    refute has_element?(view, "#netman-profile-form button.btn-primary[disabled]")

    assert render_submit(view, "put_profile", %{
             "profile" => profile_form("bootstrap-profile", "bootstrap0")
           }) =~ "Profile saved"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.expected_revision == nil
    assert desired.payload == %{"profiles" => [created]}
    assert length(TestManagementTransport.recorded()) == before
  end

  test "profile editing fails closed when the Management-owned set cannot be read", %{
    conn: conn,
    data_dir: data_dir
  } do
    managed = wire_profile("managed-profile", "managed0")
    runtime = wire_profile("runtime-profile", "runtime0")
    seed_applied_profile_config("netman-a", managed, @revision_a)
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(runtime)])

    :ok = corrupt_netman_manifest(data_dir, "netman-a")
    {:ok, view, _html} = live(conn, "/netman/netman-a/config")

    assert has_element?(view, "button[phx-click='replace_profiles'][disabled]")
    assert has_element?(view, "#netman-profile-form button.btn-primary[disabled]")
    refute render(view) =~ "runtime-profile"

    assert render_submit(view, "put_profile", %{
             "profile" => profile_form("new-profile", "new0")
           }) =~ "Management-owned profile configuration is unavailable"

    assert config_envelopes() == []
  end

  test "offline profile patch publishes the complete desired set without a runtime command", %{
    conn: conn
  } do
    profile = wire_profile("cached-profile", "cache0")
    seed_applied_profile_config("netman-a", profile, @revision_a)
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(profile)])

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-a")

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.profiles_list("netman-a")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")
    refute has_element?(view, "#netman-profile-patch button[disabled]")

    assert render_submit(view, "patch_profile", %{
             "patch" => %{
               "profile_id" => "cached-profile",
               "field" => "zone",
               "value" => "guest"
             }
           }) =~ "Profile patched"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.version == 2
    assert desired.operation == "netman.profiles.replace"
    assert desired.expected_revision == @revision_a
    assert [updated] = desired.payload["profiles"]
    assert updated == put_in(profile, ["zone"], "guest")
    assert length(TestManagementTransport.recorded()) == before
  end

  test "offline profile delete publishes the complete desired set while runtime actions stay disabled",
       %{
         conn: conn
       } do
    profile = wire_profile("cached-profile", "cache0")
    seed_applied_profile_config("netman-a", profile, @revision_a)
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(profile)])

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-a")

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.profiles_list("netman-a")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/config")
    html = render(view)

    assert html =~ "Offline cached snapshot"
    assert html =~ "Observed"
    assert html =~ "cached-profile"
    refute has_element?(view, "button[phx-click='replace_profiles'][disabled]")
    refute has_element?(view, "button[phx-click='delete_profile'][disabled]")
    assert has_element?(view, "button[phx-click='activate_profile'][disabled]")
    assert has_element?(view, "button[phx-click='load_history'][disabled]")
    assert has_element?(view, "button[phx-click='load_active_revision'][disabled]")
    assert has_element?(view, "#netman-profile-rollback button[disabled]")

    assert render_click(view, "delete_profile", %{"profile_id" => "cached-profile"}) =~
             "Profile deleted"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.version == 2
    assert desired.operation == "netman.profiles.replace"
    assert desired.expected_revision == @revision_a
    assert desired.payload == %{"profiles" => []}

    assert render_click(view, "activate_profile", %{"profile_id" => "cached-profile"}) =~
             "offline"

    assert render_click(view, "load_history", %{"profile_id" => "cached-profile"}) =~
             "runtime queries are disabled"

    assert render_click(view, "load_active_revision", %{"profile_id" => "cached-profile"}) =~
             "runtime queries are disabled"

    assert length(TestManagementTransport.recorded()) == before
  end

  test "offline Resolved updates remain durable while cache flush stays disabled", %{conn: conn} do
    seed_applied_resolved_config("netman-a", @revision_b)
    cache_resolved_snapshots("netman-a", "alpha")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/resolved")

    refute has_element?(view, "#resolved-config-form button[disabled]")
    refute has_element?(view, "#resolved-rollback-form button[disabled]")
    assert has_element?(view, "button[phx-click='flush_cache'][disabled]")

    assert render_submit(view, "update_resolved", %{
             "resolved" => %{
               "upstreams" => "203.0.113.53",
               "search_domains" => "offline.example"
             }
           }) =~ "Desired Resolved configuration published"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.operation == "netman.resolved.config.update"
    assert length(TestManagementTransport.recorded()) == before
  end

  test "offline Resolved editing uses durable desired values instead of stale runtime snapshots",
       %{
         conn: conn
       } do
    seed_applied_resolved_config("netman-a", @revision_b)
    cache_resolved_snapshots("netman-a", "stale", @revision_c)

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, html} = live(conn, "/netman/netman-a/resolved")

    assert html =~ "198.51.100.53"
    assert html =~ "stale.example"

    assert has_element?(
             view,
             "#resolved-config-form input[name='resolved[upstreams]'][value='192.0.2.53']"
           )

    assert has_element?(
             view,
             "#resolved-config-form input[name='resolved[search_domains]'][value='alpha.example']"
           )

    assert render_submit(view, "update_resolved", %{
             "resolved" => %{
               "upstreams" => "203.0.113.53",
               "search_domains" => "desired.example"
             }
           }) =~ "Desired Resolved configuration published"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.expected_revision == @revision_b
    assert length(TestManagementTransport.recorded()) == before
  end

  test "Resolved editing follows the target of the latest durable rollback", %{conn: conn} do
    seed_applied_resolved_rollback("netman-a")
    cache_resolved_snapshots("netman-a", "stale", @revision_b)

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/resolved")

    assert has_element?(
             view,
             "#resolved-config-form input[name='resolved[upstreams]'][value='192.0.2.53']"
           )

    assert has_element?(
             view,
             "#resolved-config-form input[name='resolved[search_domains]'][value='alpha.example']"
           )

    assert render_submit(view, "update_resolved", %{
             "resolved" => %{
               "upstreams" => "203.0.113.53",
               "search_domains" => "after-rollback.example"
             }
           }) =~ "Desired Resolved configuration published"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.expected_revision == @revision_a
    assert length(TestManagementTransport.recorded()) == before
  end

  test "Resolved bootstrap starts blank and publishes without a runtime-derived revision", %{
    conn: conn
  } do
    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        upstreams("stale"),
        search_domains("stale"),
        resolved_cache("stale"),
        {:ok, %{"hits" => 7, "misses" => 2}}
      ])

    :ok = TestManagementTransport.script_config([:ok])
    {:ok, view, html} = live(conn, "/netman/netman-a/resolved")

    assert html =~ "198.51.100.53"
    assert has_element?(view, "#resolved-config-form input[name='resolved[upstreams]'][value='']")

    refute has_element?(view, "#resolved-config-form button[disabled]")
    assert has_element?(view, "#resolved-rollback-form button[disabled]")

    assert render_submit(view, "update_resolved", %{
             "resolved" => %{
               "upstreams" => "203.0.113.53",
               "search_domains" => "bootstrap.example"
             }
           }) =~ "Desired Resolved configuration published"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.expected_revision == nil
  end

  test "Resolved editing fails closed when Management-owned config cannot be read", %{
    conn: conn,
    data_dir: data_dir
  } do
    seed_applied_resolved_config("netman-a", @revision_b)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        upstreams("stale"),
        search_domains("stale"),
        resolved_cache("stale"),
        {:ok, %{"hits" => 7, "misses" => 2}}
      ])

    :ok = corrupt_netman_manifest(data_dir, "netman-a")
    {:ok, view, _html} = live(conn, "/netman/netman-a/resolved")

    assert has_element?(view, "#resolved-config-form button[disabled]")
    assert has_element?(view, "#resolved-rollback-form button[disabled]")

    assert render_submit(view, "update_resolved", %{
             "resolved" => %{
               "upstreams" => "203.0.113.53",
               "search_domains" => "forged.example"
             }
           }) =~ "Management-owned Resolved configuration is unavailable"

    assert config_envelopes() == []
  end

  test "offline Resolved rollback remains a durable config publication", %{conn: conn} do
    seed_applied_resolved_config("netman-a", @revision_b)
    cache_resolved_snapshots("netman-a", "alpha")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, view, _html} = live(conn, "/netman/netman-a/resolved")

    assert render_submit(view, "rollback_resolved", %{
             "rollback" => %{"target_revision" => @revision_a}
           }) =~ "Desired Resolved rollback published"

    assert {:ok, desired} = ManagementCore.latest_desired_config(:netman, "netman-a")
    assert desired.operation == "netman.resolved.config.rollback"
    assert length(TestManagementTransport.recorded()) == before
  end

  test "ID-scoped reconnect events refresh status without switching records", %{conn: conn} do
    profile = wire_profile("cached-profile", "cache0")
    :ok = TestManagementTransport.script_request([apply_mode("managed"), profile_list(profile)])
    assert %{status: :ok} = YellowDog.Console.NetmanManagement.runtime_apply_mode_get("netman-a")
    assert %{status: :ok} = YellowDog.Console.NetmanManagement.profiles_list("netman-a")

    :ok = TestManagementTransport.disconnect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :offline)
    {:ok, view, _html} = live(conn, "/netman/netman-a/config")
    html = render(view)
    assert html =~ "Offline cached snapshot"

    :ok = TestManagementTransport.connect(:netman, "netman-a")
    assert {:ok, _netman} = ManagementCore.update_netman_status("netman-a", :online)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("observe_first"),
        profile_list(wire_profile("reconnected-profile", "re0"))
      ])

    send(view.pid, {:netman_connection, :online, %{netman_id: "netman-a"}})
    html = render(view)

    assert html =~ "Connected"
    assert html =~ "reconnected-profile"
    refute html =~ "Offline cached snapshot"

    send(view.pid, {:netman_connection, :online, %{netman_id: "netman-b"}})
    assert render(view) =~ "reconnected-profile"
  end

  defp register_netman(id, name, apply_mode, status) do
    assert {:ok, _netman} =
             ManagementCore.register_netman(%{
               id: id,
               name: name,
               profile: :custom,
               apply_mode: apply_mode,
               status: status,
               last_seen_at: ~U[2026-08-11 01:02:03Z]
             })
  end

  defp overview_responses(prefix, mode) do
    profile = wire_profile("#{prefix}-profile", "#{prefix}0")

    [
      {:ok, %{"capabilities" => ["profiles.read", "network.links.read"]}},
      apply_mode(mode),
      {:ok, %{"status" => "healthy", "pending_changes" => 0}},
      profile_list(profile),
      links(prefix),
      routes(prefix),
      {:ok,
       %{
         "profile_id" => if(prefix == "alpha", do: "vpn_gateway", else: "custom"),
         "state" => "resolved",
         "revision" => @revision_c
       }}
    ]
  end

  defp apply_mode(mode), do: {:ok, %{"mode" => mode}}

  defp profile_list(profile), do: {:ok, list_result([profile_state(profile, @revision_a)])}

  defp profile_state(profile, revision) do
    %{
      "profile" => profile,
      "desired_revision" => revision,
      "active_revision" => revision
    }
  end

  defp profile_history(profile) do
    list_result([
      %{
        "profile_id" => profile["profile_id"],
        "revision" => @revision_a,
        "profile" => profile,
        "stored_at" => @observed_at,
        "activated_at" => @observed_at
      }
    ])
  end

  defp activation(profile_id, state) do
    %{
      "profile_id" => profile_id,
      "desired_revision" => @revision_a,
      "active_revision" => @revision_a,
      "state" => state,
      "connections" => [
        %{"profile_id" => profile_id, "interface" => "alpha0", "state" => state}
      ]
    }
  end

  defp links(prefix) do
    {:ok,
     list_result([
       %{"link_id" => "#{prefix}0", "name" => "#{prefix}0", "state" => "up"}
     ])}
  end

  defp addresses(prefix) do
    address = if prefix == "alpha", do: "192.0.2.10/24", else: "198.51.100.10/24"

    {:ok,
     list_result([
       %{"link_id" => "#{prefix}0", "address" => address, "scope" => "global"}
     ])}
  end

  defp routes(prefix) do
    gateway = if prefix == "alpha", do: "192.0.2.1", else: "198.51.100.1"

    {:ok,
     list_result([
       %{"destination" => "0.0.0.0/0", "gateway" => gateway, "link_id" => "#{prefix}0"}
     ])}
  end

  defp upstreams(prefix) do
    address = if prefix == "alpha", do: "192.0.2.53", else: "198.51.100.53"

    {:ok,
     list_result([%{"address" => address, "source" => "managed"}])
     |> Map.put("config_revision", @revision_b)}
  end

  defp search_domains(prefix) do
    {:ok, list_result([%{"domain" => "#{prefix}.example", "routing_only" => false}])}
  end

  defp resolved_cache(prefix) do
    {:ok,
     %{
       "revision" => @revision_c,
       "entries" => [
         %{
           "domain" => "cached.#{prefix}.example",
           "address" => "192.0.2.99",
           "expires_at" => "2026-08-11T02:02:03Z"
         }
       ]
     }}
  end

  defp lease(prefix) do
    address = if prefix == "alpha", do: "192.0.2.20", else: "198.51.100.20"

    %{
      "profile_id" => "#{prefix}-profile",
      "interface" => "#{prefix}0",
      "address" => address,
      "expires_at" => "2026-08-11T02:02:03Z",
      "revision" => @revision_b
    }
  end

  defp seed_applied_resolved_config(netman_id, applied_revision) do
    :ok = TestManagementTransport.disconnect(:netman, netman_id)

    assert {:ok, desired} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.update",
               payload: %{"upstreams" => ["192.0.2.53"], "search_domains" => ["alpha.example"]},
               expected_revision: nil
             })

    assert {:ok, delivered} = transition_config(desired, :delivered, 0, nil)
    assert {:ok, applying} = transition_config(delivered, :applying, 1, nil)
    assert {:ok, _applied} = transition_config(applying, :applied, 2, applied_revision)

    TestManagementTransport.connect(:netman, netman_id)
  end

  defp seed_desired_resolved_config(netman_id) do
    :ok = TestManagementTransport.disconnect(:netman, netman_id)

    assert {:ok, _desired} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.update",
               payload: %{"upstreams" => ["192.0.2.53"], "search_domains" => ["alpha.example"]},
               expected_revision: nil
             })

    TestManagementTransport.connect(:netman, netman_id)
  end

  defp seed_applied_resolved_rollback(netman_id) do
    :ok = TestManagementTransport.disconnect(:netman, netman_id)

    assert {:ok, first} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.update",
               payload: %{"upstreams" => ["192.0.2.53"], "search_domains" => ["alpha.example"]},
               expected_revision: nil
             })

    assert {:ok, first} = transition_config(first, :delivered, 0, nil)
    assert {:ok, first} = transition_config(first, :applying, 1, nil)
    assert {:ok, _first} = transition_config(first, :applied, 2, @revision_a)

    assert {:ok, second} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.update",
               payload: %{
                 "upstreams" => ["198.51.100.53"],
                 "search_domains" => ["newer.example"]
               },
               expected_revision: @revision_a
             })

    assert {:ok, second} = transition_config(second, :delivered, 0, nil)
    assert {:ok, second} = transition_config(second, :applying, 1, nil)
    assert {:ok, _second} = transition_config(second, :applied, 2, @revision_b)

    assert {:ok, rollback} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.rollback",
               payload: %{"target_revision" => @revision_a},
               expected_revision: @revision_b
             })

    assert {:ok, rollback} = transition_config(rollback, :delivered, 0, nil)
    assert {:ok, rollback} = transition_config(rollback, :applying, 1, nil)
    assert {:ok, _rollback} = transition_config(rollback, :applied, 2, @revision_a)

    TestManagementTransport.connect(:netman, netman_id)
  end

  defp cache_resolved_snapshots(netman_id, prefix, config_revision \\ @revision_b) do
    {:ok, upstream_value} = upstreams(prefix)

    :ok =
      TestManagementTransport.script_request([
        apply_mode("managed"),
        {:ok, Map.put(upstream_value, "config_revision", config_revision)},
        search_domains(prefix),
        resolved_cache(prefix),
        {:ok, %{"hits" => 7, "misses" => 2}}
      ])

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.runtime_apply_mode_get(netman_id)
    assert %{status: :ok} = YellowDog.Console.NetmanManagement.resolved_upstreams_list(netman_id)

    assert %{status: :ok} =
             YellowDog.Console.NetmanManagement.resolved_search_domains_list(netman_id)

    assert %{status: :ok} = YellowDog.Console.NetmanManagement.resolved_cache_get(netman_id)
    assert %{status: :ok} = YellowDog.Console.NetmanManagement.resolved_counters_get(netman_id)
  end

  defp corrupt_netman_manifest(data_dir, netman_id) do
    path = Path.join([data_dir, "management", "netmans", netman_id, "manifest.json"])
    File.write!(path, "{")
  end

  defp seed_applied_profile_config(netman_id, profile, applied_revision) do
    :ok = TestManagementTransport.disconnect(:netman, netman_id)

    assert {:ok, desired} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.profiles.replace",
               payload: %{"profiles" => [profile]},
               expected_revision: nil
             })

    assert {:ok, delivered} = transition_config(desired, :delivered, 0, nil)
    assert {:ok, applying} = transition_config(delivered, :applying, 1, nil)
    assert {:ok, _applied} = transition_config(applying, :applied, 2, applied_revision)

    TestManagementTransport.connect(:netman, netman_id)
  end

  defp transition_config(version, state, expected_state_revision, applied_revision) do
    {previous_version, previous_revision} =
      if state == :delivered,
        do: {nil, nil},
        else: {version.previous_version, version.previous_revision}

    acknowledgement = %ConfigState{
      target_type: version.target_type,
      target_id: version.target_id,
      operation: version.operation,
      state: state,
      version: version.version,
      digest: version.digest,
      applied_revision: applied_revision,
      previous_version: previous_version,
      previous_revision: previous_revision,
      failure: nil,
      rollback: nil,
      observed_at: DateTime.utc_now(:second)
    }

    ManagementCore.transition_config(
      version.target_type,
      version.target_id,
      version.version,
      state,
      %{expected_state_revision: expected_state_revision, acknowledgement: acknowledgement}
    )
  end

  defp list_result(items) do
    %{"items" => items, "revision" => @revision_a, "observed_at" => @observed_at}
  end

  defp wire_profile(profile_id, interface) do
    %{
      "profile_id" => profile_id,
      "type" => "ethernet",
      "interface" => interface,
      "autoconnect" => true,
      "autoconnect_priority" => 100,
      "zone" => "default",
      "ethernet" => %{"mtu" => 1_500},
      "ipv4" => %{
        "method" => "auto",
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

  defp profile_form(profile_id, interface) do
    %{
      "profile_id" => profile_id,
      "interface" => interface,
      "autoconnect" => "true",
      "autoconnect_priority" => "100",
      "zone" => "default",
      "mtu" => "1500",
      "ipv4_method" => "auto",
      "ipv4_address" => "",
      "ipv4_gateway" => "",
      "ipv4_dns" => "",
      "ipv4_dns_search" => "",
      "ipv6_method" => "disabled",
      "ipv6_address" => "",
      "ipv6_gateway" => "",
      "ipv6_dns" => "",
      "ipv6_dns_search" => "",
      "expected_revision" => @revision_a
    }
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp config_envelopes do
    for {:config, _envelope} = entry <- TestManagementTransport.recorded(), do: entry
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
