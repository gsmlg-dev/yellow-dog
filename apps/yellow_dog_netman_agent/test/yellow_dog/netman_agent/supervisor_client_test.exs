defmodule YellowDog.NetmanAgent.SupervisorClientTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/client_fake_socket.ex", __DIR__)
  Code.require_file("../../support/client_fake_timer.ex", __DIR__)
  Code.require_file("../../support/client_fake_clock.ex", __DIR__)

  alias YellowDog.NetmanAgent.Client
  alias YellowDog.NetmanAgent.ClientFakeMonotonicClock
  alias YellowDog.NetmanAgent.ClientFakeSocket
  alias YellowDog.NetmanAgent.ClientFakeTimer
  alias YellowDog.NetmanAgent.ClientFakeWallClock
  alias YellowDog.NetmanAgent.Heartbeat
  alias YellowDog.NetmanAgent.ConfigApplier
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.RollbackTimer
  alias YellowDog.NetmanAgent.Supervisor, as: NetmanAgentSupervisor
  alias YellowDog.Sync.Identity.Netman

  defmodule Dispatcher do
    @moduledoc false
    def dispatch(_envelope, _opts), do: {:error, :unused}
  end

  defmodule RuntimeAdapter do
    @behaviour YellowDog.NetmanAgent.RuntimeAdapter

    @impl true
    def validate_config(_payload), do: :ok

    @impl true
    def install_config(_payload, _opts), do: {:ok, String.duplicate("a", 64)}

    @impl true
    def activate_config(_revision), do: :ok

    @impl true
    def restore_config(_revision), do: :ok
  end

  test "puts the Client after every durable config owner and the applier" do
    journal_name = unique_name(:journal)
    config_store_name = unique_name(:config_store)
    config_apply_store_name = unique_name(:config_apply_store)
    rollback_timer_name = unique_name(:rollback_timer)
    config_applier_name = unique_name(:config_applier)
    client_name = unique_name(:client)

    opts = [
      enabled: true,
      data_dir: "/tmp/yellow-dog-netman-agent-order",
      netman_id: "netman-east-1",
      capabilities: ["runtime.capabilities"],
      command_journal_name: journal_name,
      config_store_name: config_store_name,
      config_apply_store_name: config_apply_store_name,
      rollback_timer_name: rollback_timer_name,
      config_applier_name: config_applier_name,
      rollback_window: 45_000,
      config_runtime_adapter: RuntimeAdapter,
      client_opts: client_opts(client_name)
    ]

    assert {:ok, {_flags, children}} = NetmanAgentSupervisor.init(opts)

    assert Enum.map(children, & &1.id) == [
             Heartbeat,
             journal_name,
             config_store_name,
             config_apply_store_name,
             rollback_timer_name,
             config_applier_name,
             client_name
           ]

    assert [_, _, _, apply_store_spec, rollback_timer_spec, applier_spec, client_spec] = children
    assert {ConfigApplyStore, :start_link, [apply_store_opts]} = apply_store_spec.start
    assert apply_store_opts[:config_store] == config_store_name

    assert {RollbackTimer, :start_link, [rollback_timer_opts]} = rollback_timer_spec.start
    assert rollback_timer_opts[:config_applier] == config_applier_name
    assert rollback_timer_opts[:rollback_window] == 45_000

    assert {ConfigApplier, :start_link, [applier_opts]} = applier_spec.start
    assert applier_opts[:config_store] == config_store_name
    assert applier_opts[:config_apply_store] == config_apply_store_name
    assert applier_opts[:rollback_timer] == rollback_timer_name
    assert applier_opts[:runtime_adapter] == RuntimeAdapter

    assert {Client, :start_link, [configured]} = client_spec.start
    assert configured[:command_journal] == journal_name
    assert configured[:config_store] == config_store_name
    assert configured[:config_apply_store] == config_apply_store_name
    assert configured[:config_applier] == config_applier_name
    assert configured[:rollback_timer] == rollback_timer_name
  end

  test "enabled mode fails closed without every durable owner option" do
    assert {:stop, :invalid_options} =
             NetmanAgentSupervisor.init(
               enabled: true,
               client_opts: client_opts(unique_name(:client))
             )
  end

  test "explicit disabled mode exposes a disabled Client without durable state" do
    assert {:ok, {_flags, children}} =
             NetmanAgentSupervisor.init(enabled: false, agent_id: "netman-disabled")

    assert Enum.map(children, & &1.id) == [Heartbeat, Client]
    assert [_, client_spec] = children
    assert {Client, :start_link, [[enabled: false]]} = client_spec.start
  end

  defp client_opts(name) do
    [
      enabled: true,
      management_url: "https://management.example.test:4443",
      token: "secret",
      identity: %Netman{
        id: "netman-east-1",
        name: "Netman East",
        version: "1.0.0",
        profile: "managed",
        capabilities: ["runtime.capabilities"],
        config_revision: String.duplicate("a", 64)
      },
      dispatcher: Dispatcher,
      dispatcher_runtime_adapter: Dispatcher,
      query_dispatcher: Dispatcher,
      query_runtime_adapter: Dispatcher,
      socket: ClientFakeSocket,
      timer: ClientFakeTimer,
      monotonic_clock: ClientFakeMonotonicClock,
      wall_clock: ClientFakeWallClock,
      connection_poll_interval: 50,
      connect_timeout: 500,
      join_timeout: 200,
      push_timeout: 200,
      heartbeat_interval: 1_000,
      status_interval: 2_000,
      initial_backoff: 100,
      max_backoff: 250,
      name: name
    ]
  end

  defp unique_name(tag) do
    {:global, {__MODULE__, tag, System.unique_integer([:positive])}}
  end
end
