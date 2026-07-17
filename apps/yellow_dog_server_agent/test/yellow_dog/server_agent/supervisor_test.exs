defmodule YellowDog.ServerAgent.SupervisorTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Heartbeat
  alias YellowDog.ServerAgent.Supervisor, as: ServerAgentSupervisor

  @server_id "server-east-1"
  @profile "dns_only"
  @capabilities ["runtime.services"]

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-supervisor-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
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

  test "partial durable configuration fails fast", %{data_dir: data_dir} do
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
  end

  test "complete configuration starts exact ordered children with distinct names", %{
    data_dir: data_dir
  } do
    names = names()
    opts = complete_opts(data_dir, names)
    supervisor = start_supervisor(opts)

    assert {:ok, {_flags, child_specs}} = ServerAgentSupervisor.init(opts)

    assert Enum.map(child_specs, & &1.id) == [:heartbeat, :command_journal, :config_store]

    assert Enum.map(child_specs, fn child_spec -> elem(child_spec.start, 0) end) == [
             Heartbeat,
             CommandJournal,
             ConfigStore
           ]

    assert Process.whereis(names.heartbeat)
    assert Process.whereis(names.command_journal)
    assert Process.whereis(names.config_store)
    assert Process.whereis(names.supervisor) == supervisor
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
        supervisor: unique_name(:supervisor)
      }

      {:ok, supervisor} = ServerAgentSupervisor.start_link(complete_opts(data_dir, names))
      Process.unlink(supervisor)

      heartbeat = Process.whereis(names.heartbeat)
      journal = Process.whereis(names.command_journal)
      config_store = Process.whereis(names.config_store)

      assert Enum.map(Supervisor.which_children(supervisor), &elem(&1, 0)) == [
               :config_store,
               :command_journal,
               :heartbeat
             ]

      Process.exit(journal, :kill)
      restarted_journal = wait_for_restart(names.command_journal, journal)

      assert Process.whereis(names.heartbeat) == heartbeat
      assert Process.whereis(names.config_store) == config_store
      assert restarted_journal != journal

      Supervisor.stop(supervisor)
    after
      assert {:ok, _started} = Application.ensure_all_started(:yellow_dog_server_agent)
    end
  end

  test "child-only options reject shared identity and name overrides", %{data_dir: data_dir} do
    names = names()

    forbidden = [:name, :data_dir, :server_id, :profile, :capabilities]

    for child_opts_key <- [:command_journal_opts, :config_store_opts],
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
  end

  test "one_for_one restarts each durable child without restarting heartbeat or sibling", %{
    data_dir: data_dir
  } do
    names = names()
    supervisor = start_supervisor(complete_opts(data_dir, names))
    heartbeat = Process.whereis(names.heartbeat)
    journal = Process.whereis(names.command_journal)
    config_store = Process.whereis(names.config_store)

    Process.exit(journal, :kill)
    restarted_journal = wait_for_restart(names.command_journal, journal)

    assert Process.alive?(supervisor)
    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.config_store) == config_store
    assert restarted_journal != journal

    Process.exit(config_store, :kill)
    restarted_store = wait_for_restart(names.config_store, config_store)

    assert Process.whereis(names.heartbeat) == heartbeat
    assert Process.whereis(names.command_journal) == restarted_journal
    assert restarted_store != config_store
  end

  test "one_for_one restarts Heartbeat without restarting durable siblings", %{
    data_dir: data_dir
  } do
    names = names()
    supervisor = start_supervisor(complete_opts(data_dir, names))
    heartbeat = Process.whereis(names.heartbeat)
    journal = Process.whereis(names.command_journal)
    config_store = Process.whereis(names.config_store)

    Process.exit(heartbeat, :kill)
    restarted_heartbeat = wait_for_restart(names.heartbeat, heartbeat)

    assert Process.alive?(supervisor)
    assert restarted_heartbeat != heartbeat
    assert Process.whereis(names.command_journal) == journal
    assert Process.whereis(names.config_store) == config_store
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
      supervisor_name: names.supervisor,
      command_journal_opts: [max_records: 10],
      config_store_opts: [max_bytes: 1_000_000]
    ]
  end

  defp names do
    %{
      heartbeat: unique_name(:heartbeat),
      command_journal: unique_name(:journal),
      config_store: unique_name(:config_store),
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
