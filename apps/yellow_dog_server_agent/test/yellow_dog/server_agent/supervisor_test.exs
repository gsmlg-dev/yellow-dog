defmodule YellowDog.ServerAgent.SupervisorTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/client_fake_clock.ex", __DIR__)
  Code.require_file("../../support/client_fake_socket.ex", __DIR__)
  Code.require_file("../../support/client_fake_timer.ex", __DIR__)

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.ClientFakeMonotonicClock
  alias YellowDog.ServerAgent.ClientFakeSocket
  alias YellowDog.ServerAgent.ClientFakeTimer
  alias YellowDog.ServerAgent.ClientFakeWallClock
  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Dispatcher
  alias YellowDog.ServerAgent.Heartbeat
  alias YellowDog.ServerAgent.Supervisor, as: ServerAgentSupervisor
  alias YellowDog.Sync.Identity.Server

  defmodule OuterSupervisor do
    @moduledoc false

    use Supervisor

    def start_link(child_spec, name) do
      Supervisor.start_link(__MODULE__, child_spec, name: name)
    end

    @impl true
    def init(child_spec), do: Supervisor.init([child_spec], strategy: :one_for_one)
  end

  defmodule TestLifecycleStore do
    @moduledoc false

    use GenServer

    def start_link(raw_opts), do: GenServer.start_link(__MODULE__, raw_opts)
    def resolve(store), do: GenServer.call(store, :resolve)
    def save_prepared(store, prepared_opts), do: GenServer.call(store, {:save, prepared_opts})

    @impl true
    def init(raw_opts), do: {:ok, {:raw, raw_opts}}

    @impl true
    def handle_call(:resolve, _from, state), do: {:reply, state, state}

    def handle_call({:save, prepared_opts}, _from, {:raw, _raw_opts}),
      do: {:reply, :ok, {:prepared, prepared_opts}}

    def handle_call({:save, _prepared_opts}, _from, state),
      do: {:reply, :error, state}
  end

  defmodule TestLifecycleStart do
    @moduledoc false

    alias YellowDog.ServerAgent
    alias YellowDog.ServerAgent.Client
    alias YellowDog.ServerAgent.Supervisor, as: ServerAgentSupervisor
    alias YellowDog.ServerAgent.SupervisorTest.TestLifecycleStore

    def start_link(store) do
      case TestLifecycleStore.resolve(store) do
        {:raw, raw_opts} -> prepare_and_start(store, raw_opts)
        {:prepared, prepared_opts} -> ServerAgent.start_prepared_link(prepared_opts)
      end
    end

    defp prepare_and_start(store, raw_opts) do
      case ServerAgentSupervisor.prepare_options(raw_opts) do
        {:ok, prepared_opts} ->
          save_and_start(store, prepared_opts)

        {:error, :invalid_configuration} = error ->
          error
      end
    end

    defp save_and_start(store, prepared_opts) do
      case TestLifecycleStore.save_prepared(store, prepared_opts) do
        :ok ->
          ServerAgent.start_prepared_link(prepared_opts)

        :error ->
          prepared_opts
          |> Keyword.fetch!(:credential_ref)
          |> Client.release_credentials()

          {:error, :invalid_configuration}
      end
    end
  end

  @server_id "server-east-1"
  @profile "dns_only"
  @capabilities ["runtime.services"]
  @config_revision String.duplicate("a", 64)
  @token "top-secret-token"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-supervisor-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    ClientFakeSocket.configure(self())
    ClientFakeTimer.configure(self())
    ClientFakeMonotonicClock.configure([0])
    ClientFakeWallClock.configure([~U[2026-07-18 00:00:00Z]])

    on_exit(fn ->
      ClientFakeSocket.clear()
      ClientFakeTimer.clear()
      ClientFakeMonotonicClock.clear()
      ClientFakeWallClock.clear()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "unconfigured startup supervises only Heartbeat and preserves its name option" do
    heartbeat_name = unique_name(:heartbeat)

    supervisor =
      start_supervisor(
        name: heartbeat_name,
        supervisor_name: unique_name(:supervisor)
      )

    assert [{:heartbeat, heartbeat, :worker, [Heartbeat]}] =
             Supervisor.which_children(supervisor)

    assert heartbeat == Process.whereis(heartbeat_name)
  end

  test "init rejects prevalidated children and malformed direct arguments without crashing" do
    bypass_child = %{
      id: :bypass,
      start: {Task, :start_link, [fn -> :ok end]}
    }

    malformed_arguments = [
      {:validated, [bypass_child]},
      %{},
      :invalid,
      [{"name", unique_name(:heartbeat)}],
      [{:name, unique_name(:heartbeat)} | :malformed]
    ]

    for argument <- malformed_arguments do
      assert :ignore = ServerAgentSupervisor.init(argument)
    end
  end

  test "start_link returns controlled errors for malformed configuration and OTP names", %{
    data_dir: data_dir
  } do
    malformed_arguments = [
      %{},
      :invalid,
      {:validated, []},
      [{"name", unique_name(:heartbeat)}],
      [{:name, unique_name(:heartbeat)} | :malformed]
    ]

    for argument <- malformed_arguments do
      assert {:error, :invalid_configuration} = ServerAgentSupervisor.start_link(argument)
    end

    names = names()
    complete = complete_opts(data_dir, names)

    invalid_name_options = [
      Keyword.put(complete, :name, nil),
      Keyword.put(complete, :name, {:via, nil, :heartbeat}),
      Keyword.put(complete, :command_journal_name, {:via, nil, :journal}),
      Keyword.put(complete, :config_store_name, {unique_name(:store), node()}),
      Keyword.put(complete, :supervisor_name, {:via, nil, :supervisor}),
      Keyword.put(complete, :supervisor_name, {unique_name(:supervisor), node()})
    ]

    for opts <- invalid_name_options do
      assert {:error, :invalid_configuration} = ServerAgentSupervisor.start_link(opts)
    end
  end

  test "invalid outbound supervisor name creates no provider or credential-bearing result", %{
    data_dir: data_dir
  } do
    opts =
      data_dir
      |> complete_opts(names())
      |> Keyword.merge(outbound_opts())
      |> Keyword.put(:supervisor_name, {:via, nil, :supervisor})

    result =
      assert_no_process_spawn(fn ->
        ServerAgentSupervisor.start_link(opts)
      end)

    assert {:error, :invalid_configuration} = result
    refute contains_secret?(result, @token)
    refute contains_secret?(result, "management.example.test")
    refute contains_raw_credential_key?(result)
    refute contains_function?(result)
  end

  test "partial durable and outbound configuration fails fast", %{data_dir: data_dir} do
    durable = [
      data_dir: data_dir,
      server_id: @server_id,
      profile: @profile,
      capabilities: @capabilities
    ]

    for count <- 1..3 do
      for partial <- combinations(durable, count) do
        assert {:error, :invalid_configuration} =
                 ServerAgentSupervisor.start_link(
                   partial ++ [supervisor_name: unique_name(:partial)]
                 )
      end
    end

    outbound = [
      management_url: "https://management.example.test:4443",
      management_token: @token,
      server_name: "Server East",
      server_version: "1.2.3",
      config_revision: @config_revision,
      reconnect_initial_ms: 100,
      reconnect_max_ms: 1_000
    ]

    for count <- 1..6 do
      for partial <- combinations(outbound, count) do
        assert {:error, :invalid_configuration} =
                 ServerAgentSupervisor.start_link(complete_opts(data_dir, names()) ++ partial)
      end
    end
  end

  test "duplicate and unknown top-level options fail closed", %{data_dir: data_dir} do
    complete = complete_opts(data_dir, names())

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(complete ++ [server_id: @server_id])

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(complete ++ [unknown: true])

    outbound =
      complete
      |> Keyword.merge(outbound_opts())

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(outbound ++ [management_token: @token])
  end

  test "discarded outbound facade child specs spawn nothing and retain no credentials", %{
    data_dir: data_dir
  } do
    raw_opts =
      data_dir
      |> complete_opts(names())
      |> Keyword.merge(outbound_opts())

    child_spec =
      assert_no_process_spawn(fn ->
        YellowDog.ServerAgent.child_spec(raw_opts)
      end)

    assert {YellowDog.ServerAgent, :start_invalid, []} = child_spec.start
    refute contains_secret?(child_spec, @token)
    refute contains_secret?(child_spec, "management.example.test")
    refute contains_raw_credential_key?(child_spec)
    refute contains_function?(child_spec)
  end

  test "rejected outbound Supervisor child specs spawn nothing and retain no credentials", %{
    data_dir: data_dir
  } do
    raw_opts =
      data_dir
      |> complete_opts(names())
      |> Keyword.merge(outbound_opts())

    child_spec =
      assert_no_process_spawn(fn ->
        ServerAgentSupervisor.child_spec(raw_opts)
      end)

    assert {ServerAgentSupervisor, :start_invalid, []} = child_spec.start
    refute contains_secret?(child_spec, @token)
    refute contains_secret?(child_spec, "management.example.test")
    refute contains_raw_credential_key?(child_spec)
    refute contains_function?(child_spec)
  end

  test "heartbeat-only and durable-local module child specs are valid and side-effect-free", %{
    data_dir: data_dir
  } do
    durable_opts = complete_opts(data_dir, names())

    for {module, opts} <- [
          {YellowDog.ServerAgent, []},
          {YellowDog.ServerAgent, durable_opts},
          {ServerAgentSupervisor, []},
          {ServerAgentSupervisor, durable_opts}
        ] do
      child_spec =
        assert_no_process_spawn(fn ->
          module.child_spec(opts)
        end)

      assert {^module, :start_link, [^opts]} = child_spec.start
      refute contains_raw_credential_key?(child_spec)
      refute contains_function?(child_spec)
    end
  end

  test "complete durable configuration starts exact ordered local children without Client", %{
    data_dir: data_dir
  } do
    names = names()
    opts = complete_opts(data_dir, names)
    supervisor = start_supervisor(opts)

    assert {:ok, {_flags, child_specs}} = ServerAgentSupervisor.init(opts)

    assert Enum.map(child_specs, & &1.id) == [
             :heartbeat,
             :command_journal,
             :config_store,
             :config_apply_store,
             :config_applier
           ]

    assert Enum.map(child_specs, fn child_spec -> elem(child_spec.start, 0) end) == [
             Heartbeat,
             CommandJournal,
             ConfigStore,
             ConfigApplyStore,
             ConfigApplier
           ]

    assert Process.whereis(names.heartbeat)
    assert Process.whereis(names.command_journal)
    assert Process.whereis(names.config_store)
    assert Process.whereis(names.config_apply_store)
    assert Process.whereis(names.config_applier)
    refute Process.whereis(names.client)
    assert Process.whereis(names.supervisor) == supervisor
    refute_receive {:socket_start, _opts}
  end

  test "complete outbound configuration adds Client last with one concrete Server identity", %{
    data_dir: data_dir
  } do
    names = names()

    opts =
      data_dir
      |> complete_opts(names)
      |> Keyword.merge(outbound_opts())

    supervisor = start_supervisor(opts)

    assert supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse() ==
             [
               :heartbeat,
               :command_journal,
               :config_store,
               :config_apply_store,
               :config_applier,
               :client
             ]

    supervisor_state = :sys.get_state(supervisor)
    assert [{Client, :start_link, [client_opts]}] = start_mfas(supervisor_state, Client)

    assert %Server{
             id: @server_id,
             name: "Server East",
             version: "1.2.3",
             profile: @profile,
             capabilities: @capabilities,
             config_revision: @config_revision
           } = client_opts[:identity]

    assert client_opts[:command_journal] == names.command_journal
    assert client_opts[:config_applier] == names.config_applier
    assert client_opts[:config_apply_store] == names.config_apply_store
    assert client_opts[:initial_backoff] == 100
    assert client_opts[:max_backoff] == 1_000
    assert client_opts[:dispatcher] == Dispatcher
    assert client_opts[:dispatcher_runtime_adapter] == :"Elixir.YellowDog.Server.Control"
    assert client_opts[:credential_owner] == supervisor
    assert opaque_credential_ref?(client_opts[:credential_ref])

    assert Enum.sort(Keyword.keys(client_opts)) ==
             Enum.sort([
               :enabled,
               :name,
               :credential_ref,
               :credential_owner,
               :identity,
               :dispatcher,
               :dispatcher_runtime_adapter,
               :command_journal,
               :config_applier,
               :config_apply_store,
               :timer,
               :monotonic_clock,
               :wall_clock,
               :connection_poll_interval,
               :connect_timeout,
               :join_timeout,
               :push_timeout,
               :heartbeat_interval,
               :status_interval,
               :initial_backoff,
               :max_backoff
             ])

    refute contains_secret?(supervisor_state, @token)
    refute contains_secret?(supervisor_state, "management.example.test")
    refute contains_raw_credential_key?(supervisor_state)
    refute contains_function?(supervisor_state)
    assert Process.whereis(names.client)
    assert Process.alive?(supervisor)
    assert_receive {:socket_start, _opts}

    status =
      YellowDog.ServerAgent.status_snapshot(
        heartbeat: names.heartbeat,
        identity: client_opts[:identity],
        client: names.client,
        config_apply_store: names.config_apply_store
      )

    refute inspect(status) =~ @token
    refute inspect(status) =~ "management.example.test"
    refute inspect(status) =~ data_dir
  end

  test "facade direct start_link preserves raw compatibility and scrubs OTP state", %{
    data_dir: data_dir
  } do
    names = names()

    raw_opts =
      data_dir
      |> complete_opts(names)
      |> Keyword.merge(outbound_opts())

    assert {:ok, supervisor} = YellowDog.ServerAgent.start_link(raw_opts)
    Process.unlink(supervisor)
    client = wait_for_pid(names.client)
    client_state = :sys.get_state(client)
    credential_ref = client_state.config.credential_ref
    provider = provider_pid(credential_ref)

    assert client_state.config.credential_owner == self()
    assert_receive {:socket_start, _opts}

    supervisor_state = :sys.get_state(supervisor)

    for state <- [supervisor_state, client_state] do
      refute contains_secret?(state, @token)
      refute contains_secret?(state, "management.example.test")
      refute contains_function?(state)
    end

    refute contains_raw_credential_key?(supervisor_state)
    assert client_state.config.socket == Client.CredentialProvider
    assert client_state.socket == credential_ref

    provider_monitor = Process.monitor(provider)
    Supervisor.stop(supervisor)
    assert Process.alive?(provider)
    assert :ok = Client.release_credentials(credential_ref)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}
  end

  test "fixed role IDs avoid registered-name collisions and preserve restart behavior", %{
    data_dir: data_dir
  } do
    assert :ok = Application.stop(:yellow_dog_server_agent)

    try do
      names = %{
        heartbeat: unique_name(:heartbeat),
        command_journal: Heartbeat,
        config_store: unique_name(:config_store),
        config_apply_store: unique_name(:config_apply_store),
        config_applier: unique_name(:config_applier),
        client: unique_name(:client),
        supervisor: unique_name(:supervisor)
      }

      {:ok, supervisor} = ServerAgentSupervisor.start_link(complete_opts(data_dir, names))
      Process.unlink(supervisor)

      heartbeat = Process.whereis(names.heartbeat)
      journal = Process.whereis(names.command_journal)
      config_store = Process.whereis(names.config_store)
      config_apply_store = Process.whereis(names.config_apply_store)
      config_applier = Process.whereis(names.config_applier)

      assert Enum.map(Supervisor.which_children(supervisor), &elem(&1, 0)) == [
               :config_applier,
               :config_apply_store,
               :config_store,
               :command_journal,
               :heartbeat
             ]

      Process.exit(journal, :kill)
      restarted_journal = wait_for_restart(names.command_journal, journal)

      assert Process.whereis(names.heartbeat) == heartbeat
      assert Process.whereis(names.config_store) == config_store
      assert Process.whereis(names.config_apply_store) == config_apply_store
      assert Process.whereis(names.config_applier) == config_applier
      assert restarted_journal != journal

      Supervisor.stop(supervisor)
    after
      assert {:ok, _started} = Application.ensure_all_started(:yellow_dog_server_agent)
    end
  end

  test "child-only options reject shared identity and name overrides", %{data_dir: data_dir} do
    names = names()

    forbidden = [:name, :data_dir, :server_id, :profile, :capabilities]

    for child_opts_key <- [
          :command_journal_opts,
          :config_store_opts,
          :config_apply_store_opts,
          :config_applier_opts,
          :client_opts
        ],
        key <- forbidden do
      opts =
        data_dir
        |> complete_opts(names())
        |> Keyword.put(child_opts_key, [{key, "override"}])

      assert {:error, :invalid_configuration} = ServerAgentSupervisor.start_link(opts)
    end

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(
               complete_opts(data_dir, names)
               |> Keyword.put(:command_journal_opts, unknown: true)
             )

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(
               complete_opts(data_dir, names)
               |> Keyword.put(:config_store_opts, unknown: true)
             )

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(
               complete_opts(data_dir, names)
               |> Keyword.put(:config_apply_store_opts, unknown: true)
             )

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(
               complete_opts(data_dir, names)
               |> Keyword.put(:config_applier_opts, unknown: true)
             )

    assert {:error, :invalid_configuration} =
             ServerAgentSupervisor.start_link(
               complete_opts(data_dir, names)
               |> Keyword.merge(outbound_opts())
               |> Keyword.put(:client_opts, token: "override")
             )
  end

  test "one_for_one restarts durable apply children without restarting unrelated siblings", %{
    data_dir: data_dir
  } do
    names = names()
    supervisor = start_supervisor(complete_opts(data_dir, names))
    heartbeat = Process.whereis(names.heartbeat)
    journal = Process.whereis(names.command_journal)
    config_store = Process.whereis(names.config_store)
    config_apply_store = Process.whereis(names.config_apply_store)
    config_applier = Process.whereis(names.config_applier)

    Process.exit(config_apply_store, :kill)
    restarted_apply_store = wait_for_restart(names.config_apply_store, config_apply_store)

    assert Process.alive?(supervisor)
    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
    assert Process.whereis(names.config_applier) == config_applier
    assert restarted_apply_store != config_apply_store

    Process.exit(config_applier, :kill)
    restarted_applier = wait_for_restart(names.config_applier, config_applier)

    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
    assert Process.whereis(names.config_apply_store) == restarted_apply_store
    assert restarted_applier != config_applier
  end

  test "one_for_one restarts Heartbeat without restarting durable siblings", %{
    data_dir: data_dir
  } do
    names = names()
    supervisor = start_supervisor(complete_opts(data_dir, names))
    heartbeat = Process.whereis(names.heartbeat)
    journal = Process.whereis(names.command_journal)
    config_store = Process.whereis(names.config_store)
    config_apply_store = Process.whereis(names.config_apply_store)
    config_applier = Process.whereis(names.config_applier)

    Process.exit(heartbeat, :kill)
    restarted_heartbeat = wait_for_restart(names.heartbeat, heartbeat)

    assert Process.alive?(supervisor)
    assert restarted_heartbeat != heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
    assert Process.whereis(names.config_apply_store) == config_apply_store
    assert Process.whereis(names.config_applier) == config_applier
  end

  test "one_for_one restarts Client without restarting durable state owners", %{
    data_dir: data_dir
  } do
    names = names()

    supervisor =
      data_dir
      |> complete_opts(names)
      |> Keyword.merge(outbound_opts())
      |> start_supervisor()

    heartbeat = Process.whereis(names.heartbeat)
    journal = Process.whereis(names.command_journal)
    config_store = Process.whereis(names.config_store)
    config_apply_store = Process.whereis(names.config_apply_store)
    config_applier = Process.whereis(names.config_applier)
    client = Process.whereis(names.client)
    credential_ref = :sys.get_state(client).config.credential_ref
    provider = provider_pid(credential_ref)
    assert_receive {:socket_start, _opts}

    Process.exit(client, :kill)
    restarted_client = wait_for_restart(names.client, client)

    assert_receive {:socket_stop, _socket}
    assert_receive {:socket_start, _opts}
    assert Process.alive?(supervisor)
    assert Process.alive?(provider)
    assert restarted_client != client
    assert :sys.get_state(restarted_client).config.credential_ref == credential_ref
    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
    assert Process.whereis(names.config_apply_store) == config_apply_store
    assert Process.whereis(names.config_applier) == config_applier
  end

  test "test-owned late-bound lifecycle starts scrubbed outer specs across restarts", %{
    data_dir: data_dir
  } do
    names = names()
    outer_name = unique_name(:outer_supervisor)

    raw_opts =
      data_dir
      |> complete_opts(names)
      |> Keyword.merge(outbound_opts())

    {:ok, lifecycle_store} = TestLifecycleStore.start_link(raw_opts)

    child_spec = %{
      id: YellowDog.ServerAgent,
      start: {TestLifecycleStart, :start_link, [lifecycle_store]},
      type: :supervisor
    }

    refute contains_secret?(child_spec, @token)
    refute contains_secret?(child_spec, "management.example.test")
    refute contains_raw_credential_key?(child_spec)
    refute contains_function?(child_spec)

    {:ok, outer} = OuterSupervisor.start_link(child_spec, outer_name)
    Process.unlink(outer)

    on_exit(fn ->
      if Process.alive?(outer), do: Supervisor.stop(outer)
    end)

    agent = child_pid(outer, YellowDog.ServerAgent)
    client = wait_for_pid(names.client)
    credential_ref = :sys.get_state(client).config.credential_ref
    provider = provider_pid(credential_ref)
    outer_state = :sys.get_state(outer)
    inner_state = :sys.get_state(agent)

    for state <- [outer_state, inner_state] do
      refute contains_secret?(state, @token)
      refute contains_secret?(state, "management.example.test")
      refute contains_raw_credential_key?(state)
      refute contains_function?(state)
    end

    Process.exit(agent, :kill)
    restarted_agent = wait_for_child_restart(outer, YellowDog.ServerAgent, agent)
    restarted_client = wait_for_restart(names.client, client)

    assert restarted_agent != agent
    assert restarted_client != client
    assert Process.alive?(provider)
    assert :sys.get_state(restarted_client).config.credential_ref == credential_ref
    assert_receive {:socket_start, _opts}

    provider_monitor = Process.monitor(provider)
    Supervisor.stop(outer)
    assert_receive {:DOWN, ^provider_monitor, :process, ^provider, :normal}
  end

  defp start_supervisor(opts) do
    {:ok, supervisor} = ServerAgentSupervisor.start_link(opts)
    Process.unlink(supervisor)

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    supervisor
  end

  defp complete_opts(data_dir, names) do
    [
      data_dir: data_dir,
      server_id: @server_id,
      profile: @profile,
      capabilities: @capabilities,
      name: names.heartbeat,
      command_journal_name: names.command_journal,
      config_store_name: names.config_store,
      config_apply_store_name: names.config_apply_store,
      config_applier_name: names.config_applier,
      client_name: names.client,
      supervisor_name: names.supervisor,
      command_journal_opts: [max_records: 10],
      config_store_opts: [max_bytes: 1_000_000],
      config_apply_store_opts: [max_bytes: 1_000_000]
    ]
  end

  defp outbound_opts do
    [
      management_url: "https://management.example.test:4443",
      management_token: @token,
      server_name: "Server East",
      server_version: "1.2.3",
      config_revision: @config_revision,
      reconnect_initial_ms: 100,
      reconnect_max_ms: 1_000,
      client_opts: [
        socket: ClientFakeSocket,
        timer: ClientFakeTimer,
        monotonic_clock: ClientFakeMonotonicClock,
        wall_clock: ClientFakeWallClock,
        connection_poll_interval: 10,
        connect_timeout: 300,
        join_timeout: 400,
        push_timeout: 500,
        heartbeat_interval: 1_000,
        status_interval: 2_000
      ]
    ]
  end

  defp names do
    %{
      heartbeat: unique_name(:heartbeat),
      command_journal: unique_name(:journal),
      config_store: unique_name(:config_store),
      config_apply_store: unique_name(:config_apply_store),
      config_applier: unique_name(:config_applier),
      client: unique_name(:client),
      supervisor: unique_name(:supervisor)
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp combinations(_items, 0), do: [[]]
  defp combinations([], _count), do: []

  defp combinations([item | rest], count) do
    Enum.map(combinations(rest, count - 1), &[item | &1]) ++ combinations(rest, count)
  end

  defp wait_for_restart(name, old_pid, attempts \\ 100)

  defp wait_for_restart(_name, _old_pid, 0), do: flunk("child did not restart")

  defp wait_for_restart(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_restart(name, old_pid, attempts - 1)
    end
  end

  defp wait_for_pid(name, attempts \\ 100)

  defp wait_for_pid(_name, 0), do: flunk("process did not start")

  defp wait_for_pid(name, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_pid(name, attempts - 1)
    end
  end

  defp wait_for_child_restart(supervisor, id, old_pid, attempts \\ 100)

  defp wait_for_child_restart(_supervisor, _id, _old_pid, 0),
    do: flunk("supervised child did not restart")

  defp wait_for_child_restart(supervisor, id, old_pid, attempts) do
    case child_pid(supervisor, id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_child_restart(supervisor, id, old_pid, attempts - 1)
    end
  end

  defp child_pid(supervisor, id) do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, _type, _modules} -> pid
      nil -> nil
    end
  end

  defp start_mfas(value, module) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(&start_mfas(&1, module))
  end

  defp start_mfas({module, :start_link, [_opts]} = mfa, module), do: [mfa]

  defp start_mfas(value, module) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.flat_map(&start_mfas(&1, module))
  end

  defp start_mfas(value, module) when is_list(value),
    do: Enum.flat_map(value, &start_mfas(&1, module))

  defp start_mfas(_value, _module), do: []

  defp opaque_credential_ref?({provider, capability}),
    do: is_pid(provider) and is_reference(capability)

  defp provider_pid({provider, capability})
       when is_pid(provider) and is_reference(capability),
       do: provider

  defp assert_no_process_spawn(callback) do
    caller = self()
    tracer = spawn(fn -> collect_process_trace(caller, false) end)
    assert 1 = :erlang.trace(caller, true, [:procs, {:tracer, tracer}])

    try do
      result = callback.()
      trace_ref = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^trace_ref}
      snapshot_ref = make_ref()
      send(tracer, {:snapshot, caller, snapshot_ref})
      assert_receive {:process_trace_snapshot, ^snapshot_ref, spawned?}

      refute spawned?
      result
    after
      :erlang.trace(caller, false, [:procs])
      send(tracer, :stop)
    end
  end

  defp collect_process_trace(parent, spawned?) do
    receive do
      {:trace, _caller, :spawn, _pid, _mfa} ->
        collect_process_trace(parent, true)

      {:snapshot, ^parent, snapshot_ref} ->
        send(parent, {:process_trace_snapshot, snapshot_ref, spawned?})
        collect_process_trace(parent, spawned?)

      :stop ->
        :ok

      _other ->
        collect_process_trace(parent, spawned?)
    end
  end

  defp contains_secret?(value, secret) when is_binary(value),
    do: String.contains?(value, secret)

  defp contains_secret?(value, secret) when is_map(value),
    do:
      Enum.any?(Map.to_list(value), fn {key, item} ->
        contains_secret?(key, secret) or contains_secret?(item, secret)
      end)

  defp contains_secret?(value, secret) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_secret?(secret)

  defp contains_secret?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_secret?(&1, secret))

  defp contains_secret?(_value, _secret), do: false

  defp contains_raw_credential_key?(value) when is_map(value),
    do:
      Enum.any?(Map.to_list(value), fn {key, item} ->
        key in [:management_url, :management_token, :token, :socket, :params] or
          contains_raw_credential_key?(item)
      end)

  defp contains_raw_credential_key?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_raw_credential_key?()

  defp contains_raw_credential_key?(value) when is_list(value) do
    Enum.any?(value, fn
      {key, item} ->
        key in [:management_url, :management_token, :token, :socket, :params] or
          contains_raw_credential_key?(item)

      item ->
        contains_raw_credential_key?(item)
    end)
  end

  defp contains_raw_credential_key?(_value), do: false

  defp contains_function?(value) when is_function(value), do: true

  defp contains_function?(value) when is_map(value),
    do: value |> Map.to_list() |> contains_function?()

  defp contains_function?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_function?()

  defp contains_function?(value) when is_list(value), do: Enum.any?(value, &contains_function?/1)
  defp contains_function?(_value), do: false
end
