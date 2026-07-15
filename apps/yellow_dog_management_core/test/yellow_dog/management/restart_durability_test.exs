defmodule YellowDog.Management.RestartDurabilityTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Netman
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Server
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Error

  setup do
    previous_env =
      Map.new(
        [
          :data_dir,
          :max_events,
          :event_write_timeout_ms,
          :event_write_test_delay_ms,
          :atomic_json_file_ops,
          :atomic_json_file_ops_owner
        ],
        fn key ->
          {key, Application.fetch_env(:yellow_dog_management_core, key)}
        end
      )

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-restart-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.delete_env(:yellow_dog_management_core, :max_events)
    Application.delete_env(:yellow_dog_management_core, :event_write_timeout_ms)
    Application.delete_env(:yellow_dog_management_core, :event_write_test_delay_ms)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops_owner)
    restart_management_children()

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      restart_management_children()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "server and Netman registrations and statuses survive registry restarts" do
    assert {:ok, %Server{registered_at: server_registered_at}} =
             ManagementCore.register_server(%{
               id: "srv-restart",
               name: "Restart Server",
               profile: :dns_only,
               services: %{dns: true}
             })

    assert {:ok,
            %Server{
              registered_at: ^server_registered_at,
              name: "Replacement Server",
              profile: :cloud_dns,
              metadata: %{site: "edge"}
            }} =
             ManagementCore.register_server(%{
               id: "srv-restart",
               name: "Replacement Server",
               profile: :cloud_dns,
               services: %{dns: true, server_agent: true},
               metadata: %{site: "edge"}
             })

    assert {:ok,
            %Server{
              status: :online,
              last_seen_at: server_last_seen_at,
              updated_at: server_updated_at
            }} =
             ManagementCore.update_server_status("srv-restart", :online)

    assert {:ok, %Netman{registered_at: netman_registered_at}} =
             ManagementCore.register_netman(%{
               id: "netman-restart",
               name: "Restart Netman",
               profile: :vm,
               features: %{interfaces: true}
             })

    assert {:ok,
            %Netman{
              registered_at: ^netman_registered_at,
              name: "Replacement Netman",
              profile: :cloud_server,
              apply_mode: :observe_first,
              metadata: %{"rack" => "r1"}
            }} =
             ManagementCore.register_netman(%{
               id: "netman-restart",
               name: "Replacement Netman",
               profile: :cloud_server,
               apply_mode: :observe_first,
               features: %{interfaces: true, routes: true},
               metadata: %{"rack" => "r1"}
             })

    assert {:ok,
            %Netman{
              status: :offline,
              last_seen_at: netman_last_seen_at,
              updated_at: netman_updated_at
            }} =
             ManagementCore.update_netman_status("netman-restart", :offline)

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok,
            %Server{
              id: "srv-restart",
              name: "Replacement Server",
              profile: :cloud_dns,
              status: :online,
              services: %{dns: true, server_agent: true},
              metadata: %{site: "edge"},
              registered_at: ^server_registered_at,
              last_seen_at: ^server_last_seen_at,
              updated_at: ^server_updated_at
            }} = ManagementCore.get_server("srv-restart")

    assert {:ok,
            %Netman{
              id: "netman-restart",
              name: "Replacement Netman",
              profile: :cloud_server,
              apply_mode: :observe_first,
              status: :offline,
              features: %{interfaces: true, routes: true},
              metadata: %{"rack" => "r1"},
              registered_at: ^netman_registered_at,
              last_seen_at: ^netman_last_seen_at,
              updated_at: ^netman_updated_at
            }} = ManagementCore.get_netman("netman-restart")
  end

  test "atom metadata is canonical before write and survives a fresh BEAM", %{
    data_dir: data_dir
  } do
    canonical_metadata = %{"rack" => "r1", "tier" => "edge"}

    assert {:ok, %Server{metadata: ^canonical_metadata}} =
             ManagementCore.register_server(%{
               id: "srv-fresh-beam-metadata",
               metadata: %{rack: "r1", tier: :edge}
             })

    restart_child(Servers)

    assert {:ok, %Server{metadata: ^canonical_metadata}} =
             ManagementCore.get_server("srv-fresh-beam-metadata")

    script = """
    Application.put_env(:yellow_dog_management_core, :data_dir, #{inspect(data_dir)})
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    {:ok, server} = YellowDog.ManagementCore.get_server("srv-fresh-beam-metadata")
    IO.puts("FRESH_METADATA=" <> Jason.encode!(server.metadata))
    """

    mix = System.find_executable("mix")
    assert is_binary(mix)

    assert {output, 0} =
             System.cmd(
               mix,
               ["run", "--no-compile", "--no-start", "-e", script],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert [_, encoded_metadata] = Regex.run(~r/FRESH_METADATA=(\{[^\n]+\})/, output)
    assert Jason.decode!(encoded_metadata) == canonical_metadata
  end

  test "events keep one global deterministic order across restarts" do
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-events"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-events"})
    assert {:ok, %Server{}} = ManagementCore.update_server_status("srv-events", :online)
    assert {:ok, %Netman{}} = ManagementCore.update_netman_status("netman-events", :offline)

    before_restart = ManagementCore.list_events()

    assert Enum.map(before_restart, & &1.sequence) ==
             Enum.sort(Enum.map(before_restart, & &1.sequence))

    restart_management_children()

    after_restart = ManagementCore.list_events()
    assert Enum.map(after_restart, & &1.id) == Enum.map(before_restart, & &1.id)
    assert Enum.map(after_restart, & &1.sequence) == Enum.map(before_restart, & &1.sequence)
  end

  test "malformed individual manifests and event files are ignored", %{data_dir: data_dir} do
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-valid"})
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-invalid-time"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-valid"})
    valid_event_ids = Enum.map(ManagementCore.list_events(), & &1.id)

    invalid_time_path =
      Path.join([
        data_dir,
        "management",
        "servers",
        "srv-invalid-time",
        "manifest.json"
      ])

    invalid_time_manifest =
      invalid_time_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("registration", &Map.put(&1, "registered_at", "not-a-timestamp"))

    File.write!(invalid_time_path, Jason.encode!(invalid_time_manifest))

    write_file(data_dir, ["management", "servers", "srv-bad", "manifest.json"], "{")
    write_file(data_dir, ["management", "netmans", "netman-bad", "manifest.json"], "[]")
    write_file(data_dir, ["management", "events", "evt-999999.json"], "{")
    write_file(data_dir, ["management", "events", "not-an-event.json"], ~s({"id":"bad"}))
    write_file(data_dir, ["management", "events", ".manifest.json.tmp"], "interrupted")

    restart_management_children()

    assert [%Server{id: "srv-valid"}] = ManagementCore.list_servers()
    assert [%Netman{id: "netman-valid"}] = ManagementCore.list_netmans()
    assert Enum.map(ManagementCore.list_events(), & &1.id) == valid_event_ids
  end

  test "registration updates and restart preserve config lifecycle manifest keys" do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-shared-manifest")
    assert {:ok, netman_path} = StoragePath.netman_manifest("netman-shared-manifest")

    lifecycle = %{
      "desired_version" => 7,
      "applied_version" => 6,
      "desired_digest" => String.duplicate("a", 64)
    }

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(netman_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-shared-manifest"})
    assert {:ok, %Netman{}} = ManagementCore.register_netman(%{id: "netman-shared-manifest"})

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok, %Server{}} = ManagementCore.get_server("srv-shared-manifest")
    assert {:ok, %Netman{}} = ManagementCore.get_netman("netman-shared-manifest")

    assert {:ok, %Server{status: :online}} =
             ManagementCore.update_server_status("srv-shared-manifest", :online)

    assert {:ok, %Netman{name: "Replacement"}} =
             ManagementCore.register_netman(%{
               id: "netman-shared-manifest",
               name: "Replacement"
             })

    assert {:ok, server_manifest} = AtomicJson.read(server_path)
    assert {:ok, netman_manifest} = AtomicJson.read(netman_path)

    assert server_manifest["config_lifecycle"] == lifecycle
    assert netman_manifest["config_lifecycle"] == lifecycle
    assert is_map(server_manifest["registration"])
    assert is_map(netman_manifest["registration"])

    restart_child(Servers)
    restart_child(Netmans)

    assert {:ok, %Server{status: :online}} =
             ManagementCore.get_server("srv-shared-manifest")

    assert {:ok, %Netman{name: "Replacement"}} =
             ManagementCore.get_netman("netman-shared-manifest")

    assert {:ok, server_manifest} = AtomicJson.read(server_path)
    assert {:ok, netman_manifest} = AtomicJson.read(netman_path)
    assert server_manifest["config_lifecycle"] == lifecycle
    assert netman_manifest["config_lifecycle"] == lifecycle
  end

  test "event failure rollback serializes and preserves a concurrent lifecycle update" do
    assert {:ok, %Server{name: "Before"}} =
             ManagementCore.register_server(%{id: "srv-write-failure", name: "Before"})

    assert {:ok, server_path} = StoragePath.server_manifest("srv-write-failure")

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingEventFailureFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-write-failure", name: "After"})
      end)

    assert_receive {:event_write_blocked, event_store_pid}

    lifecycle = %{"desired_version" => 9, "state" => "staged"}

    config_update =
      Task.async(fn ->
        ManifestStore.update_section(server_path, "config_lifecycle", fn _current -> lifecycle end)
      end)

    assert_manifest_update_queued(server_path)
    send(event_store_pid, :continue_event_write)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    assert {:ok, ^lifecycle} = Task.await(config_update)

    assert {:ok, %Server{name: "Before"}} = ManagementCore.get_server("srv-write-failure")

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    restart_child(Servers)

    assert {:ok, %Server{name: "Before"}} = ManagementCore.get_server("srv-write-failure")
    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest["config_lifecycle"] == lifecycle
  end

  test "an unavailable EventStore returns an error and rolls registration back", %{
    data_dir: data_dir
  } do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-event-store-down")
    lifecycle = %{"desired_version" => 12}

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, EventStore)

    assert {:error, %Error{code: :internal}} =
             ManagementCore.register_server(%{id: "srv-event-store-down"})

    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-down")

    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest == %{"config_lifecycle" => lifecycle}

    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, EventStore)
    restart_child(Servers)

    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-down")
    assert [] = ManagementCore.list_events()
    assert Path.wildcard(Path.join([data_dir, "management", "events", "*.json"])) == []
  end

  test "an EventStore crash returns an error and rolls registration back" do
    assert {:ok, server_path} = StoragePath.server_manifest("srv-event-store-crash")
    lifecycle = %{"desired_version" => 13}

    assert {:ok, ^lifecycle} =
             ManifestStore.update_section(server_path, "config_lifecycle", fn _current ->
               lifecycle
             end)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingEventFailureFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())

    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    old_event_store_pid = Process.whereis(EventStore)

    registration =
      Task.async(fn ->
        ManagementCore.register_server(%{id: "srv-event-store-crash"})
      end)

    assert_receive {:event_write_blocked, event_worker_pid}
    assert event_worker_pid != old_event_store_pid
    Process.exit(old_event_store_pid, :kill)

    assert {:error, %Error{code: :internal}} = Task.await(registration)
    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-crash")

    new_event_store_pid = wait_for_replacement(EventStore, old_event_store_pid)
    assert Process.alive?(new_event_store_pid)

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    restart_child(Servers)

    assert {:error, :not_found} = ManagementCore.get_server("srv-event-store-crash")
    assert [] = ManagementCore.list_events()
    assert {:ok, manifest} = AtomicJson.read(server_path)
    assert manifest == %{"config_lifecycle" => lifecycle}
  end

  test "a queued expired append cannot write after EventStore resumes", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)

    event_store_pid = Process.whereis(EventStore)
    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    supervisor_pid = Process.whereis(YellowDog.ManagementCore.Supervisor)
    test_pid = self()

    :ok = :sys.suspend(event_store_pid)

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result = ManagementCore.register_server(%{id: "srv-expired-queued-event"})
        send(test_pid, {:queued_registration_result, self(), result})
      end)

    try do
      assert_event_append_queued(event_store_pid)

      assert_receive {:queued_registration_result, ^caller_pid, {:error, %Error{code: :timeout}}},
                     500

      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}

      assert Process.whereis(Servers) == servers_pid
      assert Process.whereis(ManifestStore) == manifest_store_pid
      assert Process.whereis(YellowDog.ManagementCore.Supervisor) == supervisor_pid
      assert Process.alive?(servers_pid)
      assert Process.alive?(manifest_store_pid)
      assert Process.alive?(supervisor_pid)

      assert {:error, :not_found} =
               ManagementCore.get_server("srv-expired-queued-event")

      assert [] = ManagementCore.list_servers()

      assert {:ok, probe_path} = StoragePath.server_manifest("srv-timeout-probe")

      assert {:ok, %{"desired_version" => 1}} =
               ManifestStore.update_section(probe_path, "config_lifecycle", fn _current ->
                 %{"desired_version" => 1}
               end)

      assert {:ok, registration_path} =
               StoragePath.server_manifest("srv-expired-queued-event")

      refute File.exists?(registration_path)
      assert event_files(data_dir) == []
    after
      :ok = :sys.resume(event_store_pid)
    end

    :sys.get_state(event_store_pid)
    Process.sleep(250)

    assert [] = ManagementCore.list_events()
    assert event_files(data_dir) == []

    assert {:ok, registration_path} =
             StoragePath.server_manifest("srv-expired-queued-event")

    refute File.exists?(registration_path)
  end

  test "a started event write is killed and cleaned at its deadline", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    Application.put_env(:yellow_dog_management_core, :event_write_test_delay_ms, 600)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.SlowEventFileOps
    )

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops_owner, self())

    test_pid = self()
    event_store_pid = Process.whereis(EventStore)
    servers_pid = Process.whereis(Servers)
    manifest_store_pid = Process.whereis(ManifestStore)
    started_at = System.monotonic_time(:millisecond)

    {caller_pid, caller_ref} =
      spawn_monitor(fn ->
        result = ManagementCore.register_server(%{id: "srv-slow-event"})
        elapsed = System.monotonic_time(:millisecond) - started_at
        send(test_pid, {:slow_registration_result, self(), result, elapsed})
      end)

    assert_receive {:event_write_started, worker_pid, event_path}
    assert Process.alive?(worker_pid)
    assert File.exists?(event_path)

    {list_caller_pid, list_caller_ref} =
      spawn_monitor(fn ->
        send(test_pid, {:queued_event_list_result, self(), ManagementCore.list_events()})
      end)

    assert_event_list_queued(event_store_pid)

    assert_receive {:slow_registration_result, ^caller_pid, {:error, %Error{code: :timeout}},
                    elapsed},
                   500

    assert elapsed < 500

    assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :normal}
    assert_receive {:queued_event_list_result, ^list_caller_pid, []}
    assert_receive {:DOWN, ^list_caller_ref, :process, ^list_caller_pid, :normal}
    refute Process.alive?(worker_pid)

    assert Process.whereis(Servers) == servers_pid
    assert Process.whereis(ManifestStore) == manifest_store_pid
    assert Process.alive?(servers_pid)
    assert Process.alive?(manifest_store_pid)
    assert {:error, :not_found} = ManagementCore.get_server("srv-slow-event")
    assert [] = ManagementCore.list_servers()
    assert [] = ManagementCore.list_events()
    refute File.exists?(event_path)

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-slow-event")
    refute File.exists?(manifest_path)

    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    Application.delete_env(:yellow_dog_management_core, :event_write_test_delay_ms)

    assert {:ok, %Server{id: "srv-after-event-timeout"}} =
             ManagementCore.register_server(%{id: "srv-after-event-timeout"})

    assert {:ok, %Server{id: "srv-after-event-timeout"}} =
             ManagementCore.get_server("srv-after-event-timeout")

    assert [%Server{id: "srv-after-event-timeout"}] = ManagementCore.list_servers()
    assert [%{source_id: "srv-after-event-timeout"}] = ManagementCore.list_events()

    Process.sleep(700)

    assert [%{source_id: "srv-after-event-timeout"}] = ManagementCore.list_events()
    assert length(event_files(data_dir)) == 1
  end

  test "event filename collisions are skipped without wedging future appends", %{
    data_dir: data_dir
  } do
    event_path = Path.join([data_dir, "management", "events", "evt-1.json"])
    File.mkdir_p!(Path.dirname(event_path))
    File.write!(event_path, "occupied")

    for id <- ["srv-event-conflict-1", "srv-event-conflict-2", "srv-event-conflict-3"] do
      assert {:ok, %Server{id: ^id}} = ManagementCore.register_server(%{id: id})
    end

    assert File.read!(event_path) == "occupied"
    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [2, 3, 4]

    restart_child(EventStore)
    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [2, 3, 4]
  end

  test "a huge malformed event filename does not poison restart allocation", %{
    data_dir: data_dir
  } do
    event_path =
      Path.join([
        data_dir,
        "management",
        "events",
        "evt-9223372036854775807.json"
      ])

    File.mkdir_p!(Path.dirname(event_path))
    File.write!(event_path, "malformed")

    restart_child(EventStore)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-after-poison-1"})
    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-after-poison-2"})

    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [1, 2]
  end

  test "an invalid event limit uses the documented default" do
    Application.put_env(:yellow_dog_management_core, :max_events, 0)

    assert {:ok, %Server{}} = ManagementCore.register_server(%{id: "srv-default-events"})
    assert [_event] = ManagementCore.list_events()
  end

  defp restart_child(child_id) do
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
  end

  defp restart_management_children do
    Enum.each([Servers, Netmans, EventStore, ManifestStore], fn child_id ->
      assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)

    Enum.each([ManifestStore, EventStore, Servers, Netmans], fn child_id ->
      assert {:ok, _pid} =
               Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)
  end

  defp write_file(data_dir, segments, contents) do
    path = Path.join([data_dir | segments])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp event_files(data_dir) do
    Path.wildcard(Path.join([data_dir, "management", "events", "*.json"]))
  end

  defp assert_event_append_queued(event_store_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(event_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from, {:append, _attrs}} ->
          true

        {:"$gen_call", _from, {:append, _attrs, request_deadline}}
        when is_integer(request_deadline) ->
          true

        _message ->
          false
      end)
    end)
  end

  defp assert_event_list_queued(event_store_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(event_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from, :list} -> true
        _message -> false
      end)
    end)
  end

  defp assert_manifest_update_queued(path) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    manifest_store_pid = Process.whereis(ManifestStore)

    wait_until(deadline, fn ->
      {:messages, messages} = Process.info(manifest_store_pid, :messages)

      Enum.any?(messages, fn
        {:"$gen_call", _from, {:update_section, ^path, "config_lifecycle", updater}}
        when is_function(updater, 1) ->
          true

        _message ->
          false
      end)
    end)
  end

  defp wait_for_replacement(module, old_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    wait_until(deadline, fn ->
      case Process.whereis(module) do
        pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
        _other -> false
      end
    end)
  end

  defp wait_until(deadline, assertion) do
    case assertion.() do
      {:ok, value} ->
        value

      true ->
        :ok

      false ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_until(deadline, assertion)
        else
          flunk("timed out waiting for synchronized process state")
        end
    end
  end

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defmodule BlockingEventFailureFileOps do
    def open(path) do
      if String.contains?(path, "/events/") do
        owner = Application.fetch_env!(:yellow_dog_management_core, :atomic_json_file_ops_owner)
        send(owner, {:event_write_blocked, self()})

        receive do
          :continue_event_write -> {:error, :eacces}
        end
      else
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      end
    end

    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate sync(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end

  defmodule SlowEventFileOps do
    def open(path) do
      if String.contains?(path, "/events/") do
        Process.put(:event_write_path, path)
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      else
        YellowDog.Management.Storage.AtomicJson.FileOps.open(path)
      end
    end

    defdelegate write(device, contents), to: YellowDog.Management.Storage.AtomicJson.FileOps

    def sync(device) do
      case Process.get(:event_write_path) do
        path when is_binary(path) ->
          owner = Application.fetch_env!(:yellow_dog_management_core, :atomic_json_file_ops_owner)
          delay = Application.fetch_env!(:yellow_dog_management_core, :event_write_test_delay_ms)
          send(owner, {:event_write_started, self(), path})
          Process.sleep(delay)
          YellowDog.Management.Storage.AtomicJson.FileOps.sync(device)

        _other ->
          YellowDog.Management.Storage.AtomicJson.FileOps.sync(device)
      end
    end

    defdelegate close(device), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rename(source, target), to: YellowDog.Management.Storage.AtomicJson.FileOps
    defdelegate rm(path), to: YellowDog.Management.Storage.AtomicJson.FileOps
  end
end
