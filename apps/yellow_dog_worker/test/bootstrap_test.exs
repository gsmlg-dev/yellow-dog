defmodule YellowDog.Worker.BootstrapTest do
  use ExUnit.Case, async: true
  alias YellowDog.Worker.Bootstrap
  @moduletag :tmp_dir
  @token String.duplicate("a", 43)

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
          "http://example.com",
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
