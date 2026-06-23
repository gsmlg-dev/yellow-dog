defmodule YellowDog.DnsProvider.Diff do
  @moduledoc """
  Computes bidirectional diffs between local and remote DNS record sets.

  Records are identified by `{owner, type, rdata}` (the identity key).
  Two records sharing an identity but differing in TTL are a "TTL conflict".

  Used by the SyncEngine to determine what changes need to be pushed
  upstream or applied locally.
  """

  @type record_entry :: %{
          owner: String.t(),
          type: String.t(),
          ttl: non_neg_integer(),
          rdata: term()
        }

  @type changeset :: %{
          additions: [record_entry()],
          deletions: [record_entry()]
        }

  @type diff_result :: %{
          local_changes: changeset(),
          remote_changes: changeset()
        }

  @type conflict :: %{
          owner: String.t(),
          type: String.t(),
          local: record_entry(),
          remote: record_entry()
        }

  @type resolved :: %{
          push_to_remote: changeset(),
          apply_to_local: changeset(),
          conflicts: [conflict()]
        }

  @type strategy :: :local_wins | :remote_wins | :manual

  @doc """
  Compute a bidirectional diff between local and remote record sets.

  Returns a map with `local_changes` (what local needs to match remote)
  and `remote_changes` (what remote needs to match local).
  """
  @spec compute([record_entry()], [record_entry()]) :: diff_result()
  def compute(local_records, remote_records) do
    local_index = index_by_identity(local_records)
    remote_index = index_by_identity(remote_records)

    local_keys = MapSet.new(Map.keys(local_index))
    remote_keys = MapSet.new(Map.keys(remote_index))

    local_only_keys = MapSet.difference(local_keys, remote_keys)
    remote_only_keys = MapSet.difference(remote_keys, local_keys)
    shared_keys = MapSet.intersection(local_keys, remote_keys)

    # Records only in local -> push to remote (remote additions)
    remote_additions_from_unique =
      local_only_keys |> Enum.map(&Map.fetch!(local_index, &1))

    # Records only in remote -> apply to local (local additions)
    local_additions_from_unique =
      remote_only_keys |> Enum.map(&Map.fetch!(remote_index, &1))

    # Shared keys with TTL differences -> conflicts on both sides
    {ttl_local_adds, ttl_local_dels, ttl_remote_adds, ttl_remote_dels} =
      Enum.reduce(shared_keys, {[], [], [], []}, fn key, {la, ld, ra, rd} ->
        local_rec = Map.fetch!(local_index, key)
        remote_rec = Map.fetch!(remote_index, key)

        if local_rec.ttl == remote_rec.ttl do
          {la, ld, ra, rd}
        else
          # TTL conflict: each side sees the other's version as an update
          {[remote_rec | la], [local_rec | ld], [local_rec | ra], [remote_rec | rd]}
        end
      end)

    %{
      local_changes: %{
        additions: local_additions_from_unique ++ ttl_local_adds,
        deletions: ttl_local_dels
      },
      remote_changes: %{
        additions: remote_additions_from_unique ++ ttl_remote_adds,
        deletions: ttl_remote_dels
      }
    }
  end

  @doc """
  Resolve a diff result using the given conflict strategy.

  Non-conflicting changes (records only on one side) are always applied
  regardless of strategy. TTL conflicts are handled according to:

    - `:local_wins` - push local version to remote, don't change local
    - `:remote_wins` - apply remote version to local, don't push
    - `:manual` - add to conflicts list, don't apply either direction
  """
  @spec resolve(diff_result(), strategy()) :: resolved()
  def resolve(diff_result, strategy) do
    local_index = index_deletions_by_identity(diff_result.local_changes)
    remote_index = index_deletions_by_identity(diff_result.remote_changes)

    # Separate non-conflicting additions from TTL-conflict additions
    {local_unique_adds, ttl_conflicts_from_local} =
      Enum.split_with(diff_result.local_changes.additions, fn rec ->
        key = identity(rec)
        not Map.has_key?(local_index, key)
      end)

    {remote_unique_adds, ttl_conflicts_from_remote} =
      Enum.split_with(diff_result.remote_changes.additions, fn rec ->
        key = identity(rec)
        not Map.has_key?(remote_index, key)
      end)

    # Non-conflicting: local-only records -> push to remote
    #                   remote-only records -> apply to local
    base = %{
      push_to_remote: %{additions: remote_unique_adds, deletions: []},
      apply_to_local: %{additions: local_unique_adds, deletions: []},
      conflicts: []
    }

    # Build TTL conflict pairs
    ttl_pairs = build_ttl_pairs(ttl_conflicts_from_local, ttl_conflicts_from_remote, diff_result)

    apply_strategy(base, ttl_pairs, strategy)
  end

  # --- Private ---

  defp identity(record), do: {record.owner, record.type, record.rdata}

  defp index_by_identity(records) do
    Map.new(records, fn r -> {identity(r), r} end)
  end

  defp index_deletions_by_identity(changeset) do
    Map.new(changeset.deletions, fn r -> {identity(r), r} end)
  end

  defp build_ttl_pairs(local_additions, _remote_additions, diff_result) do
    # local_additions are remote records (TTL conflict: remote version added to local)
    # For each, find the corresponding local record from local_changes.deletions
    local_del_index = index_by_identity(diff_result.local_changes.deletions)
    remote_del_index = index_by_identity(diff_result.remote_changes.deletions)

    Enum.map(local_additions, fn remote_rec ->
      key = identity(remote_rec)
      local_rec = Map.get(local_del_index, key)
      original_remote = Map.get(remote_del_index, key)

      %{
        key: key,
        local: local_rec,
        remote: remote_rec,
        original_remote: original_remote
      }
    end)
  end

  defp apply_strategy(base, [], _strategy), do: base

  defp apply_strategy(base, ttl_pairs, :local_wins) do
    Enum.reduce(ttl_pairs, base, fn pair, acc ->
      # Push local version to remote (delete remote's old, add local)
      %{
        acc
        | push_to_remote: %{
            additions: [pair.local | acc.push_to_remote.additions],
            deletions: [pair.original_remote | acc.push_to_remote.deletions]
          }
      }
    end)
  end

  defp apply_strategy(base, ttl_pairs, :remote_wins) do
    Enum.reduce(ttl_pairs, base, fn pair, acc ->
      # Apply remote version to local (delete local's old, add remote)
      %{
        acc
        | apply_to_local: %{
            additions: [pair.remote | acc.apply_to_local.additions],
            deletions: [pair.local | acc.apply_to_local.deletions]
          }
      }
    end)
  end

  defp apply_strategy(base, ttl_pairs, :manual) do
    conflicts =
      Enum.map(ttl_pairs, fn pair ->
        {owner, type, _rdata} = pair.key

        %{
          owner: owner,
          type: type,
          local: pair.local,
          remote: pair.remote
        }
      end)

    %{base | conflicts: conflicts}
  end
end
