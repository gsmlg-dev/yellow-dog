defmodule YellowDog.Netman.ApplicationTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Application, as: NetmanApplication

  test "resolved profile controls Netman child specs and starts available agent" do
    profile = %{
      id: "netman-test-1",
      apply_mode: :observe,
      features: %{
        interfaces: false,
        dhcp_client: false,
        dns_client: false,
        routes: false,
        link_state: false,
        vpn: true
      },
      management: %{"enabled" => true}
    }

    assert NetmanApplication.child_specs_for_profile(profile) == [
             {YellowDog.NetmanAgent, [agent_id: "netman-test-1"]}
           ]
  end

  test "resolved profile can disable the Netman agent" do
    profile = %{
      apply_mode: :observe,
      features: %{interfaces: false, dhcp_client: false, dns_client: false, routes: false},
      management: %{"enabled" => false}
    }

    assert NetmanApplication.child_specs_for_profile(profile) == []
  end

  test "observe-first mode does not start reconciliation worker" do
    assert {:ok, {_flags, children}} =
             YellowDog.Netman.Supervisor.init(apply_mode: :observe_first)

    child_ids = Enum.map(children, & &1.id)

    refute YellowDog.Netman.ReconciliationEngine in child_ids
  end
end
