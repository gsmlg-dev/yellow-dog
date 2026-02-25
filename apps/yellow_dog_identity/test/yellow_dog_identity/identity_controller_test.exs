defmodule YellowDogIdentity.IdentityControllerTest do
  @moduledoc """
  Tests for the YellowDogIdentity public API functions exercised by the
  IdentityController. Uses direct Registry.put_host/1 with Host.new/1 to
  set up state, focusing on edge cases around approve, revoke, host_status,
  stats, list_hosts, and token lifecycle.
  """

  use ExUnit.Case, async: false

  alias YellowDogIdentity.{Host, Registry, Token}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @valid_age_recipient "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  @alt_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 alt@host"
  @alt_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "api_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    start_supervised!({YellowDogIdentity.Registry, data_dir: tmp_dir, name: YellowDogIdentity.Registry})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp create_host!(hostname, opts \\ []) do
    ssh_pubkey = Keyword.get(opts, :ssh_pubkey, @valid_ssh_pubkey)
    age_recipient = Keyword.get(opts, :age_recipient, @valid_age_recipient)

    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: ssh_pubkey,
        age_recipient: age_recipient
      })

    :ok = Registry.put_host(host)
    host
  end

  defp make_approved!(hostname, opts \\ []) do
    host = create_host!(hostname, opts)
    approved = %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "setup"}
    :ok = Registry.put_host(approved)
    approved
  end

  defp make_revoked!(hostname, opts \\ []) do
    host = create_host!(hostname, opts)

    revoked = %{
      host
      | status: :revoked,
        revoked_at: DateTime.utc_now(),
        revoked_by: "setup",
        revoke_reason: "test setup"
    }

    :ok = Registry.put_host(revoked)
    revoked
  end

  # ──────────────────────────────────────────────
  # approve/2
  # ──────────────────────────────────────────────

  describe "approve/2" do
    test "approving a non-existent host returns {:error, :not_found}" do
      assert {:error, :not_found} = YellowDogIdentity.approve("nonexistent-id-12345")
    end

    test "approving a revoked host returns {:error, {:invalid_status, :revoked}}" do
      host = make_revoked!("revoked-for-approve")
      assert {:error, {:invalid_status, :revoked}} = YellowDogIdentity.approve(host.id)
    end

    test "approving an already-approved host returns {:error, {:invalid_status, :approved}}" do
      host = make_approved!("already-approved")
      assert {:error, {:invalid_status, :approved}} = YellowDogIdentity.approve(host.id)
    end

    test "successful approve sets approved_by field" do
      host = create_host!("pending-to-approve")
      assert host.status == :pending

      assert {:ok, approved} = YellowDogIdentity.approve(host.id, "admin@ops")
      assert approved.status == :approved
      assert approved.approved_by == "admin@ops"
      assert %DateTime{} = approved.approved_at
    end

    test "approve with default approved_by uses 'manual'" do
      host = create_host!("default-approver")
      assert {:ok, approved} = YellowDogIdentity.approve(host.id)
      assert approved.approved_by == "manual"
    end

    test "approved host is persisted in the registry" do
      host = create_host!("persist-approve")
      {:ok, _} = YellowDogIdentity.approve(host.id, "ci-bot")

      assert {:ok, fetched} = Registry.get_host(host.id)
      assert fetched.status == :approved
      assert fetched.approved_by == "ci-bot"
    end
  end

  # ──────────────────────────────────────────────
  # revoke/3
  # ──────────────────────────────────────────────

  describe "revoke/3" do
    test "revoking a non-existent host returns {:error, :not_found}" do
      assert {:error, :not_found} = YellowDogIdentity.revoke("missing-host-xyz", "admin")
    end

    test "revoking an already-revoked host returns {:error, :already_revoked}" do
      host = make_revoked!("double-revoke")
      assert {:error, :already_revoked} = YellowDogIdentity.revoke(host.id, "admin")
    end

    test "successful revoke sets revoked_by and revoke_reason" do
      host = make_approved!("approved-to-revoke")

      assert {:ok, revoked} = YellowDogIdentity.revoke(host.id, "sec-team", "key compromise")
      assert revoked.status == :revoked
      assert revoked.revoked_by == "sec-team"
      assert revoked.revoke_reason == "key compromise"
      assert %DateTime{} = revoked.revoked_at
    end

    test "revoke uses default reason when not provided" do
      host = make_approved!("default-reason-revoke",
        ssh_pubkey: @alt_ssh_pubkey,
        age_recipient: @alt_age_recipient
      )

      assert {:ok, revoked} = YellowDogIdentity.revoke(host.id, "admin")
      assert revoked.revoke_reason == "manual revocation"
    end

    test "can revoke a pending host" do
      host = create_host!("pending-to-revoke")
      assert host.status == :pending

      assert {:ok, revoked} = YellowDogIdentity.revoke(host.id, "admin", "rejected")
      assert revoked.status == :revoked
      assert revoked.revoked_by == "admin"
      assert revoked.revoke_reason == "rejected"
    end

    test "revoked host is persisted in the registry" do
      host = make_approved!("persist-revoke",
        ssh_pubkey: @alt_ssh_pubkey,
        age_recipient: @alt_age_recipient
      )

      {:ok, _} = YellowDogIdentity.revoke(host.id, "ops", "decommissioned")

      assert {:ok, fetched} = Registry.get_host(host.id)
      assert fetched.status == :revoked
      assert fetched.revoked_by == "ops"
      assert fetched.revoke_reason == "decommissioned"
    end
  end

  # ──────────────────────────────────────────────
  # host_status/1
  # ──────────────────────────────────────────────

  describe "host_status/1" do
    test "returns {:ok, map} for existing host" do
      host = create_host!("status-check")

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert is_map(status_map)
    end

    test "returns :not_found for missing host" do
      assert :not_found = YellowDogIdentity.host_status("does-not-exist-#{System.unique_integer()}")
    end

    test "map contains id, hostname, status, trust_level" do
      host = create_host!("status-fields")

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert status_map.id == host.id
      assert status_map.hostname == "status-fields"
      assert status_map.status == :pending
      assert status_map.trust_level == :unverified
    end

    test "map contains all expected keys" do
      host = create_host!("exact-keys")

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      expected_keys = [:approved_at, :hostname, :id, :key_fingerprint, :revoke_reason, :revoked_at, :status, :trust_level, :trust_provider]
      assert Enum.sort(Map.keys(status_map)) == expected_keys
    end

    test "reflects updated status after approval" do
      host = create_host!("status-after-approve")
      {:ok, _} = YellowDogIdentity.approve(host.id)

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert status_map.status == :approved
    end

    test "reflects updated status after revocation" do
      host = make_approved!("status-after-revoke")
      {:ok, _} = YellowDogIdentity.revoke(host.id, "admin")

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert status_map.status == :revoked
    end
  end

  # ──────────────────────────────────────────────
  # stats/0
  # ──────────────────────────────────────────────

  describe "stats/0" do
    test "returns correct counts for mixed statuses" do
      # Create hosts in each status
      host1 = create_host!("stats-pending-1")
      host2 = create_host!("stats-pending-2", ssh_pubkey: @alt_ssh_pubkey, age_recipient: @alt_age_recipient)

      # Approve one of them
      {:ok, _} = YellowDogIdentity.approve(host1.id, "admin")

      # Revoke the other
      {:ok, _} = YellowDogIdentity.revoke(host2.id, "admin", "unwanted")

      # Add a third that stays pending
      _pending3 = create_host!("stats-pending-3",
        ssh_pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 third@host",
        age_recipient: "age1zx8k5tqhrgms20yfyqce2mgyvhyxw83cxfnmkk34jz0ecaxjxxhs7n5vhu"
      )

      stats = YellowDogIdentity.stats()

      assert stats.total == 3
      assert stats.pending == 1
      assert stats.approved == 1
      assert stats.revoked == 1
      assert is_map(stats.trust_levels)
      assert Map.get(stats.trust_levels, "unverified") == 3
    end

    test "returns zeroes when registry is empty" do
      stats = YellowDogIdentity.stats()

      assert stats.total == 0
      assert stats.pending == 0
      assert stats.approved == 0
      assert stats.revoked == 0
      assert stats.trust_levels == %{}
    end

    test "trust_levels keys are strings" do
      _host = create_host!("trust-string-check")
      stats = YellowDogIdentity.stats()

      assert is_map(stats.trust_levels)
      Enum.each(stats.trust_levels, fn {k, _v} -> assert is_binary(k) end)
    end
  end

  # ──────────────────────────────────────────────
  # list_hosts/1
  # ──────────────────────────────────────────────

  describe "list_hosts/1" do
    test "no filter returns all hosts" do
      _h1 = create_host!("list-all-1")
      _h2 = create_host!("list-all-2", ssh_pubkey: @alt_ssh_pubkey, age_recipient: @alt_age_recipient)

      hosts = YellowDogIdentity.list_hosts()
      assert length(hosts) == 2
    end

    test "status filter returns only matching hosts" do
      h1 = create_host!("list-filter-1")
      _h2 = create_host!("list-filter-2", ssh_pubkey: @alt_ssh_pubkey, age_recipient: @alt_age_recipient)

      {:ok, _} = YellowDogIdentity.approve(h1.id)

      approved = YellowDogIdentity.list_hosts(status: :approved)
      pending = YellowDogIdentity.list_hosts(status: :pending)

      assert length(approved) == 1
      assert length(pending) == 1
      assert hd(approved).id == h1.id
    end

    test "status filter returns empty list when no hosts match" do
      _h1 = create_host!("list-empty-match")

      assert YellowDogIdentity.list_hosts(status: :approved) == []
      assert YellowDogIdentity.list_hosts(status: :revoked) == []
    end

    test "list_hosts returns empty list when registry is empty" do
      assert YellowDogIdentity.list_hosts() == []
    end

    test "revoked hosts appear under :revoked filter" do
      host = create_host!("list-revoked")
      {:ok, _} = YellowDogIdentity.revoke(host.id, "admin")

      revoked = YellowDogIdentity.list_hosts(status: :revoked)
      assert length(revoked) == 1
      assert hd(revoked).status == :revoked
    end
  end

  # ──────────────────────────────────────────────
  # create_token/1, list_tokens/0, revoke_token/1
  # ──────────────────────────────────────────────

  describe "create_token/1 and list_tokens/0" do
    test "create and list tokens" do
      assert YellowDogIdentity.list_tokens() == []

      params = %{
        hostname_pattern: "web-*",
        max_uses: 3,
        created_by: "test-admin",
        ttl_seconds: 3600
      }

      assert {:ok, %Token{} = token, raw_token} = YellowDogIdentity.create_token(params)
      assert is_binary(token.id)
      assert is_binary(raw_token)
      assert token.hostname_pattern == "web-*"
      assert token.max_uses == 3
      assert token.created_by == "test-admin"
      assert token.use_count == 0

      tokens = YellowDogIdentity.list_tokens()
      assert length(tokens) == 1
      assert hd(tokens).id == token.id
    end

    test "multiple tokens are listed" do
      {:ok, t1, _} = YellowDogIdentity.create_token(%{hostname_pattern: "a-*", created_by: "admin"})
      {:ok, t2, _} = YellowDogIdentity.create_token(%{hostname_pattern: "b-*", created_by: "admin"})
      {:ok, t3, _} = YellowDogIdentity.create_token(%{hostname_pattern: "c-*", created_by: "admin"})

      tokens = YellowDogIdentity.list_tokens()
      ids = Enum.map(tokens, & &1.id) |> Enum.sort()

      assert length(tokens) == 3
      assert Enum.sort([t1.id, t2.id, t3.id]) == ids
    end

    test "raw token differs from token hash" do
      {:ok, token, raw_token} = YellowDogIdentity.create_token(%{created_by: "admin"})
      refute raw_token == token.token_hash
      assert byte_size(raw_token) > 0
      assert byte_size(token.token_hash) > 0
    end

    test "create_token uses defaults for optional fields" do
      {:ok, token, _} = YellowDogIdentity.create_token(%{})
      assert token.hostname_pattern == "*"
      assert token.max_uses == 1
      assert token.created_by == "system"
      assert is_nil(token.role)
    end
  end

  describe "revoke_token/1" do
    test "revoke_token removes token from list" do
      {:ok, token, _} = YellowDogIdentity.create_token(%{hostname_pattern: "*", created_by: "admin"})
      assert length(YellowDogIdentity.list_tokens()) == 1

      assert :ok = YellowDogIdentity.revoke_token(token.id)
      assert YellowDogIdentity.list_tokens() == []
    end

    test "revoke_token on nonexistent id returns not_found error" do
      assert {:error, :not_found} = YellowDogIdentity.revoke_token("nonexistent-token-id")
    end

    test "revoking one token does not affect others" do
      {:ok, t1, _} = YellowDogIdentity.create_token(%{hostname_pattern: "a-*", created_by: "admin"})
      {:ok, t2, _} = YellowDogIdentity.create_token(%{hostname_pattern: "b-*", created_by: "admin"})

      :ok = YellowDogIdentity.revoke_token(t1.id)

      tokens = YellowDogIdentity.list_tokens()
      assert length(tokens) == 1
      assert hd(tokens).id == t2.id
    end
  end
end
