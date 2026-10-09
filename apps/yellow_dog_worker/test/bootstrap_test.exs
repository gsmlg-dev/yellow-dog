defmodule YellowDog.Worker.BootstrapTest do
  use ExUnit.Case, async: false
  alias YellowDog.Worker.Bootstrap
  @moduletag :tmp_dir
  @token String.duplicate("a", 43)

  test "default state directory uses systemd then XDG", %{tmp_dir: dir} do
    previous = Map.new(~w(STATE_DIRECTORY XDG_STATE_HOME), &{&1, System.get_env(&1)})

    try do
      System.put_env("STATE_DIRECTORY", Path.join(dir, "systemd"))
      System.put_env("XDG_STATE_HOME", Path.join(dir, "xdg"))
      path = write(dir, "management_url = \"http://10.8.0.1\"\n")
      assert {:ok, options} = Bootstrap.load(path)
      assert options[:data_dir] == Path.join(dir, "systemd")
      System.delete_env("STATE_DIRECTORY")
      assert {:ok, options} = Bootstrap.load(path)
      assert options[:data_dir] == Path.join([dir, "xdg", "yellow-dog-worker"])
      System.delete_env("XDG_STATE_HOME")
      assert {:ok, options} = Bootstrap.load(path)

      assert options[:data_dir] ==
               Path.join(System.user_home!(), ".local/state/yellow-dog-worker")
    after
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end
  end

  test "URL-only bootstrap accepts VPN HTTP and paired credentials", %{tmp_dir: dir} do
    assert {:ok, options} =
             Bootstrap.load(write(dir, "management_url = \"http://10.8.0.1:4270\"\n"))

    assert options[:source] == nil
    refute options[:worker_id]
    assert Path.type(options[:data_dir]) == :absolute

    assert {:ok, options} =
             Bootstrap.load(
               write(
                 dir,
                 "management_url = \"https://management.example\"\ndata_dir = \"state\"\n"
               )
             )

    assert options[:data_dir] == Path.join(dir, "state")

    for extra <- ["worker_id = \"edge-01\"\n", "token = \"#{@token}\"\n"] do
      assert {:error, :invalid_bootstrap} =
               Bootstrap.load(write(dir, "management_url = \"http://10.8.0.1:4270\"\n" <> extra))
    end
  end

  test "original local mode remains exact and resolves machine-local files", %{tmp_dir: dir} do
    path = write(dir, "worker_id = \"edge-01\"\ndata_dir = \"state\"\nsource = \"plan.toml\"\n")
    assert {:ok, options} = Bootstrap.load(path)
    assert options[:source] == Path.join(dir, "plan.toml")
    refute options[:connection]
    File.write!(path, File.read!(path) <> "token = \"#{@token}\"\n")
    assert {:error, :invalid_bootstrap} = Bootstrap.load(path)
  end

  test "managed mode needs only generated identity and connection config", %{tmp_dir: dir} do
    assert {:ok, options} = Bootstrap.load(write(dir, managed()))
    assert options[:source] == nil
    assert options[:connection][:poll_interval_ms] == 10_000
    assert options[:connection][:token] == @token
    assert options[:data_dir] == Path.join(dir, "state")
    assert {:ok, bounded} = Bootstrap.load(write(dir, managed() <> "poll_interval_ms = 15000\n"))
    assert bounded[:connection][:poll_interval_ms] == 15_000
  end

  test "credentials origins intervals and optional TLS paths are validated without leaking secrets",
       %{tmp_dir: dir} do
    for extra <- [
          "source = \"plan.toml\"\n",
          "poll_interval_ms = 1\n",
          "poll_interval_ms = 60000\n",
          "extra = true\n",
          "tls_cert_file = \"client.pem\"\n",
          "tls_ca_file = \"missing.pem\"\n"
        ] do
      assert {:error, :invalid_bootstrap} = Bootstrap.load(write(dir, managed() <> extra))
    end

    for url <- [
          "https://user:password@example.com",
          "https://example.com/path",
          "https://example.com?token=secret",
          "https://example.com#fragment"
        ] do
      assert {:error, :invalid_bootstrap} = Bootstrap.load(write(dir, managed(url)))
    end

    assert {:error, :invalid_bootstrap} =
             Bootstrap.load(write(dir, String.replace(managed(), @token, "short")))

    assert {:error, :invalid_bootstrap} =
             Bootstrap.load(write(dir, String.replace(managed(), "token =", "other =")))

    for file <- ~w(ca.pem client.pem client.key), do: File.write!(Path.join(dir, file), "test")

    text =
      managed() <>
        "tls_ca_file = \"ca.pem\"\ntls_cert_file = \"client.pem\"\ntls_key_file = \"client.key\"\n"

    assert {:ok, options} = Bootstrap.load(write(dir, text))
    assert options[:connection][:tls_key_file] == Path.join(dir, "client.key")
    assert {:ok, _} = Bootstrap.load(write(dir, managed("http://127.0.0.1:1234")))
  end

  defp managed(url \\ "https://yellow-dog.example"),
    do:
      "worker_id = \"edge-01\"\ndata_dir = \"state\"\nmanagement_url = \"#{url}\"\ntoken = \"#{@token}\"\n"

  defp write(dir, text) do
    path = Path.join(dir, "bootstrap.toml")
    File.write!(path, text)
    path
  end
end
