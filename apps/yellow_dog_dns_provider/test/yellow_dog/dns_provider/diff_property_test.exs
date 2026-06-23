defmodule YellowDog.DnsProvider.DiffPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.DnsProvider.Diff

  # Generator for a single DNS record entry
  defp record_gen do
    gen all(
          owner <- string(:alphanumeric, min_length: 1, max_length: 20),
          type <- member_of(["A", "AAAA", "MX", "CNAME", "TXT", "NS", "PTR", "SRV"]),
          ttl <- positive_integer(),
          rdata <- string(:alphanumeric, min_length: 1, max_length: 30)
        ) do
      %{owner: owner, type: type, ttl: ttl, rdata: rdata}
    end
  end

  # Generator for a list of records with unique identity keys
  defp unique_records_gen do
    gen all(records <- list_of(record_gen(), min_length: 0, max_length: 10)) do
      Enum.uniq_by(records, fn r -> {r.owner, r.type, r.rdata} end)
    end
  end

  property "identical sets produce empty diffs" do
    check all(records <- unique_records_gen()) do
      result = Diff.compute(records, records)

      assert result.local_changes.additions == []
      assert result.local_changes.deletions == []
      assert result.remote_changes.additions == []
      assert result.remote_changes.deletions == []
    end
  end

  property "diff against empty remote marks all local as remote additions" do
    check all(local <- unique_records_gen()) do
      result = Diff.compute(local, [])

      assert Enum.sort(result.remote_changes.additions) == Enum.sort(local)
      assert result.remote_changes.deletions == []
      assert result.local_changes.additions == []
      assert result.local_changes.deletions == []
    end
  end

  property "resolve :local_wins never modifies local for conflicts" do
    check all(
            local <- unique_records_gen(),
            remote <- unique_records_gen()
          ) do
      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :local_wins)

      # For TTL conflicts, local_wins should not apply conflict changes to local.
      # apply_to_local should only contain records that are remote-only (not conflicts).
      Enum.each(resolved.apply_to_local.additions, fn rec ->
        # Every record applied to local must be remote-only, not a TTL conflict
        refute Enum.any?(local, fn l ->
                 {l.owner, l.type, l.rdata} == {rec.owner, rec.type, rec.rdata}
               end)
      end)

      assert resolved.apply_to_local.deletions == []
    end
  end

  property "resolve :remote_wins never pushes conflicts to remote" do
    check all(
            local <- unique_records_gen(),
            remote <- unique_records_gen()
          ) do
      diff = Diff.compute(local, remote)
      resolved = Diff.resolve(diff, :remote_wins)

      # For TTL conflicts, remote_wins should not push conflict changes to remote.
      # push_to_remote should only contain records that are local-only (not conflicts).
      Enum.each(resolved.push_to_remote.additions, fn rec ->
        refute Enum.any?(remote, fn r ->
                 {r.owner, r.type, r.rdata} == {rec.owner, rec.type, rec.rdata}
               end)
      end)

      assert resolved.push_to_remote.deletions == []
    end
  end
end
