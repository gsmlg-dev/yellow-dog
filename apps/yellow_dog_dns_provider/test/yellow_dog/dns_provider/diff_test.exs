defmodule YellowDog.DnsProvider.DiffTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Diff

  # Helper to build record entries matching Provider.record_entry() type
  defp record(owner, type, ttl, rdata) do
    %{owner: owner, type: type, ttl: ttl, rdata: rdata}
  end

  describe "compute/2" do
    test "identical sets produce empty changesets" do
      records = [
        record("www.example.com", "A", 300, "1.2.3.4"),
        record("mail.example.com", "MX", 3600, "10 mail.example.com")
      ]

      result = Diff.compute(records, records)

      assert result.local_changes.additions == []
      assert result.local_changes.deletions == []
      assert result.remote_changes.additions == []
      assert result.remote_changes.deletions == []
    end

    test "record in local but not remote produces remote addition" do
      local = [record("www.example.com", "A", 300, "1.2.3.4")]
      remote = []

      result = Diff.compute(local, remote)

      assert result.remote_changes.additions == local
      assert result.remote_changes.deletions == []
      assert result.local_changes.additions == []
      assert result.local_changes.deletions == []
    end

    test "record in remote but not local produces local addition" do
      local = []
      remote = [record("www.example.com", "A", 300, "1.2.3.4")]

      result = Diff.compute(local, remote)

      assert result.local_changes.additions == remote
      assert result.local_changes.deletions == []
      assert result.remote_changes.additions == []
      assert result.remote_changes.deletions == []
    end

    test "TTL difference produces deletions and additions in both directions" do
      local = [record("www.example.com", "A", 300, "1.2.3.4")]
      remote = [record("www.example.com", "A", 600, "1.2.3.4")]

      result = Diff.compute(local, remote)

      # Local side sees the remote version as an update
      assert result.local_changes.additions == remote
      assert result.local_changes.deletions == local

      # Remote side sees the local version as an update
      assert result.remote_changes.additions == local
      assert result.remote_changes.deletions == remote
    end

    test "completely disjoint sets" do
      local = [
        record("www.example.com", "A", 300, "1.2.3.4"),
        record("api.example.com", "A", 300, "5.6.7.8")
      ]

      remote = [
        record("mail.example.com", "MX", 3600, "10 mail.example.com"),
        record("ns1.example.com", "NS", 3600, "ns1.example.com")
      ]

      result = Diff.compute(local, remote)

      # All remote records should be added locally
      assert length(result.local_changes.additions) == 2
      assert result.local_changes.deletions == []

      # All local records should be added to remote
      assert length(result.remote_changes.additions) == 2
      assert result.remote_changes.deletions == []
    end

    test "empty local set" do
      remote = [record("www.example.com", "A", 300, "1.2.3.4")]

      result = Diff.compute([], remote)

      assert result.local_changes.additions == remote
      assert result.remote_changes.additions == []
    end

    test "empty remote set" do
      local = [record("www.example.com", "A", 300, "1.2.3.4")]

      result = Diff.compute(local, [])

      assert result.remote_changes.additions == local
      assert result.local_changes.additions == []
    end

    test "both empty sets" do
      result = Diff.compute([], [])

      assert result.local_changes.additions == []
      assert result.local_changes.deletions == []
      assert result.remote_changes.additions == []
      assert result.remote_changes.deletions == []
    end

    test "mixed: some shared, some unique, some TTL conflicts" do
      shared = record("shared.example.com", "A", 300, "1.1.1.1")
      local_only = record("local.example.com", "A", 300, "2.2.2.2")
      remote_only = record("remote.example.com", "A", 300, "3.3.3.3")
      local_ttl = record("ttl.example.com", "A", 300, "4.4.4.4")
      remote_ttl = record("ttl.example.com", "A", 600, "4.4.4.4")

      local = [shared, local_only, local_ttl]
      remote = [shared, remote_only, remote_ttl]

      result = Diff.compute(local, remote)

      # remote_only should appear in local additions
      assert remote_only in result.local_changes.additions
      # local_only should appear in remote additions
      assert local_only in result.remote_changes.additions
      # TTL conflict: both sides see delete+add
      assert local_ttl in result.local_changes.deletions
      assert remote_ttl in result.local_changes.additions
      assert remote_ttl in result.remote_changes.deletions
      assert local_ttl in result.remote_changes.additions
    end
  end

  describe "resolve/2 with :local_wins" do
    test "non-conflicting changes are always applied" do
      local = [record("local.example.com", "A", 300, "1.1.1.1")]
      remote = [record("remote.example.com", "A", 300, "2.2.2.2")]

      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :local_wins)

      # Local-only records pushed to remote
      assert resolved.push_to_remote.additions == local
      assert resolved.push_to_remote.deletions == []

      # Remote-only records applied locally
      assert resolved.apply_to_local.additions == remote
      assert resolved.apply_to_local.deletions == []

      assert resolved.conflicts == []
    end

    test "TTL conflicts: local version pushed to remote, local unchanged" do
      local_rec = record("www.example.com", "A", 300, "1.2.3.4")
      remote_rec = record("www.example.com", "A", 600, "1.2.3.4")

      diff = Diff.compute([local_rec], [remote_rec])
      resolved = Diff.resolve(diff, :local_wins)

      # Push local version to remote (delete old remote, add local)
      assert local_rec in resolved.push_to_remote.additions
      assert remote_rec in resolved.push_to_remote.deletions

      # Local stays unchanged
      assert resolved.apply_to_local.additions == []
      assert resolved.apply_to_local.deletions == []

      assert resolved.conflicts == []
    end
  end

  describe "resolve/2 with :remote_wins" do
    test "non-conflicting changes are always applied" do
      local = [record("local.example.com", "A", 300, "1.1.1.1")]
      remote = [record("remote.example.com", "A", 300, "2.2.2.2")]

      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :remote_wins)

      assert resolved.push_to_remote.additions == local
      assert resolved.apply_to_local.additions == remote
      assert resolved.conflicts == []
    end

    test "TTL conflicts: remote version applied locally, remote unchanged" do
      local_rec = record("www.example.com", "A", 300, "1.2.3.4")
      remote_rec = record("www.example.com", "A", 600, "1.2.3.4")

      diff = Diff.compute([local_rec], [remote_rec])
      resolved = Diff.resolve(diff, :remote_wins)

      # Apply remote version locally (delete old local, add remote)
      assert remote_rec in resolved.apply_to_local.additions
      assert local_rec in resolved.apply_to_local.deletions

      # Remote stays unchanged
      assert resolved.push_to_remote.additions == []
      assert resolved.push_to_remote.deletions == []

      assert resolved.conflicts == []
    end
  end

  describe "resolve/2 with :manual" do
    test "non-conflicting changes are always applied" do
      local = [record("local.example.com", "A", 300, "1.1.1.1")]
      remote = [record("remote.example.com", "A", 300, "2.2.2.2")]

      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :manual)

      assert resolved.push_to_remote.additions == local
      assert resolved.apply_to_local.additions == remote
    end

    test "TTL conflicts added to conflicts list, not applied" do
      local_rec = record("www.example.com", "A", 300, "1.2.3.4")
      remote_rec = record("www.example.com", "A", 600, "1.2.3.4")

      diff = Diff.compute([local_rec], [remote_rec])
      resolved = Diff.resolve(diff, :manual)

      assert resolved.push_to_remote.additions == []
      assert resolved.push_to_remote.deletions == []
      assert resolved.apply_to_local.additions == []
      assert resolved.apply_to_local.deletions == []

      assert length(resolved.conflicts) == 1
      [conflict] = resolved.conflicts
      assert conflict.owner == "www.example.com"
      assert conflict.type == "A"
      assert conflict.local == local_rec
      assert conflict.remote == remote_rec
    end

    test "multiple TTL conflicts all reported" do
      local = [
        record("a.example.com", "A", 100, "1.1.1.1"),
        record("b.example.com", "AAAA", 200, "::1")
      ]

      remote = [
        record("a.example.com", "A", 999, "1.1.1.1"),
        record("b.example.com", "AAAA", 888, "::1")
      ]

      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :manual)

      assert length(resolved.conflicts) == 2
    end
  end
end
