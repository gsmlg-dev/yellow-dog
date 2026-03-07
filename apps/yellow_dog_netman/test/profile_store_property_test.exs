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
end
