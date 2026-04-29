defmodule YellowDog.Console.CodeReloaderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.CodeReloader

  test "reload is a no-op when Phoenix code reloader server is not running" do
    assert :ok = CodeReloader.reload(YellowDog.Console.Endpoint, [], :missing_code_reloader)
  end

  test "phoenix code reloader plug does not crash when server is not running" do
    conn =
      :get
      |> Plug.Test.conn("/system/backups")
      |> Plug.Conn.put_private(:phoenix_endpoint, YellowDog.Console.Endpoint)

    opts =
      Phoenix.CodeReloader.init(reloader: &CodeReloader.reload(&1, &2, :missing_code_reloader))

    assert %Plug.Conn{halted: false} = Phoenix.CodeReloader.call(conn, opts)
  end
end
