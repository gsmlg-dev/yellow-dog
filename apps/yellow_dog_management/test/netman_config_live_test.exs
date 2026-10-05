defmodule YellowDog.Management.NetmanConfigLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    node =
      mutate("create_netman", %{
        "id" => "selected",
        "name" => "Selected",
        "profile_name" => "custom",
        "apply_mode" => "managed",
        "features" => %{}
      })

    %{conn: build_conn(), node: node}
  end

  test "profile validation is pure and typed save/edit/delete changes desired state only", %{
    conn: conn,
    node: node
  } do
    {:ok, view, html} = live(conn, "/netman/selected/config")
    assert html =~ "Runtime activation, cache flush and lease operations are not migrated"
    assert {:ok, initial} = Domain.get_netman_config(node["id"])
    before_validation = Domain.list_audit()
    render_submit(view, "validate_profile", %{"profile" => profile_fields()})
    assert has_element?(view, "#netman-config-validation", "Desired configuration is valid")
    assert {:ok, ^initial} = Domain.get_netman_config(node["id"])
    assert Domain.list_audit() == before_validation

    view |> form("#netman-profile-form", profile: profile_fields()) |> render_submit()
    assert {:ok, saved} = Domain.get_netman_config(node["id"])
    [profile] = saved["document"]["profiles"]
    assert profile["type"] == "ethernet"
    assert profile["autoconnect"] == true
    assert profile["autoconnect_priority"] == 12
    assert profile["ethernet"]["mtu"] == 1500
    assert profile["ipv4"]["dns"] == ["192.0.2.53", "198.51.100.53"]
    assert profile["ipv4"]["dns_search"] == ["example.test", "internal.test"]
    assert profile["ipv6"]["method"] == "link-local"
    assert saved["revision"] == initial["revision"] + 1
    assert Domain.list_netman_versions(node["id"]) == []

    view
    |> element("button[phx-click='edit_profile'][phx-value-profile_id='lan']")
    |> render_click()

    assert has_element?(view, "input[name='profile[profile_id]'][value='lan'][readonly]")

    view
    |> form("#netman-profile-form", profile: %{interface: "eth1", autoconnect_priority: "20"})
    |> render_submit()

    assert {:ok, edited} = Domain.get_netman_config(node["id"])
    assert hd(edited["document"]["profiles"])["interface"] == "eth1"
    assert hd(edited["document"]["profiles"])["autoconnect_priority"] == 20

    view
    |> element("button[phx-click='delete_profile'][phx-value-profile_id='lan']")
    |> render_click()

    assert {:ok, deleted} = Domain.get_netman_config(node["id"])
    assert deleted["document"]["profiles"] == []
    assert {:ok, ^node} = Domain.get_netman(node["id"])
  end

  test "invalid manual profiles, malformed forms and duplicate IDs do not mutate drafts", %{
    conn: conn,
    node: node
  } do
    {:ok, view, _html} = live(conn, "/netman/selected/config")
    assert {:ok, initial} = Domain.get_netman_config(node["id"])
    before_invalid = Domain.list_audit()

    for params <- [
          Map.put(profile_fields(), "ipv4_address", ""),
          Map.put(profile_fields(), "mtu", "67"),
          Map.put(profile_fields(), "ipv4_dns", %{}),
          Map.put(profile_fields(), "profile_id", "../bad")
        ] do
      render_submit(view, "put_profile", %{"profile" => params})
      assert {:ok, ^initial} = Domain.get_netman_config(node["id"])
      assert Domain.list_audit() == before_invalid
    end

    view |> form("#netman-profile-form", profile: profile_fields()) |> render_submit()
    assert {:ok, saved} = Domain.get_netman_config(node["id"])
    render_submit(view, "put_profile", %{"profile" => profile_fields()})
    assert {:ok, ^saved} = Domain.get_netman_config(node["id"])
  end

  test "Resolved edits preserve profiles and parse comma-separated desired lists", %{
    conn: conn,
    node: node
  } do
    {:ok, profiles, _html} = live(conn, "/netman/selected/config")
    profiles |> form("#netman-profile-form", profile: profile_fields()) |> render_submit()
    {:ok, before_resolved} = Domain.get_netman_config(node["id"])
    before_visit = Domain.list_audit()
    {:ok, view, _html} = live(conn, "/netman/selected/resolved?netman_id[]=other")
    assert has_element?(view, "#netman-resolved-form")
    assert has_element?(view, "a[href='/netman/selected/config']", "Configuration")
    assert Domain.list_audit() == before_visit

    view
    |> form("#netman-resolved-form",
      resolved: %{
        upstreams: "192.0.2.53, 2001:db8::53",
        search_domains: "example.test, internal.test"
      }
    )
    |> render_submit()

    assert {:ok, saved} = Domain.get_netman_config(node["id"])
    assert saved["document"]["profiles"] == before_resolved["document"]["profiles"]

    assert saved["document"]["resolved"] == %{
             "upstreams" => ["192.0.2.53", "2001:db8::53"],
             "search_domains" => ["example.test", "internal.test"]
           }
  end

  test "confirmation is immutable and rollback selects stored desired content", %{
    conn: conn,
    node: node
  } do
    {:ok, view, _html} = live(conn, "/netman/selected/config")
    view |> form("#netman-profile-form", profile: profile_fields()) |> render_submit()
    view |> element("#confirm-netman-config") |> render_click()
    [version] = Domain.list_netman_versions(node["id"])
    assert has_element?(view, "#netman-config-versions", version["digest"])
    assert version["status"] == "prepared"
    assert version["actual_state"] == "unknown"

    view
    |> element("button[phx-click='delete_profile'][phx-value-profile_id='lan']")
    |> render_click()

    assert {:ok, empty} = Domain.get_netman_config(node["id"])
    assert empty["document"]["profiles"] == []

    view
    |> form("#netman-config-rollback-form",
      rollback: %{target_version: to_string(version["version"])}
    )
    |> render_submit()

    assert {:ok, restored} = Domain.get_netman_config(node["id"])
    assert restored["document"] == version["document"]
    assert version in Domain.list_netman_versions(node["id"])
    assert {:ok, ^node} = Domain.get_netman(node["id"])

    before_invalid = {restored, Domain.list_audit()}

    for target <- ["9999", "not-a-version", [to_string(version["version"])]] do
      render_submit(view, "rollback_config", %{
        "rollback" => %{"target_version" => target, "document" => %{}}
      })

      assert {:ok, unchanged} = Domain.get_netman_config(node["id"])
      assert {unchanged, Domain.list_audit()} == before_invalid
    end
  end

  test "stale full-document edits never overwrite concurrent desired configuration", %{
    conn: conn,
    node: node
  } do
    {:ok, view, _html} = live(conn, "/netman/selected/config")
    {:ok, draft} = Domain.get_netman_config(node["id"])
    document = put_in(draft["document"], ["resolved", "upstreams"], ["192.0.2.53"])

    concurrent =
      mutate("update_netman_config", %{
        "id" => node["id"],
        "expected_revision" => draft["revision"],
        "document" => document
      })

    assert view |> form("#netman-profile-form", profile: profile_fields()) |> render_submit() =~
             "revision"

    assert {:ok, ^concurrent} = Domain.get_netman_config(node["id"])
  end

  test "observe mode disables all desired mutations and forged actions fail closed", %{
    conn: conn,
    node: node
  } do
    mutate("update_netman", %{
      "id" => node["id"],
      "expected_revision" => node["revision"],
      "apply_mode" => "observe"
    })

    {:ok, initial} = Domain.get_netman_config(node["id"])
    before_visit = {Domain.list_netmans(), Domain.list_audit()}

    for suffix <- ["config", "resolved"] do
      {:ok, view, html} = live(conn, "/netman/selected/#{suffix}")
      assert html =~ "Observe mode is read-only"
      assert has_element?(view, "#confirm-netman-config[disabled]")
      assert has_element?(view, "#rollback-netman-config[disabled]")
      render_submit(view, "put_profile", %{"profile" => profile_fields()})

      render_submit(view, "update_resolved", %{
        "resolved" => %{"upstreams" => "192.0.2.53", "search_domains" => ""}
      })

      render_click(view, "confirm_config", %{})
      render_click(view, "delete_profile", %{"profile_id" => "lan"})
      render_submit(view, "rollback_config", %{"rollback" => %{"target_version" => "1"}})
      assert {:ok, ^initial} = Domain.get_netman_config(node["id"])
      assert {Domain.list_netmans(), Domain.list_audit()} == before_visit
    end
  end

  test "unknown Netman path scopes ignore query overrides and block every mutation", %{
    conn: conn,
    node: node
  } do
    {:ok, initial} = Domain.get_netman_config(node["id"])
    before_visit = Domain.list_audit()

    for suffix <- ["config", "resolved"],
        query <- ["netman_id=selected", "netman_id[]=selected", "netman_id[id]=selected"] do
      {:ok, view, _html} = live(conn, "/netman/missing/#{suffix}?#{query}")
      assert has_element?(view, "#netman-config-scope-error")
      refute has_element?(view, "#netman-profile-form")
      refute has_element?(view, "#netman-resolved-form")
      render_submit(view, "put_profile", %{"profile" => profile_fields()})
      render_click(view, "confirm_config", %{})

      render_submit(view, "update_resolved", %{
        "resolved" => %{"upstreams" => "192.0.2.53", "search_domains" => ""}
      })

      assert {:ok, ^initial} = Domain.get_netman_config(node["id"])
      assert Domain.list_audit() == before_visit
    end
  end

  defp profile_fields do
    %{
      "profile_id" => "lan",
      "interface" => "eth0",
      "zone" => "default",
      "autoconnect" => "true",
      "autoconnect_priority" => "12",
      "mtu" => "1500",
      "ipv4_method" => "manual",
      "ipv4_address" => "192.0.2.10/24",
      "ipv4_gateway" => "192.0.2.1",
      "ipv4_dns" => "192.0.2.53, 198.51.100.53",
      "ipv4_dns_search" => "example.test, internal.test",
      "ipv6_method" => "link-local",
      "ipv6_address" => "",
      "ipv6_gateway" => "",
      "ipv6_dns" => "",
      "ipv6_dns_search" => ""
    }
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
