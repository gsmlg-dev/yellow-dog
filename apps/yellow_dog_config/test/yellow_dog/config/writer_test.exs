defmodule YellowDog.Config.WriterTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Writer

  test "encode_config returns validated deterministic TOML without writing files" do
    directory =
      Path.join(System.tmp_dir!(), "yellow-dog-writer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    config = %{"dns" => %{"listen" => "192.0.2.1", "port" => 5353}}

    assert {:ok, encoded} = Writer.encode_config(config, header: "# Managed candidate")
    assert encoded == "# Managed candidate\n\n[dns]\nlisten = \"192.0.2.1\"\nport = 5353\n"
    assert File.ls!(directory) == []
  end

  test "encode_config uses Schema validation by default" do
    assert {:error, {:validation_failed, errors}} =
             Writer.encode_config(%{"dns" => %{"port" => 70_000}})

    assert {"dns.port", _message} = List.keyfind(errors, "dns.port", 0)
    assert {:error, :invalid} = Writer.encode_config(:not_a_map)
  end

  test "write_config writes exactly the content produced by encode_config" do
    path =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-writer-#{System.unique_integer([:positive])}/config.toml"
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    config = %{"core" => %{"dns" => true}, "dns" => %{"port" => 5353}}
    opts = [header: "# Exact"]

    assert {:ok, encoded} = Writer.encode_config(config, opts)
    assert :ok = Writer.write_config(path, config, opts)
    assert File.read!(path) == encoded
  end

  test "quotes dotted map keys so canonical documents round-trip" do
    config = %{
      "dns" => %{
        "zones" => %{
          "example.test" => %{"type" => "authoritative"}
        }
      }
    }

    assert {:ok, encoded} = Writer.encode_config(config, validate: false)
    assert encoded =~ ~s([dns.zones."example.test"])
    assert {:ok, ^config} = Toml.decode(encoded)
  end
end
