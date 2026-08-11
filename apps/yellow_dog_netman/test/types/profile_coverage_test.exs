defmodule YellowDog.Netman.Types.ProfileCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in Types.Profile:
  - validate_interface/1 with non-string non-nil value
  - require_string/2 with non-string value
  - validate_gateway/2 with non-string non-nil value
  - validate_dns_list/2 with non-list value
  - serialize_method(:link_local) in to_toml
  """
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Types.Profile

  describe "validate_interface with non-string type" do
    test "integer interface returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet", "interface" => 123}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "must be a string"
    end

    test "boolean interface returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet", "interface" => true}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "must be a string"
    end
  end

  describe "require_string with non-string value" do
    test "integer connection.id returns error" do
      toml = %{
        "connection" => %{"id" => 123, "type" => "ethernet"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "must be a string"
    end
  end

  describe "validate_gateway with non-string type" do
    test "integer ipv4 gateway returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "manual",
          "address" => "10.0.0.1/24",
          "gateway" => 12_345
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv4.gateway must be a string"
    end

    test "integer ipv6 gateway returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv6" => %{"method" => "auto", "gateway" => 12_345}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv6.gateway must be a string"
    end
  end

  describe "validate_dns_list with non-list value" do
    test "string ipv4 dns returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "auto", "dns" => "8.8.8.8"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv4.dns must be a list"
    end

    test "integer ipv6 dns returns error" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv6" => %{"method" => "auto", "dns" => 42}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv6.dns must be a list"
    end
  end

  describe "to_toml serialize_method :link_local" do
    test "link_local ipv6 serializes to 'link-local'" do
      profile = %Profile{
        id: "link-local-test",
        type: :ethernet,
        ipv6: %{method: :link_local, address: nil, gateway: nil, dns: []}
      }

      toml = Profile.to_toml(profile)
      assert get_in(toml, ["ipv6", "method"]) == "link-local"
    end

    test "link_local ipv6 round-trips correctly" do
      profile = %Profile{
        id: "link-local-rt",
        type: :ethernet,
        ipv6: %{method: :link_local, address: nil, gateway: nil, dns: []}
      }

      toml = Profile.to_toml(profile)
      assert {:ok, parsed} = Profile.from_toml(toml)
      assert parsed.ipv6.method == :link_local
    end
  end

  describe "validate_dns_list with non-string element" do
    test "DNS list containing a non-string entry returns invalid address error" do
      # The inner Enum.reject fn has a _ -> false catch-all (line 255) for non-string elements
      toml = %{
        "connection" => %{"id" => "dns-nonstr", "type" => "ethernet"},
        "ipv4" => %{"method" => "auto", "dns" => [123, "8.8.8.8"]}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid addresses"
    end
  end

  describe "valid_cidr? with IPv6 address" do
    test "IPv6 CIDR as ipv4.address value is rejected" do
      toml = %{
        "connection" => %{"id" => "ipv6-cidr", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "2001:db8::1/64"}
      }

      assert {:error, message} = Profile.from_toml(toml)
      assert message =~ "ipv4.address"
    end
  end
end
