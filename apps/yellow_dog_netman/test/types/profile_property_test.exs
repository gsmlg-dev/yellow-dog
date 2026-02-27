defmodule YellowDog.Netman.Types.ProfilePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.Types.Profile

  # Generators

  defp profile_id_gen do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 50)
    |> StreamData.map(&("profile-" <> &1))
  end

  defp ipv4_method_gen do
    StreamData.member_of(["auto", "manual", "disabled"])
  end

  defp ipv6_method_gen do
    StreamData.member_of(["auto", "manual", "disabled", "link-local"])
  end

  defp mtu_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.integer(68..65535)
    ])
  end

  defp valid_toml_gen do
    gen all(
          id <- profile_id_gen(),
          ipv4_method <- ipv4_method_gen(),
          ipv6_method <- ipv6_method_gen(),
          mtu <- mtu_gen(),
          priority <- StreamData.integer(0..1000),
          autoconnect <- StreamData.boolean()
        ) do
      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "autoconnect" => autoconnect,
          "autoconnect_priority" => priority
        },
        "ipv4" => %{"method" => ipv4_method},
        "ipv6" => %{"method" => ipv6_method}
      }

      if mtu do
        put_in(toml, ["ethernet"], %{"mtu" => mtu})
      else
        toml
      end
    end
  end

  # Property tests

  property "from_toml always succeeds for valid input" do
    check all(toml <- valid_toml_gen()) do
      assert {:ok, %Profile{}} = Profile.from_toml(toml)
    end
  end

  property "round-trip: parse(to_toml(parse(toml))) == parse(toml)" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile1} = Profile.from_toml(toml)
      toml2 = Profile.to_toml(profile1)
      {:ok, profile2} = Profile.from_toml(toml2)

      assert profile1.id == profile2.id
      assert profile1.type == profile2.type
      assert profile1.autoconnect == profile2.autoconnect
      assert profile1.autoconnect_priority == profile2.autoconnect_priority
      assert profile1.ipv4.method == profile2.ipv4.method
      assert profile1.ipv6.method == profile2.ipv6.method
      assert profile1.ethernet.mtu == profile2.ethernet.mtu
    end
  end

  property "from_toml preserves all fields" do
    check all(toml <- valid_toml_gen()) do
      {:ok, profile} = Profile.from_toml(toml)

      assert profile.id == toml["connection"]["id"]
      assert profile.type == :ethernet
      assert profile.autoconnect == toml["connection"]["autoconnect"]
      assert profile.autoconnect_priority == toml["connection"]["autoconnect_priority"]
    end
  end
end
