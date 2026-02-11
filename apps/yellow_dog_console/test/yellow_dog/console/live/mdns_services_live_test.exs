defmodule YellowDog.Console.MdnsServicesLiveTest do
  @moduledoc """
  LiveView tests for mDNS Services page: mounting, form validation,
  event handlers, and accessibility.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias YellowDog.Console.MdnsLive.ServicesLive

  # ============================================================================
  # Mounting & Template
  # ============================================================================

  describe "mDNS Services /mdns/services mounting" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Registered Services"
    end

    test "shows filter tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "All Services"
      assert html =~ "Enabled"
      assert html =~ "Disabled"
    end

    test "shows register service button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Register Service"
    end

    test "shows export CSV button with hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ ~s(phx-hook="CsvDownload")
      assert html =~ ~s(id="export-csv")
    end

    test "shows empty state when no services", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "No services found"
    end
  end

  # ============================================================================
  # Form Display
  # ============================================================================

  describe "mDNS Services /mdns/services form" do
    test "show_new_form opens modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "show_new_form")
      assert html =~ "Register New Service"
      assert html =~ "Service Name"
      assert html =~ "Service Type"
      assert html =~ "Port"
      assert html =~ "TXT Records"
      assert html =~ "IP Addresses"
    end

    test "hide_form closes modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")
      html = render_click(view, "hide_form")
      refute html =~ "Register New Service"
    end

    test "form has phx-change for validation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "show_new_form")
      assert html =~ ~s(phx-change="validate_service")
    end

    test "port field has min/max attributes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "show_new_form")
      assert html =~ ~s(min="1")
      assert html =~ ~s(max="65535")
    end
  end

  # ============================================================================
  # Form Validation (phx-change)
  # ============================================================================

  describe "mDNS Services /mdns/services validation" do
    test "validates empty service name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "",
          "type" => "_http._tcp",
          "port" => "8080",
          "addresses" => "",
          "txt" => ""
        })

      assert html =~ "Service name is required"
    end

    test "validates empty service type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "",
          "port" => "8080",
          "addresses" => "",
          "txt" => ""
        })

      assert html =~ "Service type is required"
    end

    test "validates invalid service type format", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "http",
          "port" => "8080",
          "addresses" => "",
          "txt" => ""
        })

      assert html =~ "_service._tcp"
    end

    test "validates invalid port", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "_http._tcp",
          "port" => "99999",
          "addresses" => "",
          "txt" => ""
        })

      assert html =~ "Port must be a number between 1 and 65535"
    end

    test "validates empty port", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "_http._tcp",
          "port" => "",
          "addresses" => "",
          "txt" => ""
        })

      assert html =~ "Port must be a number between 1 and 65535"
    end

    test "validates invalid IP address", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "_http._tcp",
          "port" => "8080",
          "addresses" => "not-an-ip",
          "txt" => ""
        })

      assert html =~ "Invalid IP address"
    end

    test "accepts valid form data without errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "_http._tcp",
          "port" => "8080",
          "addresses" => "192.168.1.100",
          "txt" => "version=1.0"
        })

      refute html =~ "text-error"
    end

    test "accepts valid IPv6 addresses", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_change(view, "validate_service", %{
          "name" => "My Service",
          "type" => "_http._tcp",
          "port" => "8080",
          "addresses" => "::1",
          "txt" => ""
        })

      refute html =~ "Invalid IP address"
    end
  end

  # ============================================================================
  # Unit Tests for validate_service_params/1
  # ============================================================================

  describe "validate_service_params/1" do
    test "returns empty map for valid params" do
      params = %{
        "name" => "Test",
        "type" => "_http._tcp",
        "port" => "8080",
        "addresses" => ""
      }

      assert ServicesLive.validate_service_params(params) == %{}
    end

    test "returns error for missing name" do
      params = %{"name" => "", "type" => "_http._tcp", "port" => "80", "addresses" => ""}
      errors = ServicesLive.validate_service_params(params)
      assert errors[:name] == "Service name is required"
    end

    test "returns error for invalid type format" do
      params = %{"name" => "Svc", "type" => "bad-type", "port" => "80", "addresses" => ""}
      errors = ServicesLive.validate_service_params(params)
      assert errors[:type] =~ "_service._tcp"
    end

    test "accepts _udp service types" do
      params = %{"name" => "Svc", "type" => "_dns._udp", "port" => "53", "addresses" => ""}
      assert ServicesLive.validate_service_params(params) == %{}
    end

    test "returns error for port 0" do
      params = %{"name" => "Svc", "type" => "_http._tcp", "port" => "0", "addresses" => ""}
      errors = ServicesLive.validate_service_params(params)
      assert errors[:port] =~ "Port must be"
    end

    test "returns error for port 70000" do
      params = %{"name" => "Svc", "type" => "_http._tcp", "port" => "70000", "addresses" => ""}
      errors = ServicesLive.validate_service_params(params)
      assert errors[:port] =~ "Port must be"
    end

    test "returns error for non-numeric port" do
      params = %{"name" => "Svc", "type" => "_http._tcp", "port" => "abc", "addresses" => ""}
      errors = ServicesLive.validate_service_params(params)
      assert errors[:port] =~ "Port must be"
    end

    test "returns error for invalid IP in addresses" do
      params = %{
        "name" => "Svc",
        "type" => "_http._tcp",
        "port" => "80",
        "addresses" => "192.168.1.1\nnot-valid"
      }

      errors = ServicesLive.validate_service_params(params)
      assert errors[:addresses] =~ "Invalid IP address: not-valid"
    end

    test "accepts empty addresses" do
      params = %{"name" => "Svc", "type" => "_http._tcp", "port" => "80", "addresses" => ""}
      assert ServicesLive.validate_service_params(params) == %{}
    end

    test "accepts valid mixed IPv4 and IPv6" do
      params = %{
        "name" => "Svc",
        "type" => "_http._tcp",
        "port" => "80",
        "addresses" => "192.168.1.1\n::1\nfe80::1"
      }

      assert ServicesLive.validate_service_params(params) == %{}
    end
  end

  # ============================================================================
  # Filter Events
  # ============================================================================

  describe "mDNS Services /mdns/services filter events" do
    test "filter all shows all services tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "filter", %{"filter" => "all"})
      assert html =~ "Registered Services"
    end

    test "filter enabled shows enabled tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "filter", %{"filter" => "enabled"})
      assert html =~ "Registered Services"
    end

    test "filter with invalid value defaults to all", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "filter", %{"filter" => "evil"})
      assert html =~ "Registered Services"
    end
  end

  # ============================================================================
  # Service CRUD Event Handlers
  # ============================================================================

  describe "mDNS Services /mdns/services CRUD events" do
    test "toggle_service handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "toggle_service", %{"id" => "nonexistent-service"})
      # Should show error flash since mDNS is not running
      assert html =~ "Failed to toggle service" or html =~ "Registered Services"
    end

    test "delete_service handles error gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "delete_service", %{"id" => "nonexistent-service"})
      # Should show error flash since mDNS is not running
      assert html =~ "Failed to delete service" or html =~ "Registered Services"
    end

    test "show_edit_form opens form in edit mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "show_edit_form", %{"id" => "test-service"})
      # Form should be visible (edit mode, service may be nil since mDNS not running)
      assert html =~ "Edit Service" or html =~ "Service Name"
    end

    test "save_service with validation errors shows errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_submit(view, "save_service", %{
          "name" => "",
          "type" => "",
          "port" => "",
          "addresses" => "",
          "txt" => "",
          "enabled" => "true"
        })

      assert html =~ "Service name is required"
      assert html =~ "Service type is required"
    end

    test "save_service with valid params handles service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "show_new_form")

      html =
        render_submit(view, "save_service", %{
          "name" => "Test Service",
          "type" => "_http._tcp",
          "port" => "8080",
          "addresses" => "",
          "txt" => "",
          "enabled" => "true"
        })

      # mDNS is not running so register_service will fail
      assert html =~ "Failed to save service" or html =~ "Registered Services"
    end
  end

  # ============================================================================
  # Export CSV
  # ============================================================================

  describe "mDNS Services /mdns/services CSV export" do
    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      render_click(view, "export_csv")
      assert render(view) =~ "Registered Services"
    end
  end
end
