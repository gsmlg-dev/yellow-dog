defmodule YellowDogIdentity.RegistryTest do
  use ExUnit.Case

  alias YellowDogIdentity.{Host, Token, Registry}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  setup do
    # Use a unique temp directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "yd_identity_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: :"registry_#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{registry: pid, tmp_dir: tmp_dir}
  end

  defp make_host(hostname \\ "node-01") do
    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    host
  end

  describe "host CRUD" do
    test "put and get host", %{registry: pid} do
      host = make_host()
      assert :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host, host.id})
    end

    test "get host by fingerprint", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_fingerprint, host.key_fingerprint})
    end

    test "get host by hostname", %{registry: pid} do
      host = make_host("myhost")
      :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_hostname, "myhost"})
    end

    test "list hosts", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      hosts = GenServer.call(pid, :list_hosts)
      assert length(hosts) == 1
    end

    test "list hosts by status", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      pending = GenServer.call(pid, {:list_hosts_by_status, :pending})
      approved = GenServer.call(pid, {:list_hosts_by_status, :approved})
      assert length(pending) == 1
      assert length(approved) == 0
    end

    test "delete host", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      assert :ok = GenServer.call(pid, {:delete_host, host.id})
      assert :not_found = GenServer.call(pid, {:get_host, host.id})
    end

    test "not_found for missing host", %{registry: pid} do
      assert :not_found = GenServer.call(pid, {:get_host, "nonexistent"})
    end

    test "get_host_by_fingerprint returns not_found when index desync (host deleted)", %{
      registry: pid
    } do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      fingerprint = host.key_fingerprint

      # Verify it's findable before deletion
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_fingerprint, fingerprint})

      # Delete the host — after deletion the fingerprint index entry is also removed
      :ok = GenServer.call(pid, {:delete_host, host.id})

      # Fingerprint lookup must not crash — returns :not_found instead
      assert :not_found = GenServer.call(pid, {:get_host_by_fingerprint, fingerprint})
    end

    test "delete host returns not_found for unknown id", %{registry: pid} do
      assert {:error, :not_found} = GenServer.call(pid, {:delete_host, "does-not-exist"})
    end

    test "delete host succeeds when file was already deleted from disk (enoent)", %{
      registry: pid,
      tmp_dir: tmp_dir
    } do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})

      # Pre-delete the file from disk, simulating external removal
      host_file = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      File.rm!(host_file)

      # delete_host must still succeed — {:error, :enoent} -> :ok in File.rm branch
      assert :ok = GenServer.call(pid, {:delete_host, host.id})

      # Host is removed from in-memory state
      assert :not_found = GenServer.call(pid, {:get_host, host.id})
    end

    test "delete_host returns {:error, :delete_failed} when file cannot be removed (permission denied)",
         %{registry: pid, tmp_dir: tmp_dir} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})

      hosts_dir = Path.join(tmp_dir, "hosts")
      # Make directory read-only so File.rm fails with :eacces
      File.chmod!(hosts_dir, 0o555)

      on_exit(fn -> File.chmod!(hosts_dir, 0o755) end)

      assert {:error, :delete_failed} = GenServer.call(pid, {:delete_host, host.id})
      # Host remains in memory since delete failed
      assert {:ok, _} = GenServer.call(pid, {:get_host, host.id})
    end

    test "put_host cleans stale fingerprint index on key change", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      old_fingerprint = host.key_fingerprint

      # Simulate key rotation: same host ID, different fingerprint
      updated = %{host | key_fingerprint: "SHA256:new-fingerprint-value", ssh_pubkey: "rotated"}
      :ok = GenServer.call(pid, {:put_host, updated})

      # Old fingerprint should no longer resolve
      assert :not_found = GenServer.call(pid, {:get_host_by_fingerprint, old_fingerprint})

      # New fingerprint should resolve
      assert {:ok, ^updated} = GenServer.call(pid, {:get_host_by_fingerprint, "SHA256:new-fingerprint-value"})
    end

    test "put_host preserves fingerprint index when key unchanged", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})

      # Update host without changing key
      updated = %{host | status: :approved}
      :ok = GenServer.call(pid, {:put_host, updated})

      # Fingerprint should still resolve
      assert {:ok, ^updated} = GenServer.call(pid, {:get_host_by_fingerprint, host.key_fingerprint})
    end

    test "hostname index provides O(1) lookup", %{registry: pid} do
      host = make_host("indexed-host")
      :ok = GenServer.call(pid, {:put_host, host})

      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_hostname, "indexed-host"})
    end

    test "hostname index cleans stale entry on hostname change", %{registry: pid} do
      host = make_host("old-hostname")
      :ok = GenServer.call(pid, {:put_host, host})

      updated = %{host | hostname: "new-hostname"}
      :ok = GenServer.call(pid, {:put_host, updated})

      assert :not_found = GenServer.call(pid, {:get_host_by_hostname, "old-hostname"})
      assert {:ok, ^updated} = GenServer.call(pid, {:get_host_by_hostname, "new-hostname"})
    end

    test "delete host removes hostname index entry", %{registry: pid} do
      host = make_host("deletable")
      :ok = GenServer.call(pid, {:put_host, host})

      :ok = GenServer.call(pid, {:delete_host, host.id})
      assert :not_found = GenServer.call(pid, {:get_host_by_hostname, "deletable"})
    end

    test "hostname index survives restart", %{tmp_dir: tmp_dir} do
      name1 = :"hn_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      host = make_host("persisted-host")
      :ok = GenServer.call(pid1, {:put_host, host})
      GenServer.stop(pid1)

      name2 = :"hn_persist_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host_by_hostname, "persisted-host"})
      assert restored.hostname == "persisted-host"

      GenServer.stop(pid2)
    end

    test "delete host removes fingerprint index entry", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      fingerprint = host.key_fingerprint

      :ok = GenServer.call(pid, {:delete_host, host.id})
      assert :not_found = GenServer.call(pid, {:get_host_by_fingerprint, fingerprint})
    end
  end

  describe "put_host_checked" do
    test "stores host when no conflicts", %{registry: pid} do
      host = make_host()
      assert :ok = GenServer.call(pid, {:put_host_checked, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host, host.id})
    end

    test "rejects duplicate fingerprint from different host", %{registry: pid} do
      host1 = make_host("host-a")
      :ok = GenServer.call(pid, {:put_host_checked, host1})

      # Build a second host with the same fingerprint but different ID
      host2 = %{make_host("host-b") | key_fingerprint: host1.key_fingerprint}
      assert {:error, :fingerprint_conflict} = GenServer.call(pid, {:put_host_checked, host2})
    end

    test "allows same host to update (no fingerprint conflict with self)", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host_checked, host})

      updated = %{host | status: :approved}
      assert :ok = GenServer.call(pid, {:put_host_checked, updated})
    end

    test "rejects duplicate instance_id from different host", %{registry: pid} do
      host1 = %{make_host("cloud-a") | trust_evidence: %{instance_id: "i-abc123", provider: :aws}}
      :ok = GenServer.call(pid, {:put_host_checked, host1})

      host2 = %{
        make_host("cloud-b")
        | trust_evidence: %{instance_id: "i-abc123", provider: :aws},
          key_fingerprint: "SHA256:different-key-for-instance-test"
      }

      assert {:error, :instance_id_conflict} = GenServer.call(pid, {:put_host_checked, host2})
    end

    test "allows same host to update with same instance_id", %{registry: pid} do
      host = %{make_host("cloud-a") | trust_evidence: %{instance_id: "i-abc123", provider: :aws}}
      :ok = GenServer.call(pid, {:put_host_checked, host})

      updated = %{host | status: :approved}
      assert :ok = GenServer.call(pid, {:put_host_checked, updated})
    end

    test "allows hosts without instance_id (no conflict)", %{registry: pid} do
      host1 = make_host("onprem-a")
      host2 = %{make_host("onprem-b") | key_fingerprint: "SHA256:different-key"}
      :ok = GenServer.call(pid, {:put_host_checked, host1})
      assert :ok = GenServer.call(pid, {:put_host_checked, host2})
    end

    test "put_host cleans stale instance_id index when host changes instance_id", %{registry: pid} do
      host = %{make_host("cloud-a") | trust_evidence: %{instance_id: "i-old111", provider: :aws}}
      :ok = GenServer.call(pid, {:put_host, host})

      # Update the same host with a new instance_id
      updated = %{host | trust_evidence: %{instance_id: "i-new222", provider: :aws}}
      :ok = GenServer.call(pid, {:put_host, updated})

      # Old instance_id must no longer block a different host
      other_host = %{
        make_host("cloud-b")
        | trust_evidence: %{instance_id: "i-old111", provider: :aws},
          key_fingerprint: "SHA256:different-key-for-iid-rotation-test"
      }

      assert :ok = GenServer.call(pid, {:put_host_checked, other_host})

      # New instance_id should now conflict if another host tries to use it
      conflict_host = %{
        make_host("cloud-c")
        | trust_evidence: %{instance_id: "i-new222", provider: :aws},
          key_fingerprint: "SHA256:yet-another-key-for-iid-conflict-test"
      }

      assert {:error, :instance_id_conflict} = GenServer.call(pid, {:put_host_checked, conflict_host})
    end

    test "instance_id index cleaned on host delete", %{registry: pid} do
      host1 = %{make_host("cloud-a") | trust_evidence: %{instance_id: "i-del123", provider: :aws}}
      :ok = GenServer.call(pid, {:put_host_checked, host1})

      :ok = GenServer.call(pid, {:delete_host, host1.id})

      # Now a new host with the same instance_id should succeed
      host2 = %{
        make_host("cloud-b")
        | trust_evidence: %{instance_id: "i-del123", provider: :aws},
          key_fingerprint: "SHA256:different-key-for-delete-test"
      }

      assert :ok = GenServer.call(pid, {:put_host_checked, host2})
    end
  end

  describe "token CRUD" do
    test "put and get token", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{hostname_pattern: "node-*"})
      assert :ok = GenServer.call(pid, {:put_token, token})
      assert {:ok, ^token} = GenServer.call(pid, {:get_token, token.id})
    end

    test "list tokens", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})
      tokens = GenServer.call(pid, :list_tokens)
      assert length(tokens) == 1
    end

    test "delete token", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})
      assert :ok = GenServer.call(pid, {:delete_token, token.id})
      assert :not_found = GenServer.call(pid, {:get_token, token.id})
    end

    test "delete token returns not_found for unknown id", %{registry: pid} do
      assert {:error, :not_found} = GenServer.call(pid, {:delete_token, "does-not-exist"})
    end

    test "delete token succeeds when file was already deleted from disk (enoent)", %{
      registry: pid,
      tmp_dir: tmp_dir
    } do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})

      # Pre-delete the file from disk
      token_file = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])
      File.rm!(token_file)

      # delete_token must still succeed — {:error, :enoent} -> :ok branch
      assert :ok = GenServer.call(pid, {:delete_token, token.id})
      assert :not_found = GenServer.call(pid, {:get_token, token.id})
    end

    test "delete_token returns {:error, :delete_failed} when file cannot be removed (permission denied)",
         %{registry: pid, tmp_dir: tmp_dir} do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})

      tokens_dir = Path.join(tmp_dir, "tokens")
      File.chmod!(tokens_dir, 0o555)
      on_exit(fn -> File.chmod!(tokens_dir, 0o755) end)

      assert {:error, :delete_failed} = GenServer.call(pid, {:delete_token, token.id})
      # Token remains in memory since delete failed
      assert {:ok, _} = GenServer.call(pid, {:get_token, token.id})
    end
  end

  describe "cleanup_expired_tokens" do
    test "expired tokens are removed from memory on cleanup", %{registry: pid} do
      # Create a token that expires immediately
      {:ok, token, _raw} = Token.create(%{ttl_seconds: 1})
      :ok = GenServer.call(pid, {:put_token, token})

      # Verify it's present
      assert {:ok, _} = GenServer.call(pid, {:get_token, token.id})

      # Wait for expiry, then trigger cleanup manually
      Process.sleep(1100)
      send(pid, :cleanup_expired_tokens)

      # Sync: wait for the GenServer to process the info message
      _ = GenServer.call(pid, :list_tokens)

      assert :not_found = GenServer.call(pid, {:get_token, token.id})
    end

    test "non-expired tokens are retained after cleanup", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{ttl_seconds: 3600})
      :ok = GenServer.call(pid, {:put_token, token})

      send(pid, :cleanup_expired_tokens)
      _ = GenServer.call(pid, :list_tokens)

      assert {:ok, _} = GenServer.call(pid, {:get_token, token.id})
    end

    test "cleanup removes expired token from state even when file deletion fails (permission denied)",
         %{registry: pid, tmp_dir: tmp_dir} do
      {:ok, token, _raw} = Token.create(%{ttl_seconds: 1})
      :ok = GenServer.call(pid, {:put_token, token})

      # Wait for expiry
      Process.sleep(1100)

      # Make tokens dir non-writable so File.rm will fail with :eacces
      tokens_dir = Path.join(tmp_dir, "tokens")
      File.chmod!(tokens_dir, 0o555)
      on_exit(fn -> File.chmod!(tokens_dir, 0o755) end)

      # Cleanup still removes from in-memory state despite file deletion failure
      send(pid, :cleanup_expired_tokens)
      _ = GenServer.call(pid, :list_tokens)

      assert :not_found = GenServer.call(pid, {:get_token, token.id})
    end
  end

  describe "TOML persistence" do
    test "hosts survive restart", %{tmp_dir: tmp_dir} do
      name1 = :"persist_test_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      host = make_host()
      :ok = GenServer.call(pid1, {:put_host, host})
      GenServer.stop(pid1)

      # Restart with same data_dir
      name2 = :"persist_test_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host, host.id})
      assert restored.hostname == host.hostname
      assert restored.key_fingerprint == host.key_fingerprint

      GenServer.stop(pid2)
    end

    test "TOML files exist on disk after put", %{tmp_dir: tmp_dir, registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})

      host_file = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      assert File.exists?(host_file)

      content = File.read!(host_file)
      assert content =~ "hostname"
      assert content =~ host.hostname
    end

    test "corrupt TOML file is skipped on load but valid files are still loaded", %{tmp_dir: tmp_dir} do
      hosts_dir = Path.join(tmp_dir, "hosts")
      File.mkdir_p!(hosts_dir)

      # Start registry, persist a valid host, then stop
      name1 = :"corrupt_skip_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)
      host = make_host()
      :ok = GenServer.call(pid1, {:put_host, host})
      GenServer.stop(pid1)

      # Drop a corrupt TOML file alongside the valid one
      File.write!(Path.join(hosts_dir, "corrupt-id.toml"), "[[[not valid toml")

      # Restart — corrupt file is skipped, valid host is still loaded
      name2 = :"corrupt_skip_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, _} = GenServer.call(pid2, {:get_host, host.id})
      # The corrupt file produced no host
      all = GenServer.call(pid2, :list_hosts)
      assert length(all) == 1

      GenServer.stop(pid2)
    end

    test "cloud-attested host with DateTime in trust_evidence survives restart", %{tmp_dir: tmp_dir} do
      name1 = :"persist_cloud_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      {:ok, host} =
        Host.new(%{
          hostname: "aws-node-01",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      # Simulate what trust router sets: cloud evidence with DateTime fields
      host_with_evidence = %{
        host
        | trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{
            provider: :aws,
            account_id: "123456789012",
            instance_id: "i-0abcdef1234567890",
            region: "us-east-1",
            image_id: "ami-0abc12345",
            instance_type: "t3.medium",
            verified_at: DateTime.utc_now(),
            document_time: "2026-01-01T12:00:00Z"
          },
          status: :approved,
          approved_at: DateTime.utc_now(),
          approved_by: "auto:aws-prod-auto"
      }

      :ok = GenServer.call(pid1, {:put_host, host_with_evidence})
      GenServer.stop(pid1)

      # Restart and verify the host is loadable
      name2 = :"persist_cloud_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host, host.id})
      assert restored.hostname == "aws-node-01"
      assert restored.trust_level == :cloud_verified
      assert restored.trust_provider == :aws
      assert restored.status == :approved
      # trust_evidence is restored as a string-keyed map (TOML round-trip)
      assert is_map(restored.trust_evidence)
      assert Map.get(restored.trust_evidence, "account_id") == "123456789012"
      assert Map.get(restored.trust_evidence, "region") == "us-east-1"
      # verified_at is stored as ISO8601 string after TOML round-trip
      assert is_binary(Map.get(restored.trust_evidence, "verified_at"))

      GenServer.stop(pid2)
    end

    test "host with control chars in metadata survives TOML round-trip", %{tmp_dir: tmp_dir} do
      name1 = :"persist_ctrl_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      host = %{make_host("ctrl-host") | metadata: %{"notes" => "line1\nline2\ttabbed\rcarriage"}}
      :ok = GenServer.call(pid1, {:put_host, host})

      # Verify TOML file is valid (no raw control chars breaking parsing)
      host_file = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      content = File.read!(host_file)
      assert content =~ "\\n"
      assert content =~ "\\t"
      assert content =~ "\\r"

      GenServer.stop(pid1)

      # Restart and verify round-trip
      name2 = :"persist_ctrl_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host, host.id})
      notes = Map.get(restored.metadata, "notes")
      assert notes =~ "line1"
      assert notes =~ "line2"

      GenServer.stop(pid2)
    end

    test "GCP-attested host with DateTime in trust_evidence survives restart", %{tmp_dir: tmp_dir} do
      name1 = :"persist_gcp_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      {:ok, host} =
        Host.new(%{
          hostname: "gcp-node-01",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      host_with_evidence = %{
        host
        | trust_level: :cloud_verified,
          trust_provider: :gcp,
          trust_evidence: %{
            provider: :gcp,
            project_id: "my-gcp-project",
            instance_id: "1234567890",
            instance_name: "gcp-node-01",
            zone: "us-central1-a",
            verified_at: DateTime.utc_now()
          }
      }

      :ok = GenServer.call(pid1, {:put_host, host_with_evidence})
      GenServer.stop(pid1)

      name2 = :"persist_gcp_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host, host.id})
      assert restored.trust_level == :cloud_verified
      assert restored.trust_provider == :gcp
      assert Map.get(restored.trust_evidence, "project_id") == "my-gcp-project"
      assert Map.get(restored.trust_evidence, "zone") == "us-central1-a"
      assert is_binary(Map.get(restored.trust_evidence, "verified_at"))

      GenServer.stop(pid2)
    end
  end
end
