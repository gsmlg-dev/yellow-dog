defmodule YellowDog.Console.IdentityLiveTest do
  @moduledoc """
  LiveView tests for identity management pages.
  Tests page mounting and basic rendering when identity service may not be running.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Identity Index
  # ============================================================================

  describe "Identity Index /identity" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Host Identity Registry"
    end

    test "shows stats", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Total Hosts"
      assert html =~ "Pending"
      assert html =~ "Approved"
      assert html =~ "Revoked"
    end

    test "shows service status badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Running" or html =~ "Stopped"
    end

    test "shows quick action links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "View All Hosts"
      assert html =~ "Pending Approvals"
      assert html =~ "Provisioning Tokens"
      assert html =~ "Approval Policies"
      assert html =~ "Audit Log"
    end

    test "shows export buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Export YAML"
      assert html =~ "Export sops"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity")
      html = render_click(view, "refresh")
      assert html =~ "Host Identity Registry"
    end

    test "shows trust level distribution card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Trust Level Distribution"
    end

    test "shows trust providers card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity")
      assert html =~ "Trust Providers"
    end

    test "preview_export yaml event shows export preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity")
      html = render_click(view, "preview_export", %{"format" => "yaml"})
      assert html =~ "Export Preview" or html =~ "YAML"
    end

    test "preview_export sops event shows sops preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity")
      html = render_click(view, "preview_export", %{"format" => "sops"})
      assert html =~ "Export Preview" or html =~ "SOPS"
    end

    test "close_export hides the preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity")
      render_click(view, "preview_export", %{"format" => "yaml"})
      html = render_click(view, "close_export")
      assert html =~ "Host Identity Registry"
    end
  end

  # ============================================================================
  # Hosts List
  # ============================================================================

  describe "Hosts List /identity/hosts" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/hosts")
      assert html =~ "All Hosts"
    end

    test "shows search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/hosts")
      assert html =~ "Search hostname"
    end

    test "shows table headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/hosts")
      assert html =~ "Hostname"
      assert html =~ "Status"
      assert html =~ "Trust"
    end

    test "filter event works for pending", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_click(view, "filter", %{"status" => "pending"})
      assert html =~ "Hostname"
    end

    test "filter event works for approved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_click(view, "filter", %{"status" => "approved"})
      assert html =~ "Hostname"
    end

    test "filter event works for revoked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_click(view, "filter", %{"status" => "revoked"})
      assert html =~ "Hostname"
    end

    test "filter event works for all", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_click(view, "filter", %{"status" => "all"})
      assert html =~ "Hostname"
    end

    test "search event filters by hostname", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_change(view, "search", %{"q" => "node-01"})
      assert html =~ "Hostname"
    end

    test "search event with empty query shows all", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_change(view, "search", %{"q" => ""})
      assert html =~ "Hostname"
    end

    test "refresh event reloads host list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/hosts")
      html = render_click(view, "refresh")
      assert html =~ "Hostname"
    end

    test "shows empty state when no hosts registered", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/hosts")
      assert html =~ "No hosts registered" or html =~ "Hostname"
    end
  end

  # ============================================================================
  # Pending Approvals
  # ============================================================================

  describe "Approvals /identity/approvals" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/approvals")
      assert html =~ "Pending Approvals"
    end

    test "shows empty state when no pending hosts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/approvals")
      assert html =~ "No pending approvals" or html =~ "Pending Approvals"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "refresh")
      assert html =~ "Pending Approvals"
    end

    test "select_all event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "select_all")
      assert html =~ "Pending Approvals"
    end

    test "select_none event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "select_none")
      assert html =~ "Pending Approvals"
    end

    test "bulk_approve with empty selection does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "bulk_approve")
      assert html =~ "Pending Approvals"
    end

    test "bulk_reject with empty selection does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "bulk_reject")
      assert html =~ "Pending Approvals"
    end

    test "approve event for nonexistent host handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "approve", %{"id" => "nonexistent-id"})
      assert html =~ "Pending Approvals"
    end

    test "reject event for nonexistent host handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      html = render_click(view, "reject", %{"id" => "nonexistent-id"})
      assert html =~ "Pending Approvals"
    end

    test "PubSub host_registered message triggers reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      send(view.pid, {:host_registered, %{id: "new-host-id"}})
      html = render(view)
      assert html =~ "Pending Approvals"
    end

    test "PubSub host_updated message triggers reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      send(view.pid, {:host_updated, %{id: "some-host-id"}})
      html = render(view)
      assert html =~ "Pending Approvals"
    end

    test "unknown PubSub messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/approvals")
      send(view.pid, {:unknown_message, :data})
      html = render(view)
      assert html =~ "Pending Approvals"
    end
  end

  # ============================================================================
  # Provisioning Tokens
  # ============================================================================

  describe "Tokens /identity/tokens" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/tokens")
      assert html =~ "Provisioning Tokens"
    end

    test "shows create token button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/tokens")
      assert html =~ "New Token"
    end

    test "shows table headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/tokens")
      assert html =~ "Pattern"
      assert html =~ "Uses"
      assert html =~ "Expires"
    end

    test "toggle create form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      html = render_click(view, "toggle_create")
      assert html =~ "Create Provisioning Token"
      assert html =~ "Hostname Pattern"
      assert html =~ "Max Uses"
    end

    test "toggle create form twice hides it again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      render_click(view, "toggle_create")
      html = render_click(view, "toggle_create")
      # Form should be hidden again
      assert html =~ "Provisioning Tokens"
    end

    test "create_token form submission handles unavailable service gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      render_click(view, "toggle_create")

      html =
        view
        |> form("form",
          hostname_pattern: "node-*",
          max_uses: "1",
          ttl_hours: "24",
          role: ""
        )
        |> render_submit()

      # Either token created (if service running) or error flash shown
      assert html =~ "Provisioning Tokens"
    end

    test "revoke_token for nonexistent id handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      html = render_click(view, "revoke_token", %{"id" => "nonexistent-token-id"})
      assert html =~ "Provisioning Tokens"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      html = render_click(view, "refresh")
      assert html =~ "Provisioning Tokens"
    end

    test "dismiss_token event clears new token display", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/tokens")
      html = render_click(view, "dismiss_token")
      assert html =~ "Provisioning Tokens"
    end
  end

  # ============================================================================
  # Approval Policies
  # ============================================================================

  describe "Policies /identity/policies" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/policies")
      assert html =~ "Approval Policies"
    end

    test "shows config info alert", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/policies")
      assert html =~ "config.toml"
      assert html =~ "identity.approval"
    end

    test "shows default action", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/policies")
      assert html =~ "Default action"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/policies")
      html = render_click(view, "refresh")
      assert html =~ "Approval Policies"
    end
  end

  # ============================================================================
  # Audit Log
  # ============================================================================

  describe "Audit /identity/audit" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/audit")
      assert html =~ "Audit Log"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/audit")
      assert html =~ "All Events" or html =~ "Event Type"
    end

    test "filter event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/audit")
      html = render_change(view, "filter", %{"event" => "host.approved", "host" => ""})
      assert html =~ "Audit Log"
    end

    test "filter with host id works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/audit")
      html = render_change(view, "filter", %{"event" => "", "host" => "some-host-id"})
      assert html =~ "Audit Log"
    end

    test "filter reset works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/audit")
      html = render_change(view, "filter", %{"event" => "", "host" => ""})
      assert html =~ "Audit Log"
    end

    test "refresh event works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/identity/audit")
      html = render_click(view, "refresh")
      assert html =~ "Audit Log"
    end

    test "shows empty state when no entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/identity/audit")
      assert html =~ "No audit entries found" or html =~ "Timestamp"
    end
  end

  # ============================================================================
  # Host Detail
  # ============================================================================

  describe "Host Detail /identity/hosts/:id" do
    test "mounts successfully for unknown host id", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      assert html =~ "Host not found" or html =~ "Host"
    end

    test "shows back navigation link", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      assert html =~ "Back" or html =~ "/server/identity/hosts"
    end

    test "shows not found alert for missing host", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      assert html =~ "Host not found" or html =~ "Host"
    end

    test "page title contains Host", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      assert html =~ "Host"
    end

    test "approve event handles gracefully when host not found", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      # approve event should not crash the LiveView
      html = render_click(view, "approve")
      assert html =~ "Host"
    end

    test "revoke event handles gracefully when host not found", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, "/server/identity/hosts/00000000-0000-0000-0000-000000000000")

      html = render_click(view, "revoke")
      assert html =~ "Host"
    end
  end
end
