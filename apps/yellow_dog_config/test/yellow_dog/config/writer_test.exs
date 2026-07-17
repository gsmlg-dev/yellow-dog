defmodule YellowDog.Config.WriterTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Schema
  alias YellowDog.Config.TomlHelpers
  alias YellowDog.Config.Writer

  test "encode_config validates and encodes without owning file installation" do
    config = put_in(Schema.defaults(), ["dns", "port"], 5353)

    assert {:ok, contents} = Writer.encode_config(config, header: nil)
    assert {:ok, decoded} = TomlHelpers.parse_toml(contents)
    assert get_in(decoded, ["dns", "port"]) == 5353
  end

  test "encode_config returns bounded validation data for invalid maps" do
    config = put_in(Schema.defaults(), ["dns", "port"], 70_000)

    assert {:error, {:validation_failed, [{"dns.port", message}]}} =
             Writer.encode_config(config, header: nil)

    assert message == "must be between 1 and 65535, got 70000"
  end
end
