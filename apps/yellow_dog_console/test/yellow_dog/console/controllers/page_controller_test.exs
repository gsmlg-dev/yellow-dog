defmodule YellowDog.Console.PageControllerTest do
  use YellowDog.Console.ConnCase, async: true

  describe "GET /" do
    test "renders the home page", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ "Yellow"
      assert html_response(conn, 200) =~ "Service Dashboard"
    end

    test "allows bundled scripts and configured font hosts in CSP", %{conn: conn} do
      conn = get(conn, ~p"/")

      [content_security_policy] = get_resp_header(conn, "content-security-policy")

      assert content_security_policy =~ "script-src 'self'"
      refute content_security_policy =~ "script-src 'self' 'unsafe-inline'"
      assert content_security_policy =~ "https://fonts.googleapis.com"
      assert content_security_policy =~ "https://fonts.gstatic.com"
    end
  end
end
