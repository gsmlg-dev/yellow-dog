defmodule YellowDog.Console.CloudDnsLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Provider

  setup do
    previous_backend = Backend.active()

    Backend.set_active(EtsBackend)
    EtsBackend.create_table()
    :ets.delete_all_objects(EtsBackend.table())

    on_exit(fn ->
      :ets.delete_all_objects(EtsBackend.table())
      Backend.set_active(previous_backend)
    end)

    :ok
  end

  describe "System Provider Cloud DNS" do
    test "sidebar exposes Cloud DNS under provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/provider/cloud-dns")

      assert has_element?(view, "a[href='/system/provider/cloud-dns']", "Cloud DNS")
    end

    test "renders connector list with add action", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/provider/cloud-dns")

      assert html =~ "Cloud DNS"
      assert html =~ "Connectors"
      assert html =~ "Add Cloud DNS"
      refute html =~ "API Token"
      refute html =~ "Access Key ID"
    end

    test "opens add connector modal with Cloudflare fields by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/provider/cloud-dns")

      html = render_click(view, "open_add_connector")

      assert html =~ ~s(id="cloud-dns-modal")
      assert html =~ "Add Cloud DNS"
      assert html =~ "Provider"
      assert html =~ "Cloudflare DNS"
      assert html =~ "AWS Route 53"
      assert html =~ "API Token"
      refute html =~ "Access Key ID"
    end

    test "provider selection switches modal fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/provider/cloud-dns")
      render_click(view, "open_add_connector")

      html =
        view
        |> form("#cloud-dns-form", %{
          "connector" => %{
            "provider" => "route53",
            "name" => "aws-test",
            "enabled" => "true"
          }
        })
        |> render_change()

      assert html =~ "Access Key ID"
      assert html =~ "Secret Access Key"
      assert html =~ "Region"
      refute html =~ "API Token"
    end

    test "saves Cloudflare and Route 53 connectors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/provider/cloud-dns")
      render_click(view, "open_add_connector")

      cloudflare_html =
        view
        |> form("#cloud-dns-form", %{
          "connector" => %{
            "provider" => "cloudflare",
            "name" => "cf-test",
            "api_token" => "cf-token",
            "account_id" => "account-1",
            "enabled" => "true"
          }
        })
        |> render_submit()

      assert cloudflare_html =~ "cf-test"

      assert {:ok,
              %{
                type: :cloudflare,
                credentials: %{api_token: "cf-token", account_id: "account-1"}
              }} = Provider.get_config("cf-test")

      render_click(view, "open_add_connector")

      view
      |> form("#cloud-dns-form", %{
        "connector" => %{
          "provider" => "route53",
          "name" => "aws-test",
          "enabled" => "true"
        }
      })
      |> render_change()

      route53_html =
        view
        |> form("#cloud-dns-form", %{
          "connector" => %{
            "provider" => "route53",
            "name" => "aws-test",
            "access_key_id" => "AKIA_TEST",
            "secret_access_key" => "route53-secret",
            "region" => "us-east-1",
            "enabled" => "true"
          }
        })
        |> render_submit()

      assert route53_html =~ "aws-test"

      assert {:ok,
              %{
                type: :route53,
                credentials: %{
                  access_key_id: "AKIA_TEST",
                  secret_access_key: "route53-secret",
                  region: "us-east-1"
                }
              }} = Provider.get_config("aws-test")
    end
  end
end
