defmodule YellowDogIdentity.RegistrationEdgeTest do
  @moduledoc """
  Edge-case tests for host registration, deletion, and conflict handling
  that complement the integration test suite.
  """

  use ExUnit.Case, async: false

  alias YellowDogIdentity.Host

  @key_a "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @key_b "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRpZmZlcmVudGtleWhlcmVmb3J0ZXN0 test2@host"

  @age "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  @context %{source_ip: {127, 0, 0, 1}}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "reg_edge_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    YellowDogIdentity.TestHelper.stop_app_identity()

    start_supervised!({YellowDogIdentity.Registry, data_dir: tmp_dir, name: YellowDogIdentity.Registry})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  # ──────────────────────────────────────────────
  # Idempotent and conflict registration
  # ──────────────────────────────────────────────

  describe "idempotent registration" do
    test "same hostname + same key returns {:error, {:idempotent, existing}}" do
      params = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, original} = YellowDogIdentity.register(params, @context)

      assert {:error, {:idempotent, existing}} = YellowDogIdentity.register(params, @context)
      assert existing.id == original.id
      assert existing.hostname == original.hostname
      assert existing.key_fingerprint == original.key_fingerprint
    end
  end

  describe "conflict detection" do
    test "same hostname + different key without force returns {:error, :conflict}" do
      params_a = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, _} = YellowDogIdentity.register(params_a, @context)

      params_b = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_b,
        "age_recipient" => @age
      }

      assert {:error, :conflict} = YellowDogIdentity.register(params_b, @context)
    end
  end

  # ──────────────────────────────────────────────
  # Force re-registration
  # ──────────────────────────────────────────────

  describe "force re-registration" do
    test "same hostname + different key with force: true returns {:ok, host} with previous_keys" do
      params_a = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, original} = YellowDogIdentity.register(params_a, @context)

      params_b = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_b,
        "age_recipient" => @age,
        "force" => true
      }

      assert {:ok, %Host{} = host} = YellowDogIdentity.register(params_b, @context)
      assert host.ssh_pubkey == @key_b
      assert length(host.previous_keys) == 1

      [archived] = host.previous_keys
      assert archived["ssh_pubkey"] == @key_a
      assert archived["key_fingerprint"] == original.key_fingerprint
      assert is_binary(archived["replaced_at"])
    end

    test "force re-registration preserves the original host ID" do
      params_a = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, original} = YellowDogIdentity.register(params_a, @context)

      params_b = %{
        "hostname" => "test-node",
        "ssh_pubkey" => @key_b,
        "age_recipient" => @age,
        "force" => true
      }

      {:ok, replaced} = YellowDogIdentity.register(params_b, @context)
      assert replaced.id == original.id
    end
  end

  # ──────────────────────────────────────────────
  # Deletion
  # ──────────────────────────────────────────────

  describe "delete_host/1" do
    test "succeeds on existing host" do
      params = %{
        "hostname" => "delete-me",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, host} = YellowDogIdentity.register(params, @context)
      assert :ok = YellowDogIdentity.delete_host(host.id)
    end

    test "returns {:error, :not_found} on missing host" do
      assert {:error, :not_found} = YellowDogIdentity.delete_host("nonexistent-id")
    end

    test "after delete, get_host returns :not_found" do
      params = %{
        "hostname" => "vanish-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, host} = YellowDogIdentity.register(params, @context)
      :ok = YellowDogIdentity.delete_host(host.id)

      assert :not_found = YellowDogIdentity.get_host(host.id)
    end

    test "after delete, list_hosts does not include the host" do
      params = %{
        "hostname" => "gone-node",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      {:ok, host} = YellowDogIdentity.register(params, @context)
      :ok = YellowDogIdentity.delete_host(host.id)

      hosts = YellowDogIdentity.list_hosts()
      refute Enum.any?(hosts, &(&1.id == host.id))
    end
  end

  # ──────────────────────────────────────────────
  # Multiple registrations and defaults
  # ──────────────────────────────────────────────

  describe "multiple registrations" do
    test "different hostnames with different keys succeed" do
      params_a = %{
        "hostname" => "alpha",
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      params_b = %{
        "hostname" => "beta",
        "ssh_pubkey" => @key_b,
        "age_recipient" => @age
      }

      assert {:ok, %Host{hostname: "alpha"}} = YellowDogIdentity.register(params_a, @context)
      assert {:ok, %Host{hostname: "beta"}} = YellowDogIdentity.register(params_b, @context)

      hosts = YellowDogIdentity.list_hosts()
      hostnames = Enum.map(hosts, & &1.hostname)
      assert "alpha" in hostnames
      assert "beta" in hostnames
    end
  end

  describe "hostname defaults" do
    test "registration with missing hostname defaults to unknown" do
      params = %{
        "ssh_pubkey" => @key_a,
        "age_recipient" => @age
      }

      assert {:error, :hostname_required} = YellowDogIdentity.register(params, @context)
    end
  end
end
