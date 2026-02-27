defmodule YellowDog.Netman.SecretStoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.SecretStore

  test "get/1 returns {:error, :not_found} for any key" do
    assert SecretStore.get("wifi_password") == {:error, :not_found}
    assert SecretStore.get("802.1x_cert") == {:error, :not_found}
    assert SecretStore.get("") == {:error, :not_found}
  end

  test "put/2 returns :ok" do
    assert SecretStore.put("wifi_password", "secret123") == :ok
    assert SecretStore.put("", "") == :ok
  end

  test "delete/1 returns :ok" do
    assert SecretStore.delete("wifi_password") == :ok
    assert SecretStore.delete("nonexistent") == :ok
  end

  test "put then get still returns not_found (stub)" do
    SecretStore.put("key", "value")
    assert SecretStore.get("key") == {:error, :not_found}
  end
end
