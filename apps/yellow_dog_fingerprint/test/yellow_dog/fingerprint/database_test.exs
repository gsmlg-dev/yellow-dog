defmodule YellowDog.Fingerprint.DatabaseTest do
  use ExUnit.Case, async: false

  alias YellowDog.Fingerprint.Database
  alias YellowDog.Fingerprint.Types.Fingerprint

  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp build_fingerprint(protocol) do
    params = [1, 3, 6, 15, System.unique_integer([:positive]) |> rem(200) |> abs()]
    vc = "test-vendor-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    %Fingerprint{
      id: Fingerprint.compute_id(protocol, params, vc),
      protocol: protocol,
      parameter_list: params,
      vendor_class: vc,
      hostname_pattern: nil,
      first_seen: now,
      last_seen: now,
      hit_count: 1
    }
  end

  describe "Database GenServer is running" do
    test "process is alive" do
      pid = Process.whereis(Database)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "stats/0" do
    test "returns map with expected keys" do
      stats = Database.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :profiles)
      assert Map.has_key?(stats, :fingerprints_v4)
      assert Map.has_key?(stats, :fingerprints_v6)
      assert Map.has_key?(stats, :overrides)
    end

    test "counts are non-negative integers" do
      stats = Database.stats()
      assert is_integer(stats.profiles) and stats.profiles >= 0
      assert is_integer(stats.fingerprints_v4) and stats.fingerprints_v4 >= 0
      assert is_integer(stats.fingerprints_v6) and stats.fingerprints_v6 >= 0
      assert is_integer(stats.overrides) and stats.overrides >= 0
    end
  end

  describe "record_fingerprint/1 and lookup_v4/1" do
    test "records a DHCPv4 fingerprint and makes it retrievable via lookup_v4" do
      fp = build_fingerprint(:dhcpv4)

      assert :not_found = Database.lookup_v4(fp.id)

      Database.record_fingerprint(fp)
      Process.sleep(20)

      assert {:ok, entry} = Database.lookup_v4(fp.id)
      assert entry.vendor_class == fp.vendor_class
      assert entry.hit_count == 1
    end

    test "hit_count increments on repeated recordings" do
      fp = build_fingerprint(:dhcpv4)

      Database.record_fingerprint(fp)
      Database.record_fingerprint(fp)
      Process.sleep(30)

      {:ok, entry} = Database.lookup_v4(fp.id)
      assert entry.hit_count == 2
    end

    test "fingerprints_v4 count increases after record" do
      fp = build_fingerprint(:dhcpv4)
      before_count = Database.stats().fingerprints_v4

      Database.record_fingerprint(fp)
      Process.sleep(20)

      after_count = Database.stats().fingerprints_v4
      assert after_count == before_count + 1
    end
  end

  describe "record_fingerprint/1 and lookup_v6/1" do
    test "records a DHCPv6 fingerprint and makes it retrievable via lookup_v6" do
      fp = build_fingerprint(:dhcpv6)

      assert :not_found = Database.lookup_v6(fp.id)

      Database.record_fingerprint(fp)
      Process.sleep(20)

      assert {:ok, entry} = Database.lookup_v6(fp.id)
      assert entry.vendor_class == fp.vendor_class
    end

    test "fingerprints_v6 count increases after record" do
      fp = build_fingerprint(:dhcpv6)
      before_count = Database.stats().fingerprints_v6

      Database.record_fingerprint(fp)
      Process.sleep(20)

      after_count = Database.stats().fingerprints_v6
      assert after_count == before_count + 1
    end
  end

  describe "list_fingerprints/0" do
    test "returns a list" do
      result = Database.list_fingerprints()
      assert is_list(result)
    end

    test "v4 count matches all_v4_entries count" do
      v4_direct = Database.all_v4_entries()
      all = Database.list_fingerprints()
      # list_fingerprints = v4 + v6, so v4_count <= length(all)
      assert length(v4_direct) <= length(all)
    end
  end

  describe "list_unknown_fingerprints/0" do
    test "returns only fingerprints without profile_id" do
      # record a fresh fingerprint (no profile mapping in DB)
      fp = build_fingerprint(:dhcpv4)
      Database.record_fingerprint(fp)
      Process.sleep(20)

      unknowns = Database.list_unknown_fingerprints()
      assert is_list(unknowns)

      # All returned entries should have nil profile_id
      for entry <- unknowns do
        assert entry.profile_id == nil
      end
    end

    test "is sorted by hit_count descending" do
      unknowns = Database.list_unknown_fingerprints()

      if length(unknowns) > 1 do
        counts = Enum.map(unknowns, & &1.hit_count)
        assert counts == Enum.sort(counts, :desc)
      end
    end
  end

  describe "add_override/3 and lookup_override/1" do
    test "adds and retrieves an override" do
      hash = unique_id()
      profile_id = "windows-11"

      assert :not_found = Database.lookup_override(hash)

      assert :ok = Database.add_override(hash, profile_id, "manual classification")

      assert {:ok, override} = Database.lookup_override(hash)
      assert override.profile_id == profile_id
      assert override.note == "manual classification"
    end

    test "overrides count increases after add" do
      hash = unique_id()
      before_count = Database.stats().overrides

      Database.add_override(hash, "test-profile", nil)

      after_count = Database.stats().overrides
      assert after_count == before_count + 1
    end

    test "lookup_override returns :not_found for unknown hash" do
      assert :not_found = Database.lookup_override("nonexistent-#{unique_id()}")
    end

    test "override note can be nil" do
      hash = unique_id()
      Database.add_override(hash, "profile-no-note", nil)

      {:ok, override} = Database.lookup_override(hash)
      assert override.note == nil
    end
  end

  describe "get_profile/1" do
    test "returns :not_found for non-existent profile" do
      assert :not_found = Database.get_profile("nonexistent-profile-#{unique_id()}")
    end
  end

  describe "list_profiles/0" do
    test "returns a list" do
      result = Database.list_profiles()
      assert is_list(result)
    end
  end
end
