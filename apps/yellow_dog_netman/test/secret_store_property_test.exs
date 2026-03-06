defmodule YellowDog.Netman.SecretStorePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.SecretStore

  property "get always returns {:error, :not_found} for any key (stub)" do
    check all(key <- StreamData.string(:printable, max_length: 64)) do
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put always returns :ok for any key and value" do
    check all(
            key <- StreamData.string(:printable, max_length: 64),
            value <- StreamData.string(:printable, max_length: 256)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "delete always returns :ok for any key" do
    check all(key <- StreamData.string(:printable, max_length: 64)) do
      assert SecretStore.delete(key) == :ok
    end
  end

  property "delete is idempotent — double delete always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert SecretStore.delete(key) == :ok
      assert SecretStore.delete(key) == :ok
    end
  end

  property "put then get still returns :not_found (stub never persists)" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      SecretStore.put(key, value)
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end
end
