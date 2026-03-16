defmodule YellowDog.Store.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.Config

  @moduletag :store_integration

  setup do
    YellowDog.StoreHelper.setup_store()
    start_supervised!(YellowDog.Store.EventBridge)
    :ok
  end

  test "put and get a config value" do
    assert :ok = Config.put(:dns, :port, 5353)

    result = Config.get(:dns, :port)
    assert result == 5353
  end

  test "get returns default when key not found" do
    result = Config.get(:dns, :nonexistent_key, 42)
    assert result == 42
  end

  test "get returns nil default when key not found" do
    result = Config.get(:dns, :nonexistent_key)
    assert result == nil
  end

  test "put overwrites existing value" do
    Config.put(:dns, :timeout, 1000)
    Config.put(:dns, :timeout, 2000)

    assert Config.get(:dns, :timeout) == 2000
  end

  test "list returns all config keys for a service" do
    Config.put(:dhcpv4, :pool_size, 100)
    Config.put(:dhcpv4, :lease_time, 3600)

    {:ok, entries} = Config.list(:dhcpv4)
    assert is_list(entries)
    assert length(entries) >= 2
  end

  test "delete removes config override" do
    Config.put(:mdns, :enabled, true)
    assert :ok = Config.delete(:mdns, :enabled)

    result = Config.get(:mdns, :enabled, :default_val)
    assert result == :default_val
  end

  test "config values can be any Elixir term" do
    Config.put(:test, :map_val, %{nested: %{key: "value"}})
    assert Config.get(:test, :map_val) == %{nested: %{key: "value"}}

    Config.put(:test, :list_val, [1, 2, 3])
    assert Config.get(:test, :list_val) == [1, 2, 3]

    Config.put(:test, :tuple_val, {:ok, "data"})
    assert Config.get(:test, :tuple_val) == {:ok, "data"}
  end
end
