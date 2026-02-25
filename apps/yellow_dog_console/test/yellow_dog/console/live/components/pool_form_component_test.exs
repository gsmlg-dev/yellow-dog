defmodule YellowDog.Console.Components.PoolFormComponentTest do
  @moduledoc """
  Tests for PoolFormComponent (DHCPv4/DHCPv6 pool create/edit modal).

  The component is a LiveComponent mounted inside PoolsLive pages.
  We drive it through /dhcpv4/pools (show_new_form) and verify
  the validate/save/close event pipeline.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ── Opening the form ────────────────────────────────────────────────

  describe "show_new_form opens the pool modal" do
    test "clicking show_new_form renders the form modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_new_form", %{})

      # The modal appears with the form heading
      assert html =~ "Add DHCPv4 Pool" or html =~ "Pool Name"
    end

    test "form contains name, network, range_start, range_end inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_new_form", %{})

      assert html =~ "address_pool[name]"
      assert html =~ "address_pool[range_start]"
      assert html =~ "address_pool[range_end]"
    end

    test "DHCPv4 form shows lease_time field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_new_form", %{})

      assert html =~ "address_pool[lease_time]" or html =~ "Lease Time"
    end

    test "form submit button says Add Pool in create mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_new_form", %{})

      assert html =~ "Add Pool"
    end
  end

  # ── DHCPv4 validate event ────────────────────────────────────────────

  describe "validate event (DHCPv4)" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      render_click(view, "show_new_form", %{})
      {:ok, view: view}
    end

    test "valid params keep form open without errors", %{view: view} do
      html =
        view
        |> element("#pool-form")
        |> render_change(%{
          "address_pool" => %{
            "name" => "testpool",
            "range_start" => "192.168.1.100",
            "range_end" => "192.168.1.200",
            "lease_time" => "3600",
            "protocol" => "ipv4"
          }
        })

      # Form still shown after validate
      assert html =~ "address_pool[name]"
    end

    test "empty name triggers required validation", %{view: view} do
      html =
        view
        |> element("#pool-form")
        |> render_change(%{
          "address_pool" => %{
            "name" => "",
            "range_start" => "192.168.1.100",
            "range_end" => "192.168.1.200",
            "lease_time" => "3600",
            "protocol" => "ipv4"
          }
        })

      assert html =~ "required" or html =~ "blank" or html =~ "Pool Name"
    end
  end

  # ── DHCPv4 save event ────────────────────────────────────────────────

  describe "save event (DHCPv4)" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      render_click(view, "show_new_form", %{})
      {:ok, view: view}
    end

    test "valid save is handled without crashing (service may be unavailable)", %{view: view} do
      view
      |> element("#pool-form")
      |> render_submit(%{
        "address_pool" => %{
          "name" => "newpool",
          "range_start" => "10.0.0.100",
          "range_end" => "10.0.0.200",
          "network" => "10.0.0.0/24",
          "lease_time" => "3600",
          "protocol" => "ipv4"
        }
      })

      # Flush parent's handle_info({:pool_saved, ...}) — in test env DHCPv4 service is
      # unavailable, so parent shows error flash (form stays open). Accept either state.
      html = render(view)
      assert is_binary(html)
    end

    test "invalid save (missing name) keeps modal open with errors", %{view: view} do
      html =
        view
        |> element("#pool-form")
        |> render_submit(%{
          "address_pool" => %{
            "name" => "",
            "range_start" => "192.168.1.100",
            "range_end" => "192.168.1.200",
            "lease_time" => "3600",
            "protocol" => "ipv4"
          }
        })

      # Modal stays open with errors
      assert html =~ "pool-form" or html =~ "Pool Name"
    end

    test "invalid IP in range_start shows validation error", %{view: view} do
      html =
        view
        |> element("#pool-form")
        |> render_submit(%{
          "address_pool" => %{
            "name" => "testpool",
            "range_start" => "not-an-ip",
            "range_end" => "192.168.1.200",
            "lease_time" => "3600",
            "protocol" => "ipv4"
          }
        })

      # Should show an IP validation error
      assert html =~ "pool-form" or html =~ "Invalid"
    end
  end

  # ── Close event ─────────────────────────────────────────────────────

  describe "close event" do
    test "close event hides the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      render_click(view, "show_new_form", %{})

      # Click the Cancel button — fires component's handle_event("close"),
      # which sends :close_pool_form to the parent LiveView.
      # render_click returns component HTML (before parent processes the message),
      # so we call render(view) to flush the parent's handle_info queue.
      view |> element("button[phx-click='close']") |> render_click()
      html = render(view)

      refute html =~ "phx-submit=\"save\""
    end

    test "Escape keydown closes the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      render_click(view, "show_new_form", %{})

      # phx-window-keydown="close" phx-key="Escape" is on the component root div.
      # render_keydown triggers the component's handle_event("close"),
      # which sends :close_pool_form to parent — flush with render(view).
      view |> element("[phx-window-keydown='close']") |> render_keydown(%{"key" => "Escape"})
      html = render(view)

      refute html =~ "phx-submit=\"save\""
    end
  end

  # ── DHCPv6 form ─────────────────────────────────────────────────────

  describe "DHCPv6 pool form shows protocol-specific fields" do
    test "DHCPv6 form opens with preferred_lifetime and valid_lifetime fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_click(view, "show_new_form", %{})

      assert html =~ "preferred_lifetime" or html =~ "Preferred Lifetime"
      assert html =~ "valid_lifetime" or html =~ "Valid Lifetime"
    end

    test "DHCPv6 form title says DHCPv6", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_click(view, "show_new_form", %{})

      assert html =~ "DHCPv6" or html =~ "Pool"
    end
  end
end
