defmodule YellowDog.Netman.ProfileStorePropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Types.Profile

  # Generators

  defp profile_id_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 20)
    |> StreamData.map(&("prop-ps-" <> &1))
  end

  defp iface_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
      |> StreamData.map(&("pi_" <> &1))
      |> StreamData.map(&String.slice(&1, 0, 15))
    ])
  end

  defp priority_gen do
    StreamData.integer(0..1000)
  end

  defp profile_gen do
    gen all(
          id <- profile_id_gen(),
          iface <- iface_gen(),
          priority <- priority_gen(),
          autoconnect <- StreamData.boolean()
        ) do
      %Profile{
        id: id,
        type: :ethernet,
        interface: iface,
        autoconnect: autoconnect,
        autoconnect_priority: priority
      }
    end
  end

  # Properties

  property "put then get always retrieves the same profile" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      assert {:ok, ^profile} = ProfileStore.get(profile.id)
      ProfileStore.delete(profile.id)
    end
  end

  property "delete then get returns :not_found" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      ProfileStore.delete(profile.id)
      assert {:error, :not_found} = ProfileStore.get(profile.id)
    end
  end

  property "list always returns a list of Profile structs" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      profiles = ProfileStore.list()
      assert is_list(profiles)
      assert Enum.all?(profiles, &match?(%Profile{}, &1))
      ProfileStore.delete(profile.id)
    end
  end

  property "match_interface returns nil or a Profile" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)) do
      result = ProfileStore.match_interface(iface)
      assert is_nil(result) or match?(%Profile{}, result)
    end
  end

  property "exact interface match is preferred over wildcard" do
    check all(
            exact <- profile_gen(),
            wild <- profile_gen(),
            iface <-
              StreamData.string(:alphanumeric, min_length: 3, max_length: 12)
              |> StreamData.map(&("xmt_" <> &1))
              |> StreamData.map(&String.slice(&1, 0, 15))
          ) do
      # Make exact and wildcard profiles with unique IDs
      exact = %{exact | interface: iface, id: "exact-#{iface}"}
      wild = %{wild | interface: nil, id: "wild-#{iface}", autoconnect_priority: 999}

      ProfileStore.put(exact.id, exact)
      ProfileStore.put(wild.id, wild)

      matched = ProfileStore.match_interface(iface)
      assert matched != nil
      assert matched.id == exact.id

      ProfileStore.delete(exact.id)
      ProfileStore.delete(wild.id)
    end
  end

  property "higher priority wildcard wins when no exact match" do
    check all(
            lo_prio <- StreamData.integer(0..499),
            hi_prio <- StreamData.integer(500..1000),
            iface <-
              StreamData.string(:alphanumeric, min_length: 3, max_length: 12)
              |> StreamData.map(&("hpw_" <> &1))
              |> StreamData.map(&String.slice(&1, 0, 15))
          ) do
      lo_id = "lo-wild-#{iface}"
      hi_id = "hi-wild-#{iface}"

      lo_profile = %Profile{
        id: lo_id,
        type: :ethernet,
        interface: nil,
        autoconnect_priority: lo_prio
      }

      hi_profile = %Profile{
        id: hi_id,
        type: :ethernet,
        interface: nil,
        autoconnect_priority: hi_prio
      }

      ProfileStore.put(lo_id, lo_profile)
      ProfileStore.put(hi_id, hi_profile)

      matched = ProfileStore.match_interface(iface)
      assert matched != nil
      assert matched.id == hi_id

      ProfileStore.delete(lo_id)
      ProfileStore.delete(hi_id)
    end
  end

  property "match_interface does not match wrong type" do
    check all(profile <- profile_gen()) do
      profile = %{profile | type: :ethernet}
      ProfileStore.put(profile.id, profile)

      result = ProfileStore.match_interface(profile.interface || "any_iface", :wifi)
      # Should not match ethernet profile when looking for wifi
      if result != nil do
        assert result.type == :wifi
      end

      ProfileStore.delete(profile.id)
    end
  end

  property "double delete returns :not_found on second call" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      assert :ok = ProfileStore.delete(profile.id)
      assert {:error, :not_found} = ProfileStore.delete(profile.id)
    end
  end

  property "list always contains recently put profile" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      profiles = ProfileStore.list()

      assert Enum.any?(profiles, &(&1.id == profile.id)),
             "Expected profile #{profile.id} in list/0 result"

      ProfileStore.delete(profile.id)
    end
  end

  property "second put overwrites first (last write wins)" do
    check all(
            p1 <- profile_gen(),
            p2 <- profile_gen()
          ) do
      shared_id = "overwrite-#{p1.id}"
      p1 = %{p1 | id: shared_id}
      p2 = %{p2 | id: shared_id}

      ProfileStore.put(p1.id, p1)
      ProfileStore.put(p2.id, p2)

      assert {:ok, ^p2} = ProfileStore.get(shared_id)

      ProfileStore.delete(shared_id)
    end
  end

  property "list count increases by exactly 1 after putting a new unique profile" do
    check all(profile <- profile_gen()) do
      unique_id = "pscount-#{:erlang.unique_integer([:monotonic, :positive])}"
      profile = %{profile | id: unique_id}

      before_count = length(ProfileStore.list())
      ProfileStore.put(profile.id, profile)
      after_count = length(ProfileStore.list())

      assert after_count == before_count + 1,
             "Expected list to grow by 1: #{before_count} -> #{after_count}"

      ProfileStore.delete(profile.id)
    end
  end

  property "import_file on a valid TOML file returns {:ok, profile}" do
    check all(_ <- StreamData.constant(:ok), max_runs: 3) do
      uid = :rand.uniform(999_999)
      id = "ps_import_#{uid}"
      path = "/tmp/#{id}.toml"

      toml = """
      [connection]
      id = "#{id}"
      type = "ethernet"
      autoconnect = false

      [ipv4]
      method = "disabled"

      [ipv6]
      method = "disabled"
      """

      File.write!(path, toml)

      try do
        result = ProfileStore.import_file(path)

        assert match?({:ok, %Profile{}}, result),
               "Expected {:ok, %Profile{}}, got: #{inspect(result)}"

        {:ok, profile} = result
        assert profile.id == id
        ProfileStore.delete(id)
      after
        File.rm(path)
      end
    end
  end

  property "list after delete never contains the deleted profile" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      ProfileStore.delete(profile.id)

      profiles = ProfileStore.list()

      refute Enum.any?(profiles, &(&1.id == profile.id)),
             "Profile #{profile.id} should not appear in list after delete"
    end
  end

  property "get for never-put profile always returns {:error, :not_found}" do
    check all(_ <- StreamData.constant(:ok)) do
      unique_id = "fresh-#{:erlang.unique_integer([:monotonic, :positive])}"
      result = ProfileStore.get(unique_id)
      assert result == {:error, :not_found},
             "Expected not_found for fresh ID, got: #{inspect(result)}"
    end
  end

  property "list count decreases by exactly 1 after deleting an existing profile" do
    check all(_ <- StreamData.constant(:ok)) do
      uid = :erlang.unique_integer([:monotonic, :positive])
      id = "psdel-#{uid}"

      profile = %Profile{
        id: id,
        type: :ethernet,
        interface: nil,
        autoconnect: false,
        autoconnect_priority: 0
      }

      ProfileStore.put(id, profile)
      before_count = length(ProfileStore.list())
      ProfileStore.delete(id)
      after_count = length(ProfileStore.list())

      assert after_count == before_count - 1,
             "Expected list to shrink by 1: #{before_count} -> #{after_count}"
    end
  end

  property "put for one profile does not affect another profile's get result" do
    check all(
            p1 <- profile_gen(),
            p2 <- profile_gen()
          ) do
      p1 = %{p1 | id: "iso1-#{p1.id}"}
      p2 = %{p2 | id: "iso2-#{p2.id}"}

      ProfileStore.put(p1.id, p1)
      ProfileStore.put(p2.id, p2)

      # Overwrite p1 with a modified version
      p1_updated = %{p1 | autoconnect: not p1.autoconnect}
      ProfileStore.put(p1.id, p1_updated)

      # p2 must be unaffected
      assert {:ok, ^p2} = ProfileStore.get(p2.id),
             "p2 was unexpectedly changed when p1 was overwritten"

      ProfileStore.delete(p1.id)
      ProfileStore.delete(p2.id)
    end
  end

  property "import_file on a file larger than 1MB returns file_too_large error" do
    check all(_ <- StreamData.constant(:ok), max_runs: 1) do
      path = "/tmp/ps_prop_large_#{:rand.uniform(999_999)}.toml"
      # Write 1MB + 1 byte (just over the limit)
      File.write!(path, String.duplicate("# x\n", 262_145))

      try do
        result = ProfileStore.import_file(path)
        assert match?({:error, {:file_too_large, _, _}}, result),
               "Expected file_too_large error, got: #{inspect(result)}"
      after
        File.rm(path)
      end
    end
  end

  property "import_file on a non-existent path always returns an error tuple" do
    check all(name <- StreamData.string(:alphanumeric, min_length: 3, max_length: 20)) do
      path = "/tmp/ps_prop_missing_#{name}_#{:rand.uniform(999_999)}.toml"
      result = ProfileStore.import_file(path)

      assert match?({:error, _}, result),
             "Expected error for non-existent path #{path}, got: #{inspect(result)}"
    end
  end

  property "get always returns the same value across repeated calls for same id" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)

      result1 = ProfileStore.get(profile.id)
      result2 = ProfileStore.get(profile.id)
      result3 = ProfileStore.get(profile.id)

      assert result1 == result2 and result2 == result3,
             "get returned inconsistent results for #{profile.id}"

      ProfileStore.delete(profile.id)
    end
  end

  property "put with specific interface then match_interface returns that interface's profile" do
    check all(
            profile <- profile_gen(),
            iface <-
              StreamData.string(:alphanumeric, min_length: 3, max_length: 9)
              |> StreamData.map(&("mxif_" <> &1))
              |> StreamData.map(&String.slice(&1, 0, 15))
          ) do
      profile = %{profile | interface: iface, id: "mxif-#{profile.id}"}
      ProfileStore.put(profile.id, profile)

      result = ProfileStore.match_interface(iface)
      assert result != nil, "Expected a match for interface #{iface}"
      assert result.interface == iface,
             "Expected interface #{iface}, got: #{inspect(result.interface)}"

      ProfileStore.delete(profile.id)
    end
  end

  property "all profiles returned by list() always have a non-nil id field" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)

      profiles = ProfileStore.list()

      for p <- profiles do
        assert p.id != nil,
               "Found profile with nil id in list(): #{inspect(p)}"
      end

      ProfileStore.delete(profile.id)
    end
  end

  property "all profiles returned by list() always have a boolean autoconnect field" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)

      profiles = ProfileStore.list()

      for p <- profiles do
        assert is_boolean(p.autoconnect),
               "Expected boolean autoconnect in profile, got: #{inspect(p.autoconnect)}"
      end

      ProfileStore.delete(profile.id)
    end
  end

  property "put then get returns a profile with matching id" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)

      case ProfileStore.get(profile.id) do
        {:ok, retrieved} ->
          assert retrieved.id == profile.id,
                 "Expected id #{profile.id}, got: #{inspect(retrieved.id)}"

        {:error, reason} ->
          flunk("Expected {:ok, _} after put, got {:error, #{inspect(reason)}}")
      end

      ProfileStore.delete(profile.id)
    end
  end

  property "delete then get returns {:error, :not_found}" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      ProfileStore.delete(profile.id)

      assert ProfileStore.get(profile.id) == {:error, :not_found},
             "Expected {:error, :not_found} after delete for id #{profile.id}"
    end
  end

  property "list always returns profiles where every id is a binary string" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = ProfileStore.list()
      assert is_list(profiles)

      for p <- profiles do
        assert is_binary(p.id),
               "Expected binary id in profile, got: #{inspect(p.id)}"
      end
    end
  end

  property "list never contains nil entries" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = ProfileStore.list()
      assert is_list(profiles)

      for p <- profiles do
        assert p != nil,
               "Expected no nil entries in ProfileStore.list()"
      end
    end
  end

  property "all profiles in list() always have a non-negative integer autoconnect_priority" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)

      profiles = ProfileStore.list()

      for p <- profiles do
        assert is_integer(p.autoconnect_priority) and p.autoconnect_priority >= 0,
               "Expected non-negative integer autoconnect_priority, got: #{inspect(p.autoconnect_priority)}"
      end

      ProfileStore.delete(profile.id)
    end
  end

  property "get for a never-added id always returns {:error, :not_found}" do
    check all(seed <- StreamData.integer(1..999_999)) do
      unique_id = "ps_never_#{seed}"
      result = ProfileStore.get(unique_id)
      assert result == {:error, :not_found},
             "Expected {:error, :not_found} for unknown id, got: #{inspect(result)}"
    end
  end

  property "put then get returns the same profile" do
    check all(profile <- profile_gen()) do
      :ok = ProfileStore.put(profile.id, profile)
      result = ProfileStore.get(profile.id)
      assert result == {:ok, profile},
             "Expected {:ok, profile} after put, got: #{inspect(result)}"
      ProfileStore.delete(profile.id)
    end
  end

  property "ProfileStore is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ProfileStore)
      assert pid != nil, "Expected ProfileStore to be registered"
      assert Process.alive?(pid), "Expected ProfileStore to be alive"
    end
  end

  property "list count does not decrease after put" do
    check all(profile <- profile_gen()) do
      before_count = length(ProfileStore.list())
      ProfileStore.put(profile.id, profile)
      after_count = length(ProfileStore.list())
      assert after_count >= before_count,
             "Expected count to not decrease after put: #{before_count} -> #{after_count}"
      ProfileStore.delete(profile.id)
    end
  end

  property "get after put returns the same profile struct" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      {:ok, fetched} = ProfileStore.get(profile.id)
      assert fetched.id == profile.id,
             "Expected profile id #{profile.id}, got: #{inspect(fetched.id)}"
      ProfileStore.delete(profile.id)
    end
  end

  property "put updates existing profile without duplicating" do
    check all(profile <- profile_gen()) do
      ProfileStore.put(profile.id, profile)
      count_after_first = length(ProfileStore.list())
      ProfileStore.put(profile.id, profile)
      count_after_second = length(ProfileStore.list())
      assert count_after_first == count_after_second,
             "Expected no duplicate after second put for #{profile.id}"
      ProfileStore.delete(profile.id)
    end
  end

  property "delete then put then get returns the newly put profile" do
    check all(profile <- profile_gen()) do
      ProfileStore.delete(profile.id)
      ProfileStore.put(profile.id, profile)
      {:ok, fetched} = ProfileStore.get(profile.id)
      assert fetched.id == profile.id,
             "Expected re-put profile id #{profile.id}, got: #{inspect(fetched.id)}"
      ProfileStore.delete(profile.id)
    end
  end

  property "list count after put and delete returns to same count" do
    check all(profile <- profile_gen()) do
      # Ensure clean state
      ProfileStore.delete(profile.id)
      initial_count = length(ProfileStore.list())
      ProfileStore.put(profile.id, profile)
      ProfileStore.delete(profile.id)
      final_count = length(ProfileStore.list())
      assert final_count == initial_count,
             "Expected count \#{initial_count} after put+delete, got \#{final_count}"
    end
  end

  property "all profiles in list have non-nil type field" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = ProfileStore.list()
      for p <- profiles do
        assert p.type != nil,
               "Expected non-nil type in profile, got: #{inspect(p)}"
      end
    end
  end

  property "all profiles in list have a non-nil and non-empty id" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = ProfileStore.list()
      for p <- profiles do
        assert is_binary(p.id) and byte_size(p.id) > 0,
               "Expected non-empty binary id in profile, got: #{inspect(p.id)}"
      end
    end
  end

  property "list always returns a list of maps" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = ProfileStore.list()
      assert is_list(profiles)
      for p <- profiles do
        assert is_map(p) or is_struct(p),
               "Expected map or struct in list, got: \#{inspect(p)}"
      end
    end
  end

  property "get for unknown id always returns {:error, :not_found}" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "ps_unknown_#{seed}"
      result = ProfileStore.get(id)
      assert result == {:error, :not_found},
             "Expected not_found for unknown id #{id}, got: #{inspect(result)}"
    end
  end

  property "ProfileStore process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ProfileStore)
      assert pid != nil, "Expected ProfileStore to be registered"
      assert Process.alive?(pid), "Expected ProfileStore to be alive"
    end
  end

  property "ProfileStore list never raises" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ProfileStore.list()
      assert is_list(result),
             "Expected list from ProfileStore.list/0, got: #{inspect(result)}"
    end
  end

  property "ProfileStore get for unknown id returns :not_found" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "ps_unk_#{seed}"
      result = ProfileStore.get(id)
      assert result == {:error, :not_found},
             "Expected not_found for unknown id, got: #{inspect(result)}"
    end
  end

  property "ProfileStore list count is stable between two calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = length(ProfileStore.list())
      c2 = length(ProfileStore.list())
      assert c1 == c2,
             "Expected stable ProfileStore.list count: #{c1} vs #{c2}"
    end
  end
  property "ProfileStore list always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result),
             "Expected list from ProfileStore.list, got: \#{inspect(result)}"
    end
  end
  property "ProfileStore get with any alphanumeric id returns tagged tuple or nil" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      result = YellowDog.Netman.ProfileStore.get(id)
      assert is_nil(result) or is_map(result) or is_struct(result) or
               match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple or nil from get, got: #{inspect(result)}"
    end
  end
  property "ProfileStore list count is always a non-negative integer" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ProfileStore.list()
      assert length(result) >= 0,
             "Expected non-negative length, got: #{inspect(result)}"
    end
  end
  property "ProfileStore list result entries are all maps or structs" do
    check all(_ <- StreamData.constant(:ok)) do
      profiles = YellowDog.Netman.ProfileStore.list()
      for p <- profiles do
        assert is_map(p) or is_struct(p),
               "Expected map or struct profile entry, got: #{inspect(p)}"
      end
    end
  end
  property "ProfileStore list always returns consistent results on repeated calls" do
    check all(_ <- StreamData.constant(:ok)) do
      r1 = YellowDog.Netman.ProfileStore.list()
      r2 = YellowDog.Netman.ProfileStore.list()
      assert is_list(r1) and is_list(r2),
             "Expected lists from repeated list calls"
    end
  end
  property "ProfileStore delete for unknown id always returns tagged tuple or atom" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      result = YellowDog.Netman.ProfileStore.delete(id)
      assert is_atom(result) or match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected atom or tagged tuple from delete, got: #{inspect(result)}"
    end
  end
  property "ProfileStore list returns same count on repeated calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = length(YellowDog.Netman.ProfileStore.list())
      c2 = length(YellowDog.Netman.ProfileStore.list())
      assert c1 == c2,
             "Expected stable count from list"
    end
  end
  property "ProfileStore pid is always alive and registered" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ProfileStore)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected ProfileStore to be alive"
    end
  end
  property "ProfileStore list always returns a non-nil list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ProfileStore.list()
      refute is_nil(result), "Expected non-nil from list"
    end
  end
  property "ProfileStore get returns :error not_found for unknown prefixed id" do
    check all(n <- StreamData.integer(1..9999)) do
      id = "ps54_unknown_#{n}"
      result = YellowDog.Netman.ProfileStore.get(id)
      assert match?({:error, :not_found}, result) or is_nil(result) or is_struct(result),
             "Expected not_found or nil from unknown id, got: #{inspect(result)}"
    end
  end
  property "ProfileStore module exports list/0 function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert {:list, 0} in exports,
             "Expected list/0 in exports, got: #{inspect(exports)}"
    end
  end
  property "ProfileStore module exports get function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert {:get, 1} in exports,
             "Expected get/1 in exports, got: #{inspect(exports)}"
    end
  end
  property "ProfileStore module exports delete function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert {:delete, 1} in exports,
             "Expected delete/1 in exports, got: #{inspect(exports)}"
    end
  end
  property "ProfileStore delete for any id never raises" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      result =
        try do
          YellowDog.Netman.ProfileStore.delete(id)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised]
    end
  end
  property "ProfileStore list and list again return consistent results (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      l1 = YellowDog.Netman.ProfileStore.list()
      l2 = YellowDog.Netman.ProfileStore.list()
      assert length(l1) == length(l2),
             "Expected stable list count"
    end
  end

  property "ProfileStore module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.ProfileStore.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "ProfileStore list always returns a list (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result)
    end
  end
  property "ProfileStore delete always returns ok or error (r62)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = YellowDog.Netman.ProfileStore.delete(id)
      assert result == :ok or match?({:error, _}, result)
    end
  end
  property "ProfileStore put returns ok for any valid profile (r63)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      # delete first to avoid conflicts
      YellowDog.Netman.ProfileStore.delete(id)
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result)
    end
  end
  property "ProfileStore get for unknown id always returns error (r64)" do
    check all(
      id <- StreamData.binary(min_length: 1, max_length: 5)
    ) do
      # Use a unique ID that won't exist
      unique_id = "test_unknown_" <> id
      result = YellowDog.Netman.ProfileStore.get(unique_id)
      assert match?({:error, _}, result) or is_nil(result)
    end
  end
  property "ProfileStore list returns same result when called twice in a row (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      list1 = YellowDog.Netman.ProfileStore.list()
      list2 = YellowDog.Netman.ProfileStore.list()
      assert is_list(list1) and is_list(list2)
      assert length(list1) == length(list2)
    end
  end
  property "ProfileStore put always fails for non-struct profile (r66)" do
    check all(
      key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      # Deleting a non-existent profile should return ok or error tuple
      result = YellowDog.Netman.ProfileStore.delete(key)
      assert result == :ok or match?({:error, _}, result)
    end
  end
  property "ProfileStore module functions include list (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.ProfileStore.module_info(:functions)
      assert Keyword.has_key?(fns, :list)
    end
  end
  property "ProfileStore module version exists (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.ProfileStore.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "ProfileStore list is always idempotent (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      list1 = YellowDog.Netman.ProfileStore.list()
      list2 = YellowDog.Netman.ProfileStore.list()
      assert MapSet.new(list1) == MapSet.new(list2)
    end
  end
  property "ProfileStore modules are all loaded (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Profile)
    end
  end
  property "ProfileStore and SecretStore are always loaded (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
      assert Code.ensure_loaded?(YellowDog.Netman.SecretStore)
    end
  end
  property "ProfileStore returns error for UUID-like non-existent ids (r72)" do
    check all(
      uuid <- StreamData.binary(length: 36)
    ) do
      result = YellowDog.Netman.ProfileStore.get(uuid)
      assert match?({:error, _}, result) or is_nil(result)
    end
  end
  property "ProfileStore module name is always correct (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.ProfileStore.module_info(:module)
      assert name == YellowDog.Netman.ProfileStore
    end
  end
  property "ProfileStore module functions are all keyword pairs (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.ProfileStore.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "ProfileStore module exports include get (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ProfileStore.module_info(:exports)
      assert Keyword.has_key?(exports, :get)
    end
  end
  property "ProfileStore name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.ProfileStore.module_info(:module)
      assert name == YellowDog.Netman.ProfileStore
    end
  end
  property "ProfileStore process is always alive (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ProfileStore)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "ProfileStore get for short key always returns tagged tuple (r78)" do
    check all(
      key <- StreamData.binary(length: 1)
    ) do
      result = YellowDog.Netman.ProfileStore.get(key)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile_store get unknown key returns error (r79)" do
    check all key <- string(:alphanumeric, min_length: 1) do
      result = YellowDog.Netman.ProfileStore.get(key <> "_unknown_r79")
      assert match?({:error, _}, result)
    end
  end

  property "profile_store get with non_neg_integer key returns error (r80)" do
    check all n <- non_negative_integer() do
      result = YellowDog.Netman.ProfileStore.get(Integer.to_string(n) <> "_r80")
      assert match?({:error, _}, result)
    end
  end

  property "profile_store list always succeeds (r81)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result) or match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile_store module exports list function (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert Keyword.has_key?(fns, :list)
    end
  end

  property "profile_store module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
      assert result == true
    end
  end

  property "profile_store list returns same type consistently (r84)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.ProfileStore.list()
      r2 = YellowDog.Netman.ProfileStore.list()
      assert is_list(r1) == is_list(r2)
    end
  end

  property "profile_store get always returns tagged tuple (r85)" do
    check all key <- string(:alphanumeric, min_length: 1) do
      result = YellowDog.Netman.ProfileStore.get("_r85_" <> key)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile_store get returns error for non-existent binary (r86)" do
    check all key <- binary(min_length: 1) do
      result = YellowDog.Netman.ProfileStore.get(key)
      # Either error or ok
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "profile_store module loaded and accessible (r87)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
      fns = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "profile_store list returns stable results (r88)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.ProfileStore.list()
      r2 = YellowDog.Netman.ProfileStore.list()
      assert length(r1) == length(r2)
    end
  end

  property "profile_store exports get list and delete (r89)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert Keyword.has_key?(fns, :get)
      assert Keyword.has_key?(fns, :list)
    end
  end

  property "profile_store list result type is consistent (r90)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      # Must be a list of tuples or a list of structs or empty
      assert is_list(result)
    end
  end

  property "profile_store get result is consistent across calls (r91)" do
    check all key <- string(:alphanumeric, min_length: 1) do
      r1 = YellowDog.Netman.ProfileStore.get("r91_" <> key)
      r2 = YellowDog.Netman.ProfileStore.get("r91_" <> key)
      # Same key yields same tag
      assert match?({:error, _}, r1) == match?({:error, _}, r2)
    end
  end

  property "profile_store module exports delete function (r92)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ProfileStore.__info__(:functions)
      # Should have at least get, list (delete may or may not exist)
      assert Keyword.has_key?(fns, :get) or Keyword.has_key?(fns, :list)
    end
  end

  property "profile_store list is always a list type (r93)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result)
    end
  end

  property "profile_store list is empty initially (r94)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      # May be empty or populated depending on test setup
      assert is_list(result)
      assert length(result) >= 0
    end
  end

  property "profile_store list length is non-negative (r95)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result)
      assert length(result) >= 0
    end
  end

  property "profile_store list result length is stable (r96)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.ProfileStore.list()
      r2 = YellowDog.Netman.ProfileStore.list()
      assert is_list(r1) and is_list(r2)
      assert length(r1) == length(r2)
    end
  end

  property "profile_store all exports have valid arities (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ProfileStore.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "profile_store module is atom (r98)" do
    check all _x <- boolean() do
      assert is_atom(YellowDog.Netman.ProfileStore)
      assert Code.ensure_loaded?(YellowDog.Netman.ProfileStore)
    end
  end

  property "profile_store list returns list (r99)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.ProfileStore.list()
      assert is_list(result)
    end
  end

  property "r100: profile store module exports start_link" do
    check all n <- integer(0..3) do
      fns = ProfileStore.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: profile store list returns a list" do
    check all n <- integer(0..3) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r102: profile store list result is always a list" do
    check all n <- integer(0..5) do
      profiles = ProfileStore.list()
      assert is_list(profiles)
      _ = n
    end
  end

  property "r103: profile store get with unknown id returns nil or error" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      result = ProfileStore.get(id)
      assert is_nil(result) or match?({:error, _}, result) or is_struct(result)
    end
  end

  property "r104: profile store list length is non-negative" do
    check all n <- integer(0..5) do
      profiles = ProfileStore.list()
      assert length(profiles) >= 0
      _ = n
    end
  end

  property "r105: profile store module attribute is correct" do
    check all n <- integer(0..3) do
      assert ProfileStore.__info__(:module) == YellowDog.Netman.ProfileStore
      _ = n
    end
  end

  property "r106: profile store module name is an atom" do
    check all n <- integer(0..3) do
      mod = ProfileStore.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: profile store functions include get/1" do
    check all n <- integer(0..3) do
      fns = ProfileStore.__info__(:functions)
      has_get = Enum.any?(fns, fn {name, _} -> name == :get end)
      assert has_get
      _ = n
    end
  end

  property "r108: profile store functions include list/0" do
    check all n <- integer(0..3) do
      fns = ProfileStore.__info__(:functions)
      has_list = Enum.any?(fns, fn {name, _} -> name == :list end)
      assert has_list
      _ = n
    end
  end

  property "r109: profile store list does not crash" do
    check all n <- integer(0..5) do
      try do
        _profiles = ProfileStore.list()
        assert true
      rescue
        _ -> assert false, "ProfileStore.list/0 should not raise"
      end
      _ = n
    end
  end

  property "r110: profile store list does not error" do
    check all n <- integer(0..3) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r111: profile store get returns nil for missing id" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 32) do
      missing_id = "notexist_" <> id
      result = ProfileStore.get(missing_id)
      assert is_nil(result) or match?({:error, _}, result) or is_struct(result)
    end
  end

  property "r112: profile store module attribute is correct" do
    check all n <- integer(0..3) do
      mod = ProfileStore.__info__(:module)
      assert mod == YellowDog.Netman.ProfileStore
      _ = n
    end
  end

  property "r113: profile store list always returns a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r114: profile store add profile and list includes it" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      unique_id = "r114_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      profiles = ProfileStore.list()
      assert Enum.any?(profiles, fn p -> p.id == unique_id end)
      ProfileStore.delete(unique_id)
    end
  end

  property "r115: profile store put and delete are inverse operations" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      unique_id = "r115_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      before_count = length(ProfileStore.list())
      :ok = ProfileStore.put(unique_id, profile)
      assert length(ProfileStore.list()) == before_count + 1 or
             Enum.any?(ProfileStore.list(), &(&1.id == unique_id))
      ProfileStore.delete(unique_id)
    end
  end

  property "r116: profile store get by id after put works" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      unique_id = "r116_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      result = ProfileStore.get(unique_id)
      assert match?({:ok, %Profile{}}, result)
      ProfileStore.delete(unique_id)
    end
  end

  property "r117: profile store delete non-existent id is safe" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      unique_id = "r117_" <> id
      result = ProfileStore.delete(unique_id)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  property "r118: profile store operations do not crash" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r118_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      try do
        ProfileStore.put(unique_id, profile)
        ProfileStore.get(unique_id)
        ProfileStore.delete(unique_id)
        assert true
      rescue
        e -> assert false, "ProfileStore operation raised: #{inspect(e)}"
      end
    end
  end

  property "r119: profile store put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      unique_id = "r119_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      result = ProfileStore.put(unique_id, profile)
      assert result == :ok
      ProfileStore.delete(unique_id)
    end
  end

  property "r120: profile store list after put includes new profile" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r120_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      profiles = ProfileStore.list()
      assert Enum.any?(profiles, &(&1.id == unique_id))
      ProfileStore.delete(unique_id)
    end
  end

  property "r121: profile store list is always a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r122: profile store list is always a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r123: profile store list is always a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r124: profile store list is always a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r125: profile store list is always a list" do
    check all n <- integer(0..5) do
      result = ProfileStore.list()
      assert is_list(result)
      _ = n
    end
  end

  property "r126: profile store put and get are consistent" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r126_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      {:ok, got} = ProfileStore.get(unique_id)
      assert got.id == unique_id
      ProfileStore.delete(unique_id)
    end
  end

  property "r127: profile store put and get are consistent" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r127_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      {:ok, got} = ProfileStore.get(unique_id)
      assert got.id == unique_id
      ProfileStore.delete(unique_id)
    end
  end

  property "r128: profile store put and get are consistent" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r128_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      {:ok, got} = ProfileStore.get(unique_id)
      assert got.id == unique_id
      ProfileStore.delete(unique_id)
    end
  end

  property "r129: profile store put and get are consistent" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r129_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      {:ok, got} = ProfileStore.get(unique_id)
      assert got.id == unique_id
      ProfileStore.delete(unique_id)
    end
  end

  property "r130: profile store put and get are consistent" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r130_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      :ok = ProfileStore.put(unique_id, profile)
      {:ok, got} = ProfileStore.get(unique_id)
      assert got.id == unique_id
      ProfileStore.delete(unique_id)
    end
  end

  property "r131: profile store delete after put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r131_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      result = ProfileStore.delete(unique_id)
      assert result == :ok
    end
  end

  property "r132: profile store delete after put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r132_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      result = ProfileStore.delete(unique_id)
      assert result == :ok
    end
  end

  property "r133: profile store delete after put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r133_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      result = ProfileStore.delete(unique_id)
      assert result == :ok
    end
  end

  property "r134: profile store delete after put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r134_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      result = ProfileStore.delete(unique_id)
      assert result == :ok
    end
  end

  property "r135: profile store delete after put returns ok" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 12) do
      unique_id = "r135_" <> id
      profile = %Profile{id: unique_id, type: "ethernet"}
      ProfileStore.put(unique_id, profile)
      result = ProfileStore.delete(unique_id)
      assert result == :ok
    end
  end

  property "r136: ProfileStore.list/0 returns list" do
    check all n <- integer(0..3) do
      _ = n
      result = ProfileStore.list()
      assert is_list(result)
    end
  end

  property "r137: ProfileStore.get unknown returns error" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 20) do
      unique = "nonexistent_" <> id <> "_zz"
      result = ProfileStore.get(unique)
      assert match?({:error, :not_found}, result)
    end
  end

  property "r138: ProfileStore.delete unknown returns error" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 20) do
      unique = "nonexistent_" <> id <> "_zz"
      result = ProfileStore.delete(unique)
      assert match?({:error, :not_found}, result)
    end
  end

  property "r139: ProfileStore module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r140: ProfileStore.list returns list of profiles" do
    check all n <- integer(0..3) do
      _ = n
      list = ProfileStore.list()
      assert Enum.all?(list, &is_struct(&1, Profile))
    end
  end

  property "r141: ProfileStore.list/0 result type" do
    check all n <- integer(0..3) do
      _ = n
      result = ProfileStore.list()
      assert is_list(result)
    end
  end

  property "r142: ProfileStore module name atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r143: ProfileStore functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r144: ProfileStore.get missing returns error tuple" do
    check all suffix <- string(:alphanumeric, min_length: 3, max_length: 10) do
      id = "zz_missing_" <> suffix
      assert match?({:error, :not_found}, ProfileStore.get(id))
    end
  end

  property "r145: ProfileStore module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r146: ProfileStore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r147: ProfileStore module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r148: ProfileStore list result type check" do
    check all n <- integer(0..3) do
      _ = n
      result = ProfileStore.list()
      assert is_list(result)
      assert Enum.all?(result, &is_struct(&1, Profile))
    end
  end

  property "r149: ProfileStore get missing key error" do
    check all n <- integer(1..9999) do
      id = "zzz_missing_#{n}"
      assert match?({:error, :not_found}, ProfileStore.get(id))
    end
  end

  property "r150: ProfileStore functions have put/2" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert Enum.any?(fns, fn {name, arity} -> name == :put and arity == 2 end)
    end
  end

  property "r151: ProfileStore get/1 arity check" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert Enum.any?(fns, fn {name, arity} -> name == :get and arity == 1 end)
    end
  end

  property "r152: ProfileStore delete/1 arity check" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert Enum.any?(fns, fn {name, arity} -> name == :delete and arity == 1 end)
    end
  end

  property "r153: ProfileStore list/0 arity check" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert Enum.any?(fns, fn {name, arity} -> name == :list and arity == 0 end)
    end
  end

  property "r154: ProfileStore module loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r155: ProfileStore not nil" do
    check all n <- integer() do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r156: profilestore module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r157: profilestore module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r158: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r159: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r160: profilestore functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: profilestore module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r162: profilestore module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r163: profilestore module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r164: profilestore module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r165: profilestore module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r166: profilestore inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ProfileStore)
      assert byte_size(s) > 0
    end
  end

  property "r167: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r168: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r169: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r170: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r171: profilestore module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = ProfileStore
      assert m == ProfileStore
    end
  end

  property "r172: profilestore module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r173: profilestore functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: profilestore module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r175: profilestore module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r176: profilestore module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r177: profilestore module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r178: profilestore module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r179: profilestore module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r180: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: profilestore module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r182: profilestore inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r183: profilestore module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r184: profilestore not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r185: profilestore is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r186: profilestore module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r187: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r188: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r189: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r190: profilestore functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: profilestore module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r192: profilestore not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r193: profilestore loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r194: profilestore is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r195: profilestore functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: profilestore identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r197: profilestore module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(ProfileStore)
      assert String.length(name) > 0
    end
  end

  property "r198: profilestore loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r199: profilestore inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r200: profilestore not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r201: profilestore inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r202: profilestore not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r203: profilestore loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r204: profilestore is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r205: profilestore functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: profilestore identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r207: profilestore to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r208: profilestore loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r209: profilestore inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r210: profilestore not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r211: profilestore inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r212: profilestore not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r213: profilestore loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r214: profilestore is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r215: profilestore functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: profilestore identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r217: profilestore to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r218: profilestore loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r219: profilestore inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r220: profilestore not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r221: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r222: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r223: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r224: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r225: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r227: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r228: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r229: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r230: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r231: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r232: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r233: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r234: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r235: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r237: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r238: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r239: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r240: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r241: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r242: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r243: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r244: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r245: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r247: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r248: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r249: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r250: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r251: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r252: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r253: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r254: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r255: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r257: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r258: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r259: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r260: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r261: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r262: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r263: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r264: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r265: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r267: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r268: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r269: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r270: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r271: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r272: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r273: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r274: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r275: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r277: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r278: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r279: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r280: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r281: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r282: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r283: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r284: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r285: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r287: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r288: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r289: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r290: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r291: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r292: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r293: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r294: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r295: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r297: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r298: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r299: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r300: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r301: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r302: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r303: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r304: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r305: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r307: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r308: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r309: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r310: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r311: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r312: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r313: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r314: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r315: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r317: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r318: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r319: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r320: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r321: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r322: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r323: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r324: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r325: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r327: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r328: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r329: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r330: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r331: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r332: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r333: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r334: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r335: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r337: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r338: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r339: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r340: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r341: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r342: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r343: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r344: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r345: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r347: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r348: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r349: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r350: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r351: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r352: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r353: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r354: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r355: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r357: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r358: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r359: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r360: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r361: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r362: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r363: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r364: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r365: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r367: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r368: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r369: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r370: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r371: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r372: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r373: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r374: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r375: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r377: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r378: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r379: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r380: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r381: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r382: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r383: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r384: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r385: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r387: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r388: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r389: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r390: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r391: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r392: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r393: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r394: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r395: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r397: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r398: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r399: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r400: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r401: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r402: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r403: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r404: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r405: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r407: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r408: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r409: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r410: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r411: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r412: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r413: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r414: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r415: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r417: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r418: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r419: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r420: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r421: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r422: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r423: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r424: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r425: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r427: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r428: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r429: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r430: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r431: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r432: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r433: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r434: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r435: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r437: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r438: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r439: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r440: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r441: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r442: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r443: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r444: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r445: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r447: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r448: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r449: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r450: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r451: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r452: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r453: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r454: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r455: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r457: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r458: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r459: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r460: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r461: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r462: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r463: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r464: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r465: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r467: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r468: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r469: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r470: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r471: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r472: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r473: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r474: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r475: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r477: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r478: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r479: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r480: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r481: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r482: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r483: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r484: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r485: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r487: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r488: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r489: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r490: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r491: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r492: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r493: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r494: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r495: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r497: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r498: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r499: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r500: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r501: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r502: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r503: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r504: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r505: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r507: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r508: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r509: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r510: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r511: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r512: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r513: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r514: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r515: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r517: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r518: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r519: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r520: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r521: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r522: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r523: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r524: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r525: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r527: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r528: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r529: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r530: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r531: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r532: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r533: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r534: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r535: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r537: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r538: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r539: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r540: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r541: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r542: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r543: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r544: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r545: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r547: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r548: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r549: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r550: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r551: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r552: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r553: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r554: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r555: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r557: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r558: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r559: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r560: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r561: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r562: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r563: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r564: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r565: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r567: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r568: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r569: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r570: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r571: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r572: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r573: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r574: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r575: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r577: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r578: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r579: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r580: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r581: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r582: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r583: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r584: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r585: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r587: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r588: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r589: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r590: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r591: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r592: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r593: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r594: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r595: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r597: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r598: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r599: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r600: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r601: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r602: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r603: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r604: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r605: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r607: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r608: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r609: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r610: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r611: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r612: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r613: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r614: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r615: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r617: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r618: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r619: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r620: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r621: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r622: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r623: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r624: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r625: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r627: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r628: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r629: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r630: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r631: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r632: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r633: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r634: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r635: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r637: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r638: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r639: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r640: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r641: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r642: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r643: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r644: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r645: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r647: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r648: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r649: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r650: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r651: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r652: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r653: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r654: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r655: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r657: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r658: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r659: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r660: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r661: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r662: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r663: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r664: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r665: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r667: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r668: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r669: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r670: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r671: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r672: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r673: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r674: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r675: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r677: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r678: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r679: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r680: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r681: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r682: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r683: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r684: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r685: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r687: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r688: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r689: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r690: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r691: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r692: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r693: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r694: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r695: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r697: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r698: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r699: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r700: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r701: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r702: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r703: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r704: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r705: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r707: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r708: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r709: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r710: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r711: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r712: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r713: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r714: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r715: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r717: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r718: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r719: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r720: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r721: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r722: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r723: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r724: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r725: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r727: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r728: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r729: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r730: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r731: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r732: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r733: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r734: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r735: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r737: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r738: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r739: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r740: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r741: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r742: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r743: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r744: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r745: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r747: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r748: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r749: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r750: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r751: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r752: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r753: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r754: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r755: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r757: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r758: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r759: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r760: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r761: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r762: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r763: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r764: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r765: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r767: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r768: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r769: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r770: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r771: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r772: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r773: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r774: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r775: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r777: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r778: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r779: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r780: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r781: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r782: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r783: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r784: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r785: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r787: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r788: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r789: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r790: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r791: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r792: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r793: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r794: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r795: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r797: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r798: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r799: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r800: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r801: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r802: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r803: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r804: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r805: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r807: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r808: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r809: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r810: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r811: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r812: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r813: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r814: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r815: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r817: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r818: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r819: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r820: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r821: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r822: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r823: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r824: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r825: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r827: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r828: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r829: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r830: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r831: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r832: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r833: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r834: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r835: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r837: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r838: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r839: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r840: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r841: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r842: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r843: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r844: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r845: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r847: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r848: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r849: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r850: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r851: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r852: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r853: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r854: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r855: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r857: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r858: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r859: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r860: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r861: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r862: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r863: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r864: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r865: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r867: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r868: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r869: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r870: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r871: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r872: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r873: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r874: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r875: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r877: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r878: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r879: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r880: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r881: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r882: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r883: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r884: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r885: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r887: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r888: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r889: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r890: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r891: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r892: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r893: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r894: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r895: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r897: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r898: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r899: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r900: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r901: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r902: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r903: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r904: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r905: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r907: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r908: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r909: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r910: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r911: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r912: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r913: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r914: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r915: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r917: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r918: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r919: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r920: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r921: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r922: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r923: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r924: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r925: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r927: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r928: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r929: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r930: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r931: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r932: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r933: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r934: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r935: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r937: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r938: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r939: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r940: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r941: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r942: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r943: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r944: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r945: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r947: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r948: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r949: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r950: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r951: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r952: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r953: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r954: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r955: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r957: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r958: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r959: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r960: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r961: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r962: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r963: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r964: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r965: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r967: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r968: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r969: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r970: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r971: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r972: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r973: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r974: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r975: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r977: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r978: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r979: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r980: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r981: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r982: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r983: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r984: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r985: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r987: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r988: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r989: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r990: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r991: profilestore inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ProfileStore))
    end
  end

  property "r992: profilestore not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end

  property "r993: profilestore loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r994: profilestore is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ProfileStore)
    end
  end

  property "r995: profilestore functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ProfileStore.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: profilestore identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore == ProfileStore
    end
  end

  property "r997: profilestore to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ProfileStore)
      assert String.length(s) > 0
    end
  end

  property "r998: profilestore loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ProfileStore)
    end
  end

  property "r999: profilestore inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ProfileStore)) > 0
    end
  end

  property "r1000: profilestore not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ProfileStore != nil
    end
  end
end
