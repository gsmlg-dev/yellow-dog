defmodule YellowDog.Netman.ApplicationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Application, as: NetmanApplication
  alias YellowDog.Netman.RuntimeState

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
             {RuntimeState,
              [
                features: profile.features,
                apply_mode: :observe
              ]},
             {YellowDog.NetmanAgent, [agent_id: "netman-test-1"]}
           ]
  end

  test "resolved profile can disable the Netman agent" do
    profile = %{
      apply_mode: :observe,
      features: %{interfaces: false, dhcp_client: false, dns_client: false, routes: false},
      management: %{"enabled" => false}
    }

    assert NetmanApplication.child_specs_for_profile(profile) == [
             {RuntimeState,
              [
                features: profile.features,
                apply_mode: :observe
              ]}
           ]
  end

  test "observe-first mode does not start reconciliation worker" do
    assert {:ok, {_flags, children}} =
             YellowDog.Netman.Supervisor.init(apply_mode: :observe_first)

    child_ids = Enum.map(children, & &1.id)

    refute YellowDog.Netman.ReconciliationEngine in child_ids
    refute RuntimeState in child_ids
  end

  test "runtime state and network runtime are one-for-one application siblings" do
    profile = %{
      apply_mode: :managed,
      features: %{
        interfaces: true,
        dhcp_client: false,
        dns_client: false,
        routes: false,
        link_state: true,
        vpn: false
      },
      management: %{"enabled" => false}
    }

    assert NetmanApplication.child_specs_for_profile(profile) == [
             {RuntimeState, [features: profile.features, apply_mode: :managed]},
             {YellowDog.Netman.Supervisor, [features: profile.features, apply_mode: :managed]}
           ]
  end

  test "runtime-state restart is isolated from sibling processes" do
    runtime_name = :"runtime-state-#{System.unique_integer([:positive])}"
    sibling_name = :"runtime-state-sibling-#{System.unique_integer([:positive])}"

    children = [
      Supervisor.child_spec(
        {RuntimeState, name: runtime_name, apply_mode: :observe_first, features: %{vpn: true}},
        id: runtime_name
      ),
      %{
        id: sibling_name,
        start: {Agent, :start_link, [fn -> :running end, [name: sibling_name]]}
      }
    ]

    supervisor =
      start_supervised!(%{
        id: :"runtime-state-supervisor-#{System.unique_integer([:positive])}",
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

    runtime_pid = Process.whereis(runtime_name)
    sibling_pid = Process.whereis(sibling_name)

    Process.exit(runtime_pid, :kill)

    assert eventually(fn ->
             replacement = Process.whereis(runtime_name)
             is_pid(replacement) and replacement != runtime_pid
           end)

    assert {:ok, restarted_state} = RuntimeState.snapshot(runtime_name)
    assert restarted_state.apply_mode == :observe_first

    assert restarted_state.features ==
             Map.new(YellowDog.Netman.FeatureRegistry.list_features(), fn feature ->
               {feature, feature == :vpn}
             end)

    assert Process.whereis(sibling_name) == sibling_pid
    assert Process.alive?(supervisor)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
