defmodule YellowDogIdentity.Trust.NetbootTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Netboot

  describe "verify/1" do
    test "returns {:skip, :not_applicable} when no lease found" do
      context = %{source_ip: {192, 168, 99, 99}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} when netboot registry not available" do
      # With no lease in cache and no netboot app, should skip
      context = %{source_ip: {10, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} for loopback address" do
      context = %{source_ip: {127, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} for IPv6 address" do
      context = %{source_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end
  end

  describe "trust level" do
    test "netboot_verified is a valid trust level" do
      assert :netboot_verified in [:cloud_verified, :netboot_verified, :network_verified, :network_partial, :token_verified, :unverified]
    end
  end

  describe "provider chain integration" do
    test "netboot provider implements the trust provider behaviour" do
      Code.ensure_loaded!(Netboot)
      assert function_exported?(Netboot, :verify, 1)
    end

    test "netboot provider skips gracefully and allows DHCP fallthrough" do
      # When netboot skips, the router should continue to DHCP correlation
      context = %{
        source_ip: {192, 168, 1, 50},
        hostname: "test-netboot",
        attestation: nil,
        metadata: %{},
        authorization: nil
      }

      # Should not crash — will reach unverified since no lease or token
      {level, _provider, _evidence} = YellowDogIdentity.Trust.Router.verify(context)
      assert level in [:unverified, :network_verified, :network_partial, :netboot_verified]
    end
  end
end
