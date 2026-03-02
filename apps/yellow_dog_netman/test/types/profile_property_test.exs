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

  defp ipv4_address_gen do
    gen all(
          a <- StreamData.integer(1..254),
          b <- StreamData.integer(0..255),
          c <- StreamData.integer(0..255),
          d <- StreamData.integer(1..254),
          prefix <- StreamData.integer(8..30)
        ) do
      "#{a}.#{b}.#{c}.#{d}/#{prefix}"
    end
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
          autoconnect <- StreamData.boolean(),
          ipv4_address <- ipv4_address_gen()
        ) do
      ipv4 =
        if ipv4_method == "manual" do
          %{"method" => ipv4_method, "address" => ipv4_address}
        else
          %{"method" => ipv4_method}
        end

      toml = %{
        "connection" => %{
          "id" => id,
          "type" => "ethernet",
          "autoconnect" => autoconnect,
          "autoconnect_priority" => priority
        },
        "ipv4" => ipv4,
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

  property "IPv4 CIDR prefix must be 0-32" do
    check all(
            id <- profile_id_gen(),
            prefix <- StreamData.integer(33..128)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "10.0.0.1/#{prefix}"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "valid CIDR"
    end
  end

  property "IPv4 CIDR with valid prefix 0-32 is accepted" do
    check all(
            id <- profile_id_gen(),
            prefix <- StreamData.integer(0..32),
            a <- StreamData.integer(1..254),
            d <- StreamData.integer(1..254)
          ) do
      toml = %{
        "connection" => %{"id" => id, "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "#{a}.0.0.#{d}/#{prefix}"}
      }

      assert {:ok, %Profile{}} = Profile.from_toml(toml)
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
