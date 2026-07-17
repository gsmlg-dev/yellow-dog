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
    assert {:ok, {_flags, child_specs}} = ServerAgentSupervisor.init(opts)

    assert Enum.map(child_specs, & &1.id) == [
             :heartbeat,
             :command_journal,
             :config_store,
             :config_apply_store,
             :config_applier,
             :client
           ]

    client_spec = List.last(child_specs)
    {Client, :start_link, [client_opts]} = client_spec.start

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

    assert Enum.sort(Keyword.keys(client_opts)) ==
             Enum.sort([
               :enabled,
               :name,
               :management_url,
               :token,
               :identity,
               :dispatcher,
               :dispatcher_runtime_adapter,
               :command_journal,
               :config_applier,
               :config_apply_store,
               :socket,
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

    Process.exit(client, :kill)
    restarted_client = wait_for_restart(names.client, client)

    assert Process.alive?(supervisor)
    assert restarted_client != client
    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
    assert Process.whereis(names.config_apply_store) == config_apply_store
    assert Process.whereis(names.config_applier) == config_applier
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
end
