defmodule YellowDog.Management.RepoTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.Repo

  test "Ecto tasks use the runtime database URL while preserving the sandbox pool" do
    url = System.fetch_env!("YELLOW_DOG_MANAGEMENT_DATABASE_URL") |> URI.parse()
    config = Repo.config()

    assert config[:database] == String.trim_leading(url.path, "/")
    assert config[:username] == url.userinfo |> String.split(":") |> hd()
    assert config[:hostname] == url.host
    assert config[:port] == url.port
    assert config[:socket_dir] == URI.decode_query(url.query || "")["socket_dir"]
    assert config[:pool] == Ecto.Adapters.SQL.Sandbox
  end
end
