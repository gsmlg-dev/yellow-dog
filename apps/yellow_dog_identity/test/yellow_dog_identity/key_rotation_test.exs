defmodule YellowDogIdentity.KeyRotationTest do
  @moduledoc """
  Tests for host key rotation via forced re-registration.

  Key rotation occurs when a host registers with the same hostname but a
  different SSH public key and `force: true`.  The old key is archived into
  `previous_keys` and the host record is updated in place (same ID).
  """

  use ExUnit.Case, async: false

  alias YellowDogIdentity.Host

  # Two structurally valid ed25519 keys with distinct key material
  @key_a "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g test@host"
  @key_b "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAMKERgfJi00O0JJUFdeZWxzeoGIj5adpKuyucDHztXc second@host"
  @age_recipient "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("yd_key_rotation_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)
    start_supervised!({YellowDogIdentity.Supervisor, data_dir: tmp_dir})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "key rotation — normal registration" do
    test "creates host with empty previous_keys" do
      params = %{hostname: "rotation-host", ssh_pubkey: @key_a, age_recipient: @age_recipient}

      assert {:ok, %Host{} = host} = YellowDogIdentity.register(params)
      assert host.previous_keys == []
      assert host.ssh_pubkey == @key_a
    end
  end

  describe "key rotation — idempotent re-registration" do
    test "same hostname + same key returns existing host" do
      params = %{hostname: "idem-host", ssh_pubkey: @key_a, age_recipient: @age_recipient}

      {:ok, original} = YellowDogIdentity.register(params)

      assert {:error, {:idempotent, existing}} = YellowDogIdentity.register(params)
      assert existing.id == original.id
      assert existing.key_fingerprint == original.key_fingerprint
    end
  end

  describe "key rotation — conflict without force" do
    test "same hostname + different key without force returns {:error, :conflict}" do
      params_a = %{hostname: "conflict-host", ssh_pubkey: @key_a, age_recipient: @age_recipient}
      {:ok, _} = YellowDogIdentity.register(params_a)

      params_b = %{hostname: "conflict-host", ssh_pubkey: @key_b, age_recipient: @age_recipient}
      assert {:error, :conflict} = YellowDogIdentity.register(params_b)
    end
  end

  describe "key rotation — forced re-registration" do
    test "same hostname + different key with force: true succeeds and archives old key" do
      params_a = %{hostname: "force-host", ssh_pubkey: @key_a, age_recipient: @age_recipient}
      {:ok, _host_a} = YellowDogIdentity.register(params_a)

      params_b = %{
        hostname: "force-host",
        ssh_pubkey: @key_b,
        age_recipient: @age_recipient,
        force: true
      }

      assert {:ok, %Host{} = host_b} = YellowDogIdentity.register(params_b)

      # New key material is in place
      assert host_b.ssh_pubkey == @key_b
      # Old key is archived
      assert length(host_b.previous_keys) == 1

      [archived] = host_b.previous_keys
      assert archived["ssh_pubkey"] == @key_a
    end

    test "host ID is preserved after forced re-registration" do
      params_a = %{hostname: "id-preserved", ssh_pubkey: @key_a, age_recipient: @age_recipient}
      {:ok, host_a} = YellowDogIdentity.register(params_a)

      params_b = %{
        hostname: "id-preserved",
        ssh_pubkey: @key_b,
        age_recipient: @age_recipient,
        force: true
      }

      {:ok, host_b} = YellowDogIdentity.register(params_b)

      assert host_b.id == host_a.id
    end

    test "previous key entry contains ssh_pubkey, key_fingerprint, and replaced_at" do
      params_a = %{hostname: "key-entry-host", ssh_pubkey: @key_a, age_recipient: @age_recipient}
      {:ok, host_a} = YellowDogIdentity.register(params_a)

      params_b = %{
        hostname: "key-entry-host",
        ssh_pubkey: @key_b,
        age_recipient: @age_recipient,
        force: true
      }

      {:ok, host_b} = YellowDogIdentity.register(params_b)

      assert [archived] = host_b.previous_keys
      assert archived["ssh_pubkey"] == @key_a
      assert archived["key_fingerprint"] == host_a.key_fingerprint
      assert is_binary(archived["replaced_at"])

      # Verify replaced_at is a valid ISO 8601 timestamp
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(archived["replaced_at"])
    end
  end
end
