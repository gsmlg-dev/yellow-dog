defmodule YellowDog.Server.Control.DhcpTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dhcp
  alias YellowDog.Sync.Error

  @adapters %{
    "ipv4" => YellowDog.ServerControlFake.Adapter.Dhcpv4,
    "ipv6" => YellowDog.ServerControlFake.Adapter.Dhcpv6
  }

  setup do
    previous = Application.get_env(:yellow_dog, Dhcp)
    Application.put_env(:yellow_dog, Dhcp, adapters: @adapters)
    start_supervised!(YellowDog.ServerControlFake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog, Dhcp, previous),
        else: Application.delete_env(:yellow_dog, Dhcp)
    end)

    :ok
  end

  test "routes IPv4 and IPv6 dispatch and current unchanged through fixed adapters" do
    for {family, route} <- [{"ipv4", :dhcpv4}, {"ipv6", :dhcpv6}] do
      payload = %{"family" => family, "pool_id" => "office", "route" => "ignored"}
      current = %{family: family, pool_id: "office"}
      response = %{family: family, status: :running}

      YellowDog.ServerControlFake.configure(route,
        current: {:ok, current},
        response: {:ok, response}
      )

      assert {:ok, ^response} = Dhcp.dispatch("server.dhcp.status.get", payload)
      assert {:ok, ^current} = Dhcp.current("server.dhcp.pools.delete", payload)

      assert [
               {^route, :dispatch, "server.dhcp.status.get", ^payload},
               {^route, :current, "server.dhcp.pools.delete", ^payload}
             ] = YellowDog.ServerControlFake.take_calls()
    end
  end

  test "returns invalid without invoking a family adapter for missing or unknown families" do
    for payload <- [%{}, %{"family" => "ipv7"}, %{"family" => nil}] do
      assert_invalid(Dhcp.dispatch("server.dhcp.status.get", payload))
      assert_invalid(Dhcp.current("server.dhcp.pools.delete", payload))
    end

    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "returns unsupported when a known family adapter is unavailable or incomplete" do
    Application.put_env(:yellow_dog, Dhcp,
      adapters: %{"ipv4" => YellowDog.ServerControlFake.MissingAdapter}
    )

    payload = %{"family" => "ipv4"}

    assert_unsupported(Dhcp.dispatch("server.dhcp.status.get", payload))
    assert_unsupported(Dhcp.current("server.dhcp.pools.delete", payload))

    Application.put_env(:yellow_dog, Dhcp,
      adapters: %{"ipv4" => YellowDog.ServerControlFake.ServiceRegistry}
    )

    assert_unsupported(Dhcp.dispatch("server.dhcp.status.get", payload))
    assert_unsupported(Dhcp.current("server.dhcp.pools.delete", payload))
    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "rejects test adapter overrides outside the fixed family keys" do
    Application.put_env(:yellow_dog, Dhcp,
      adapters: %{"caller_selected" => YellowDog.ServerControlFake.Adapter.Dhcpv4}
    )

    assert_internal(Dhcp.dispatch("server.dhcp.status.get", %{"family" => "ipv4"}))
    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  defp assert_invalid({:error, %Error{code: :invalid}}), do: :ok
  defp assert_invalid(other), do: flunk("expected invalid error, got: #{inspect(other)}")

  defp assert_unsupported({:error, %Error{code: :unsupported}}), do: :ok
  defp assert_unsupported(other), do: flunk("expected unsupported error, got: #{inspect(other)}")

  defp assert_internal({:error, %Error{code: :internal}}), do: :ok
  defp assert_internal(other), do: flunk("expected internal error, got: #{inspect(other)}")
end
