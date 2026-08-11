defmodule YellowDog.Netman.Control.VpnTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Control.Vpn
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  setup do
    previous = Application.get_env(:yellow_dog_netman, Vpn)
    Application.put_env(:yellow_dog_netman, Vpn, profile_resolver: VpnProfileResolverStub)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:yellow_dog_netman, Vpn)
      else
        Application.put_env(:yellow_dog_netman, Vpn, previous)
      end

      :persistent_term.erase({VpnProfileResolverStub, :profile})
    end)

    :ok
  end

  test "projects vpn_gateway and enabled custom profiles as resolved configuration state" do
    for profile <- [:vpn_gateway, :custom] do
      VpnProfileResolverStub.configure(%{profile: profile, features: %{vpn: true}})

      assert {:ok, result} = Vpn.dispatch("netman.vpn.profile.get", %{})

      projected = %{"profile_id" => Atom.to_string(profile), "state" => "resolved"}
      assert {:ok, revision} = Digest.calculate(projected)
      assert result == Map.put(projected, "revision", revision)
      assert_valid_result(result)
    end
  end

  test "projects profiles without VPN configuration as unavailable" do
    VpnProfileResolverStub.configure(%{profile: :custom, features: %{vpn: false}})

    assert {:ok, result} = Vpn.dispatch("netman.vpn.profile.get", %{})

    projected = %{"profile_id" => "custom", "state" => "unavailable"}
    assert {:ok, revision} = Digest.calculate(projected)
    assert result == Map.put(projected, "revision", revision)
    assert_valid_result(result)
  end

  test "has no tunnel, peer, key, or lifecycle mutation surface" do
    for operation <- [
          "netman.vpn.tunnels.start",
          "netman.vpn.tunnels.stop",
          "netman.vpn.peers.put",
          "netman.vpn.peers.delete",
          "netman.vpn.keys.generate"
        ] do
      assert {:error, %Error{code: :unsupported}} = Vpn.dispatch(operation, %{})
      assert {:error, %Error{code: :invalid}} = NetmanOperation.fetch(operation)
    end

    refute function_exported?(Vpn, :current, 2)
    refute function_exported?(Vpn, :dispatch, 3)
  end

  defp assert_valid_result(result) do
    assert {:ok, operation} = NetmanOperation.fetch("netman.vpn.profile.get")
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end
end

defmodule VpnProfileResolverStub do
  def configure(profile), do: :persistent_term.put({__MODULE__, :profile}, profile)
  def resolve, do: :persistent_term.get({__MODULE__, :profile})
end
