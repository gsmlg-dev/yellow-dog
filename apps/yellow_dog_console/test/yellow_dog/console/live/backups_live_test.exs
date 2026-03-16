defmodule YellowDog.Console.BackupsLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "BackupsLive mount" do
    test "successfully mounts and renders page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system/backups")
      assert html =~ "Backups"
      assert html =~ "Create Backup"
      assert html =~ "Available Backups"
    end

    test "shows empty state when no backups exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system/backups")
      assert html =~ "No backups found"
    end
  end

  describe "BackupsLive events" do
    test "refresh reloads backup list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system/backups")
      html = render_click(view, "refresh")
      assert html =~ "Available Backups"
    end

    test "update_label changes the label assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system/backups")
      render_change(view, "update_label", %{"label" => "nightly"})
      html = render(view)
      assert html =~ "nightly"
    end
  end
end
