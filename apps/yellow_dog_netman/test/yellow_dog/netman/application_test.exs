defmodule YellowDog.Netman.ApplicationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Application, as: NetmanApplication
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Sync.Identity.Netman, as: NetmanIdentity
  alias __MODULE__.NetmanAgentFake

  @valid_agent_runtime [
    management_url: "https://management.example.test:4443",
    management_token: "local-secret",
    netman_id: "netman-bootstrap-1",
    data_dir: "/var/lib/yellow-dog/netman-agent",
    reconnect_initial_ms: nil,
    reconnect_max_ms: nil
  ]

  setup do
    previous = Application.fetch_env(:yellow_dog_netman_agent, :runtime)
    Application.delete_env(:yellow_dog_netman_agent, :runtime)

    on_exit(fn -> restore_env(previous) end)
  end

  test "valid local management bootstrap starts Netman runtime before the outbound agent" do
    Application.put_env(:yellow_dog_netman_agent, :runtime, @valid_agent_runtime)

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
             {YellowDog.Netman.Supervisor,
              [
                features: profile.features,
                apply_mode: :observe
              ]},
             %{
               id: YellowDog.NetmanAgent,
               start: {NetmanApplication, :start_netman_agent, [YellowDog.NetmanAgent, profile]},
               type: :supervisor
             }
           ]
  end

  test "incomplete or invalid local management bootstrap never starts an outbound agent" do
    profile = %{
      apply_mode: :observe,
      features: %{interfaces: false, dhcp_client: false, dns_client: false, routes: false},
      management: %{"enabled" => true}
    }

    for runtime <- [
          [],
          Keyword.delete(@valid_agent_runtime, :management_token),
          Keyword.put(@valid_agent_runtime, :management_url, "http://management.example.test"),
          Keyword.put(@valid_agent_runtime, :netman_id, "../netman"),
          Keyword.put(@valid_agent_runtime, :data_dir, "relative/agent")
        ] do
      Application.put_env(:yellow_dog_netman_agent, :runtime, runtime)

      assert NetmanApplication.child_specs_for_profile(profile) == [
               {RuntimeState, [features: profile.features, apply_mode: :observe]}
             ]
    end
  end

  test "outbound startup uses local bootstrap credentials and runtime-owned identity" do
    Application.put_env(:yellow_dog_netman_agent, :runtime, @valid_agent_runtime)
    NetmanAgentFake.configure(self())
    on_exit(&NetmanAgentFake.clear/0)

    profile = %{
      id: "management-must-not-override-id",
      name: "Netman East",
      profile: :custom,
      apply_mode: :managed,
      features: %{},
      management: %{"enabled" => true}
    }

    assert {:ok, agent} = NetmanApplication.start_netman_agent(NetmanAgentFake, profile)
    assert_receive {:netman_agent_start, opts}

    assert opts[:enabled]
    assert opts[:data_dir] == "/var/lib/yellow-dog/netman-agent"
    assert opts[:netman_id] == "netman-bootstrap-1"
    assert opts[:config_runtime_adapter] == YellowDog.Netman.Control.ConfigRuntimeAdapter

    assert %NetmanIdentity{
             id: "netman-bootstrap-1",
             name: "Netman East",
             profile: "custom",
             capabilities: capabilities,
             config_revision: revision
           } = opts[:client_opts][:identity]

    assert "profiles.write" in capabilities
    assert is_binary(revision)
    assert opts[:client_opts][:management_url] == "https://management.example.test:4443"
    assert opts[:client_opts][:token] == "local-secret"
    refute inspect(opts[:client_opts][:identity]) =~ "local-secret"
    refute inspect(opts[:client_opts][:identity]) =~ "/var/lib/yellow-dog"

    assert {:ok, {_flags, children}} = YellowDog.NetmanAgent.Supervisor.init(opts)
    assert List.last(children).id == YellowDog.NetmanAgent.Client

    GenServer.stop(agent)
  end

  test "resolved profile can disable the Netman agent" do
    Application.put_env(:yellow_dog_netman_agent, :runtime, @valid_agent_runtime)

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

  test "legacy console socket configuration cannot add an outbound client" do
    previous_config = Application.get_env(:yellow_dog_netman, :console)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:yellow_dog_netman, :console)
      else
        Application.put_env(:yellow_dog_netman, :console, previous_config)
      end
    end)

    Application.delete_env(:yellow_dog_netman, :console)

    assert {:ok, {_flags, baseline_children}} =
             YellowDog.Netman.Supervisor.init(apply_mode: :observe_first)

    Application.put_env(:yellow_dog_netman, :console,
      enabled: true,
      url: "ws://legacy.example.test/netman/ws/websocket",
      token: "legacy-token"
    )

    assert {:ok, {_flags, configured_children}} =
             YellowDog.Netman.Supervisor.init(apply_mode: :observe_first)

    assert Enum.map(configured_children, & &1.id) == Enum.map(baseline_children, & &1.id)
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

  defp restore_env({:ok, value}),
    do: Application.put_env(:yellow_dog_netman_agent, :runtime, value)

  defp restore_env(:error), do: Application.delete_env(:yellow_dog_netman_agent, :runtime)

  defmodule NetmanAgentFake do
    @key {__MODULE__, :owner}

    def configure(owner), do: :persistent_term.put(@key, owner)
    def clear, do: :persistent_term.erase(@key)

    def start_link(opts) do
      send(:persistent_term.get(@key), {:netman_agent_start, opts})
      Agent.start_link(fn -> :running end)
    end
  end
end
