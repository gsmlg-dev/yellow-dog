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
end
