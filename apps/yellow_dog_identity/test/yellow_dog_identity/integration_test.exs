defmodule YellowDogIdentity.IntegrationTest do
  @moduledoc """
  Integration tests for the full YellowDogIdentity registration flow.

  These tests exercise the public API (register/2, approve/2, revoke/3,
  export_recipients/1, stats/0) against a real Registry GenServer backed
  by a temp directory on disk.
  """

  use ExUnit.Case, async: false

  alias YellowDogIdentity.{Host, Registry}

  # Two distinct ed25519 keys for conflict/force tests
  @key_a "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 test@host"
  @key_b "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 alt@host"

  @age_a "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
  @age_b "age1zx8k5tqhrgms20yfyqce2mgyvhyxw83cxfnmkk34jz0ecaxjxxhs7n5vhu"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yd_identity_integration_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Stop the identity supervisor (which manages Registry) if running
    if sup = Process.whereis(YellowDogIdentity.Supervisor) do
      Supervisor.stop(sup)
    end

    # Stop any pre-existing registry (started by yellow_dog app)
    if pid = Process.whereis(YellowDogIdentity.Registry) do
      GenServer.stop(pid)
    end

    # Start the Registry under its default name so the public API functions work
    {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: YellowDogIdentity.Registry)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, registry: pid}
  end

  # ──────────────────────────────────────────────
  # 1. Register a new host
  # ──────────────────────────────────────────────

  describe "register/2 — new host" do
    test "returns {:ok, host} with status :pending when no trust providers match" do
      params = %{
        hostname: "node-01",
        ssh_pubkey: @key_a,
        age_recipient: @age_a
      }

      assert {:ok, %Host{} = host} = YellowDogIdentity.register(params)
      assert host.hostname == "node-01"
      assert host.ssh_pubkey == @key_a
      assert host.age_recipient == @age_a
      assert host.status == :pending
      assert host.trust_level == :unverified
      assert host.trust_provider == :none
      assert is_binary(host.id)
      assert is_binary(host.key_fingerprint)
      assert String.starts_with?(host.key_fingerprint, "SHA256:")
      assert %DateTime{} = host.created_at
    end

    test "persisted host can be retrieved by id" do
      params = %{hostname: "node-02", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)

      assert {:ok, fetched} = YellowDogIdentity.get_host(host.id)
      assert fetched.id == host.id
      assert fetched.hostname == host.hostname
    end

    test "host appears in list_hosts" do
      params = %{hostname: "node-03", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)

      hosts = YellowDogIdentity.list_hosts()
      assert Enum.any?(hosts, &(&1.id == host.id))
    end

    test "host appears in list_hosts filtered by :pending" do
      params = %{hostname: "node-04", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)

      pending = YellowDogIdentity.list_hosts(status: :pending)
      assert Enum.any?(pending, &(&1.id == host.id))

      approved = YellowDogIdentity.list_hosts(status: :approved)
      refute Enum.any?(approved, &(&1.id == host.id))
    end
  end

  # ──────────────────────────────────────────────
  # 2. Idempotent registration
  # ──────────────────────────────────────────────

  describe "register/2 — idempotent" do
    test "same key + same hostname returns {:error, {:idempotent, existing}}" do
      params = %{hostname: "idem-host", ssh_pubkey: @key_a, age_recipient: @age_a}

      {:ok, original} = YellowDogIdentity.register(params)

      assert {:error, {:idempotent, existing}} = YellowDogIdentity.register(params)
      assert existing.id == original.id
      assert existing.hostname == original.hostname
      assert existing.key_fingerprint == original.key_fingerprint
    end
  end

  # ──────────────────────────────────────────────
  # 3. Conflict detection
  # ──────────────────────────────────────────────

  describe "register/2 — conflict" do
    test "same hostname + different key without force returns {:error, :conflict}" do
      params_a = %{hostname: "conflict-host", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, _host_a} = YellowDogIdentity.register(params_a)

      params_b = %{hostname: "conflict-host", ssh_pubkey: @key_b, age_recipient: @age_b}
      assert {:error, :conflict} = YellowDogIdentity.register(params_b)
    end
  end

  # ──────────────────────────────────────────────
  # 4. Force re-registration
  # ──────────────────────────────────────────────

  describe "register/2 — force re-registration" do
    test "same hostname + different key with force: true archives old key" do
      params_a = %{hostname: "force-host", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host_a} = YellowDogIdentity.register(params_a)

      params_b = %{
        hostname: "force-host",
        ssh_pubkey: @key_b,
        age_recipient: @age_b,
        force: true
      }

      {:ok, host_b} = YellowDogIdentity.register(params_b)

      # The forced registration reuses the original host id
      assert host_b.id == host_a.id
      # New key material is in place
      assert host_b.ssh_pubkey == @key_b
      assert host_b.age_recipient == @age_b
      # Old key is archived in previous_keys
      assert length(host_b.previous_keys) == 1

      [archived] = host_b.previous_keys
      assert archived["ssh_pubkey"] == @key_a
      assert archived["key_fingerprint"] == host_a.key_fingerprint
      assert is_binary(archived["replaced_at"])

      # Only one host record exists for this hostname
      all = YellowDogIdentity.list_hosts()
      matching = Enum.filter(all, &(&1.hostname == "force-host"))
      assert length(matching) == 1
    end
  end

  # ──────────────────────────────────────────────
  # 5. Approve a pending host
  # ──────────────────────────────────────────────

  describe "approve/2" do
    test "changes status from :pending to :approved" do
      params = %{hostname: "approve-host", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)
      assert host.status == :pending

      assert {:ok, approved} = YellowDogIdentity.approve(host.id, "admin@test")
      assert approved.status == :approved
      assert approved.approved_by == "admin@test"
      assert %DateTime{} = approved.approved_at
    end

    test "approving a non-pending host returns an error" do
      params = %{hostname: "already-approved", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)
      {:ok, _} = YellowDogIdentity.approve(host.id)

      assert {:error, {:invalid_status, :approved}} = YellowDogIdentity.approve(host.id)
    end

    test "approving a nonexistent host returns :not_found" do
      assert {:error, :not_found} = YellowDogIdentity.approve("nonexistent-id")
    end
  end

  # ──────────────────────────────────────────────
  # 6. Revoke a host
  # ──────────────────────────────────────────────

  describe "revoke/3" do
    test "revokes an approved host" do
      params = %{hostname: "revoke-host", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)
      {:ok, _} = YellowDogIdentity.approve(host.id)

      assert {:ok, revoked} = YellowDogIdentity.revoke(host.id, "security@test", "compromised")
      assert revoked.status == :revoked
      assert revoked.revoked_by == "security@test"
      assert revoked.revoke_reason == "compromised"
      assert %DateTime{} = revoked.revoked_at
    end

    test "revokes a pending host" do
      params = %{hostname: "revoke-pending", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)

      assert {:ok, revoked} = YellowDogIdentity.revoke(host.id, "admin", "not needed")
      assert revoked.status == :revoked
    end

    test "revoking an already-revoked host returns :already_revoked" do
      params = %{hostname: "double-revoke", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)
      {:ok, _} = YellowDogIdentity.revoke(host.id, "admin")

      assert {:error, :already_revoked} = YellowDogIdentity.revoke(host.id, "admin")
    end

    test "revoking a nonexistent host returns :not_found" do
      assert {:error, :not_found} = YellowDogIdentity.revoke("missing", "admin")
    end
  end

  # ──────────────────────────────────────────────
  # 7. Export recipients (only approved hosts)
  # ──────────────────────────────────────────────

  describe "export_recipients/1" do
    test "only includes approved hosts" do
      # Register three hosts
      {:ok, h1} =
        YellowDogIdentity.register(%{
          hostname: "export-1",
          ssh_pubkey: @key_a,
          age_recipient: @age_a
        })

      {:ok, _h2} =
        YellowDogIdentity.register(%{
          hostname: "export-2",
          ssh_pubkey: @key_b,
          age_recipient: @age_b
        })

      # Approve only the first
      {:ok, _} = YellowDogIdentity.approve(h1.id)

      yaml = YellowDogIdentity.export_recipients()
      assert yaml =~ @age_a
      refute yaml =~ @age_b
    end

    test "returns empty list marker when no approved hosts exist" do
      {:ok, _} =
        YellowDogIdentity.register(%{
          hostname: "pending-only",
          ssh_pubkey: @key_a,
          age_recipient: @age_a
        })

      yaml = YellowDogIdentity.export_recipients()
      assert yaml =~ "age: []"
    end

    test "sops format includes creation_rules" do
      {:ok, h} =
        YellowDogIdentity.register(%{
          hostname: "sops-host",
          ssh_pubkey: @key_a,
          age_recipient: @age_a
        })

      {:ok, _} = YellowDogIdentity.approve(h.id)

      sops = YellowDogIdentity.export_recipients(format: :sops)
      assert sops =~ "creation_rules:"
      assert sops =~ @age_a
    end
  end

  # ──────────────────────────────────────────────
  # 8. Stats
  # ──────────────────────────────────────────────

  describe "stats/0" do
    test "returns correct counts" do
      # Register 3 hosts with distinct keys
      {:ok, h1} =
        YellowDogIdentity.register(%{
          hostname: "stats-1",
          ssh_pubkey: @key_a,
          age_recipient: @age_a
        })

      {:ok, h2} =
        YellowDogIdentity.register(%{
          hostname: "stats-2",
          ssh_pubkey: @key_b,
          age_recipient: @age_b
        })

      # Approve one, revoke another, leave third pending
      # We only have 2 keys, so register a third host with key_a on a different hostname
      # (same key, different hostname is allowed)
      # Actually key_a is already used for stats-1 which will trigger idempotent check
      # via fingerprint. The duplicate check allows same key+different hostname.
      # Let's just work with 2 hosts:
      {:ok, _} = YellowDogIdentity.approve(h1.id)
      {:ok, _} = YellowDogIdentity.revoke(h2.id, "admin")

      stats = YellowDogIdentity.stats()

      assert stats.total == 2
      assert stats.approved == 1
      assert stats.revoked == 1
      assert stats.pending == 0
      assert is_map(stats.trust_levels)
      assert Map.get(stats.trust_levels, "unverified") == 2
    end

    test "returns zeroes when registry is empty" do
      stats = YellowDogIdentity.stats()

      assert stats.total == 0
      assert stats.pending == 0
      assert stats.approved == 0
      assert stats.revoked == 0
    end
  end

  # ──────────────────────────────────────────────
  # 9. Audit log
  # ──────────────────────────────────────────────

  describe "audit log" do
    test "audit log is written on register, approve, and revoke", %{tmp_dir: tmp_dir} do
      params = %{hostname: "audit-host", ssh_pubkey: @key_a, age_recipient: @age_a}
      {:ok, host} = YellowDogIdentity.register(params)

      {:ok, _} = YellowDogIdentity.approve(host.id)
      {:ok, _} = YellowDogIdentity.revoke(host.id, "admin", "decomm")

      # audit log is written via GenServer.cast — give it a moment to flush
      :sys.get_state(YellowDogIdentity.Registry)

      audit_path = Path.join(tmp_dir, "audit.log")
      assert File.exists?(audit_path)

      content = File.read!(audit_path)

      assert content =~ "host.registered"
      assert content =~ "host.approved"
      assert content =~ "host.revoked"
      assert content =~ host.id
    end
  end

  # ──────────────────────────────────────────────
  # host_status/1 convenience check
  # ──────────────────────────────────────────────

  describe "host_status/1" do
    test "returns status map for existing host" do
      {:ok, host} =
        YellowDogIdentity.register(%{
          hostname: "status-host",
          ssh_pubkey: @key_a,
          age_recipient: @age_a
        })

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert status_map.id == host.id
      assert status_map.hostname == "status-host"
      assert status_map.status == :pending
      assert status_map.trust_level == :unverified
    end

    test "returns :not_found for missing host" do
      assert :not_found = YellowDogIdentity.host_status("no-such-host")
    end
  end
end
