defmodule YellowDog.ApplicationTest do
  use ExUnit.Case, async: false

  alias YellowDog.ApplicationAgentFake
  alias YellowDog.ApplicationServiceFake
  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.ServerOperation

  @agent_module ApplicationAgentFake
  @runtime_defaults [reconnect_initial_ms: 1_000, reconnect_max_ms: 30_000]
  @secret "runtime-only-management-token"

  setup do
    Application.stop(:yellow_dog)
    stop_config()

    saved_env = %{
      config_file_path: Application.fetch_env(:yellow_dog, :config_file_path),
      data_dir: Application.fetch_env(:yellow_dog, :data_dir),
      module: Application.fetch_env(:yellow_dog, :server_agent_module),
      owner: Application.fetch_env(:yellow_dog, :application_test_owner),
      result: Application.fetch_env(:yellow_dog, :application_test_agent_result),
      service_overrides: Application.fetch_env(:yellow_dog, :service_module_overrides),
      startup_barrier: Application.fetch_env(:yellow_dog, :application_test_startup_barrier),
      runtime: Application.fetch_env(:yellow_dog_server_agent, :runtime)
    }

    Application.put_env(:yellow_dog, :server_agent_module, @agent_module)
    Application.put_env(:yellow_dog, :application_test_owner, self())
    Application.put_env(:yellow_dog, :application_test_agent_result, :ok)
    Application.put_env(:yellow_dog, :service_module_overrides, %{})
    Application.delete_env(:yellow_dog, :application_test_startup_barrier)
    Application.put_env(:yellow_dog_server_agent, :runtime, @runtime_defaults)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-application-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Application.stop(:yellow_dog)
      stop_config()
      restore_env(:yellow_dog, :config_file_path, saved_env.config_file_path)
      restore_env(:yellow_dog, :data_dir, saved_env.data_dir)
      restore_env(:yellow_dog, :server_agent_module, saved_env.module)
      restore_env(:yellow_dog, :application_test_owner, saved_env.owner)
      restore_env(:yellow_dog, :application_test_agent_result, saved_env.result)
      restore_env(:yellow_dog, :service_module_overrides, saved_env.service_overrides)
      restore_env(:yellow_dog, :application_test_startup_barrier, saved_env.startup_barrier)
      restore_env(:yellow_dog_server_agent, :runtime, saved_env.runtime)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "modern enabled profile starts one late-bound agent after YellowDog.Supervisor and re-resolves on restart",
       %{tmp_dir: tmp_dir} do
    config_path = write_server_config(tmp_dir, server_id: "profile-server")
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog_server_agent, :runtime, server_id: "runtime-server")

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)

    assert_receive {:server_agent_started, first_pid, first_opts, supervisor}, 2_000
    assert is_pid(supervisor)
    assert Process.alive?(supervisor)
    assert first_opts[:server_id] == "runtime-server"

    assert 1 ==
             YellowDog.Supervisor
             |> Supervisor.which_children()
             |> Enum.count(&(elem(&1, 0) == YellowDog.ServerAgent))

    refute_receive {:server_agent_started, _pid, _opts, _supervisor}, 100

    Application.put_env(:yellow_dog_server_agent, :runtime, server_id: "restarted-server")
    Process.exit(first_pid, :kill)

    assert_receive {:server_agent_started, second_pid, second_opts, ^supervisor}, 2_000
    assert second_pid != first_pid
    assert second_opts[:server_id] == "restarted-server"

    assert :ok = YellowDog.ServiceManager.stop_service(:server_agent)

    refute Enum.any?(
             Supervisor.which_children(YellowDog.Supervisor),
             &(elem(&1, 0) == YellowDog.ServerAgent)
           )
  end

  test "public ServiceManager start stop and restart preserve the late-bound agent contract", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir, server_agent: false)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog_server_agent, :runtime, server_id: "public-agent")

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    refute child_pid(YellowDog.ServerAgent)

    assert :ok = YellowDog.ServiceManager.start_service(:server_agent)
    assert_receive {:server_agent_started, first_pid, first_opts, supervisor}, 2_000
    assert supervisor == Process.whereis(YellowDog.Supervisor)
    assert first_opts[:server_id] == "public-agent"
    assert child_pid(YellowDog.ServerAgent) == first_pid
    assert service_flag(:server_agent) == true

    assert :ok = YellowDog.ServiceManager.stop_service(:server_agent)
    refute child_pid(YellowDog.ServerAgent)
    assert service_flag(:server_agent) == false

    assert :ok = YellowDog.ServiceManager.start_service(:server_agent)
    assert_receive {:server_agent_started, second_pid, second_opts, ^supervisor}, 2_000
    assert second_pid != first_pid
    assert second_opts[:server_id] == "public-agent"
    assert child_pid(YellowDog.ServerAgent) == second_pid
    assert service_flag(:server_agent) == true
  end

  test "stop before async startup selection leaves no ignored child and permits public start", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog_server_agent, :runtime, server_id: "async-race-agent")
    barrier_ref = install_startup_barrier()

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    startup_task = await_startup_barrier(barrier_ref)

    assert :ok = YellowDog.ServiceManager.stop_service(:server_agent)
    assert service_flag(:server_agent) == false

    release_startup_barrier(startup_task, barrier_ref)

    refute child_entry(YellowDog.ServerAgent)
    assert :ok = YellowDog.ServiceManager.start_service(:server_agent)
    assert_receive {:server_agent_started, pid, opts, supervisor}, 2_000
    assert supervisor == Process.whereis(YellowDog.Supervisor)
    assert opts[:server_id] == "async-race-agent"
    assert child_pid(YellowDog.ServerAgent) == pid
    assert service_flag(:server_agent) == true
  end

  test "public start repeatedly recovers an already-present ignored agent child", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir, server_agent: false)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog_server_agent, :runtime, server_id: "ignored-agent")
    barrier_ref = install_startup_barrier()

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    startup_task = await_startup_barrier(barrier_ref)
    release_startup_barrier(startup_task, barrier_ref)

    child_spec = YellowDog.Application.server_agent_child_spec(@agent_module)
    assert {:ok, :undefined} = Supervisor.start_child(YellowDog.Supervisor, child_spec)

    assert {:error, :service_disabled} =
             YellowDog.Application.start_service_supervisor(:server_agent, :ignored)

    refute child_entry(YellowDog.ServerAgent)
    assert service_flag(:server_agent) == false

    for iteration <- 1..10 do
      child_spec = YellowDog.Application.server_agent_child_spec(@agent_module)

      assert {:ok, :undefined} =
               Supervisor.start_child(YellowDog.Supervisor, child_spec),
             "iteration #{iteration}"

      assert {YellowDog.ServerAgent, :undefined, :supervisor, _modules} =
               child_entry(YellowDog.ServerAgent)

      assert :ok = YellowDog.ServiceManager.start_service(:server_agent),
             "iteration #{iteration}"

      assert_receive {:server_agent_started, pid, opts, supervisor}, 2_000
      assert supervisor == Process.whereis(YellowDog.Supervisor)
      assert opts[:server_id] == "ignored-agent"
      assert child_pid(YellowDog.ServerAgent) == pid
      assert service_flag(:server_agent) == true

      assert :ok = YellowDog.ServiceManager.stop_service(:server_agent)
      refute child_entry(YellowDog.ServerAgent)
      assert service_flag(:server_agent) == false
    end
  end

  test "failed ignored child recovery restores the flag and removes the child entry", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir, server_agent: false)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_url: "wss://management.example.test",
      management_token: @secret,
      server_id: "failed-recovery-agent"
    )

    barrier_ref = install_startup_barrier()
    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    startup_task = await_startup_barrier(barrier_ref)
    release_startup_barrier(startup_task, barrier_ref)

    child_spec = YellowDog.Application.server_agent_child_spec(@agent_module)
    assert {:ok, :undefined} = Supervisor.start_child(YellowDog.Supervisor, child_spec)

    Application.put_env(
      :yellow_dog,
      :application_test_agent_result,
      {:error, {:secret, @secret}}
    )

    handler_id = "failed-recovery-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:yellow_dog, :application, :error],
        fn _event, _measurements, metadata, owner ->
          if metadata.service == :server_agent do
            send(owner, {:failed_recovery_error, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :server_agent_reconcile_failed} =
             YellowDog.ServiceManager.start_service(:server_agent)

    assert_receive {:server_agent_failed, failed_opts, supervisor}, 2_000
    assert supervisor == Process.whereis(YellowDog.Supervisor)
    assert failed_opts[:management_token] == @secret

    assert_receive {:failed_recovery_error, metadata}, 2_000
    assert metadata.reason == :start_failed
    refute inspect(metadata) =~ @secret
    refute inspect(metadata) =~ "management.example.test"

    assert service_flag(:server_agent) == false
    refute child_entry(YellowDog.ServerAgent)
  end

  test "terminal reconciliation bounds repeated undefined to running delete races" do
    {:ok, calls} = Agent.start_link(fn -> %{observations: 0, deletes: 0} end)

    observe_child = fn ->
      Agent.update(calls, &Map.update!(&1, :observations, fn count -> count + 1 end))
      {YellowDog.ServerAgent, :undefined, :supervisor, [@agent_module]}
    end

    delete_child = fn ->
      Agent.update(calls, &Map.update!(&1, :deletes, fn count -> count + 1 end))
      {:error, :running}
    end

    assert {:ok, :restarting} =
             YellowDog.Application.reconcile_terminal_server_agent_child_for_test(
               2,
               observe_child,
               delete_child
             )

    assert Agent.get(calls, & &1) == %{observations: 3, deletes: 3}
  end

  test "public ServerAgent start rejects legacy profiles and restores the attempted flag", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_legacy_config(tmp_dir, false)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert service_flag(:server_agent) == false

    assert {:error, :unsupported_profile} =
             YellowDog.ServiceManager.start_service(:server_agent)

    assert service_flag(:server_agent) == false
    refute child_pid(YellowDog.ServerAgent)
  end

  test "public ServerAgent start rejects a missing selected module and restores the flag", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir, server_agent: false)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog, :server_agent_module, YellowDog.MissingServerAgent)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)

    assert {:error, :module_not_available} =
             YellowDog.ServiceManager.start_service(:server_agent)

    assert service_flag(:server_agent) == false
    refute child_pid(YellowDog.ServerAgent)
  end

  test "disabled custom and legacy configurations never start the agent", %{tmp_dir: tmp_dir} do
    configs = [
      {:disabled, write_server_config(tmp_dir, server_agent: false, suffix: "disabled")},
      {:custom_default, write_server_config(tmp_dir, omit_server_agent: true, suffix: "custom")},
      {:legacy, write_legacy_config(tmp_dir)}
    ]

    for {label, config_path} <- configs do
      Application.put_env(:yellow_dog, :config_file_path, config_path)
      assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog), inspect(label)

      refute_receive {:server_agent_started, _pid, _opts, _supervisor},
                     150,
                     inspect(label)

      refute Enum.any?(
               Supervisor.which_children(YellowDog.Supervisor),
               &(elem(&1, 0) == YellowDog.ServerAgent)
             )

      assert :ok = Application.stop(:yellow_dog)
    end
  end

  test "an enabled custom release with the agent module missing remains bootable", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog, :server_agent_module, YellowDog.MissingServerAgent)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert Process.alive?(Process.whereis(YellowDog.Supervisor))
    refute_receive {:server_agent_started, _pid, _opts, _supervisor}, 150

    refute Enum.any?(
             Supervisor.which_children(YellowDog.Supervisor),
             &(elem(&1, 0) == YellowDog.ServerAgent)
           )
  end

  test "derives runtime overrides, durable identity, revision, data dir, and available capabilities",
       %{tmp_dir: tmp_dir} do
    config =
      server_config(
        id: "profile-id",
        name: "Profile Name",
        management_url: "wss://profile.example.test",
        services: %{
          "dns" => true,
          "mdns" => true,
          "dhcpv4" => true,
          "dhcpv6" => true,
          "netboot" => true,
          "identity" => true,
          "server_agent" => true
        }
      )

    start_config!(config)

    agent_data_dir = Path.join(tmp_dir, "agent-base")

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_token: @secret,
      server_id: "runtime-id",
      data_dir: agent_data_dir,
      reconnect_initial_ms: 250,
      reconnect_max_ms: 4_000
    )

    assert {:ok, pid} = YellowDog.Application.start_server_agent(@agent_module)
    assert_receive {:server_agent_started, ^pid, opts, nil}

    assert opts[:data_dir] == agent_data_dir
    assert opts[:server_id] == "runtime-id"
    assert opts[:profile] == :custom
    assert opts[:server_name] == "Profile Name"
    assert opts[:server_version] == Application.spec(:yellow_dog, :vsn) |> to_string()
    assert opts[:management_url] == "wss://profile.example.test"
    assert opts[:management_token] == @secret
    assert opts[:reconnect_initial_ms] == 250
    assert opts[:reconnect_max_ms] == 4_000
    assert {:ok, expected_revision} = Digest.calculate(YellowDog.Config.get_all())
    assert opts[:config_revision] == expected_revision
    assert opts[:capabilities] == expected_capabilities(config)
    assert Enum.uniq(opts[:capabilities]) == opts[:capabilities]
    assert Enum.any?(opts[:capabilities], &String.starts_with?(&1, "runtime."))
    refute Enum.any?(opts[:capabilities], &String.starts_with?(&1, "settings."))
    refute String.contains?(opts[:data_dir], "/server/server")
  end

  test "capabilities exclude settings unsupported by the production runtime adapter" do
    start_config!(server_config(id: "server-1"))

    runtime_adapter = :"Elixir.YellowDog.Server.Control"

    assert Code.ensure_loaded?(runtime_adapter)

    required_callbacks = [
      validate_config: 1,
      install_config: 2,
      activate_config: 1,
      restore_config: 1
    ]

    refute Enum.all?(required_callbacks, fn {callback, arity} ->
             function_exported?(runtime_adapter, callback, arity)
           end)

    assert {:ok, pid} = YellowDog.Application.start_server_agent(@agent_module)
    assert_receive {:server_agent_started, ^pid, opts, nil}

    assert "runtime.capabilities" in opts[:capabilities]

    refute Enum.any?(opts[:capabilities], fn capability ->
             capability in [
               "settings.read",
               "settings.config.write",
               "settings.apply",
               "settings.reload",
               "settings.rollback"
             ]
           end)
  end

  test "successful public service changes rebuild and then restore agent identity", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    Application.put_env(:yellow_dog, :service_module_overrides, %{
      identity: ApplicationServiceFake
    })

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_url: "wss://management.example.test",
      management_token: @secret,
      server_id: "refresh-server",
      reconnect_initial_ms: 1_000,
      reconnect_max_ms: 30_000
    )

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert_receive {:server_agent_started, initial_pid, initial_opts, supervisor}, 2_000
    assert supervisor == Process.whereis(YellowDog.Supervisor)
    refute Enum.any?(initial_opts[:capabilities], &String.starts_with?(&1, "identity."))

    assert :ok = YellowDog.ServiceManager.start_service(:identity)
    assert_receive {:application_service_started, service_pid, _service_opts}, 2_000
    assert_receive {:server_agent_started, started_pid, started_opts, ^supervisor}, 2_000

    assert started_pid != initial_pid
    assert Process.alive?(service_pid)
    assert started_opts[:config_revision] != initial_opts[:config_revision]
    assert Enum.any?(started_opts[:capabilities], &String.starts_with?(&1, "identity."))
    assert service_flag(:identity) == true

    assert :ok = YellowDog.ServiceManager.stop_service(:identity)
    assert_receive {:server_agent_started, stopped_pid, stopped_opts, ^supervisor}, 2_000

    assert stopped_pid != started_pid
    refute Process.alive?(service_pid)
    assert stopped_opts[:config_revision] == initial_opts[:config_revision]
    assert stopped_opts[:capabilities] == initial_opts[:capabilities]
    assert service_flag(:identity) == false
  end

  test "agent identity refresh failure is sanitized and cannot reverse a changed service", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    Application.put_env(:yellow_dog, :service_module_overrides, %{
      identity: ApplicationServiceFake
    })

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert_receive {:server_agent_started, _pid, _opts, supervisor}, 2_000
    assert supervisor == Process.whereis(YellowDog.Supervisor)

    Application.put_env(
      :yellow_dog,
      :application_test_agent_result,
      {:error, {:secret, @secret}}
    )

    handler_id = "identity-refresh-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:yellow_dog, :application, :error],
        fn _event, _measurements, metadata, owner ->
          if metadata[:operation] == :identity_refresh do
            send(owner, {:identity_refresh_error, metadata})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = YellowDog.ServiceManager.start_service(:identity)
    assert_receive {:application_service_started, service_pid, _service_opts}, 2_000
    assert_receive {:server_agent_failed, _failed_opts, ^supervisor}, 2_000
    assert_receive {:identity_refresh_error, metadata}, 2_000

    assert Process.alive?(service_pid)
    assert service_flag(:identity) == true
    assert metadata.service == :server_agent
    assert metadata.trigger_service == :identity
    assert metadata.reason == :refresh_failed
    refute inspect(metadata) =~ @secret
    refute inspect(metadata) =~ "management.example.test"
  end

  test "uses the YellowDog base data dir and retry defaults only when both retry values are absent",
       %{tmp_dir: tmp_dir} do
    data_dir = Path.join(tmp_dir, "yellow-dog-data")
    config = server_config(id: "server-1", data_dir: data_dir)
    start_config!(config)

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_url: "wss://management.example.test",
      management_token: @secret
    )

    assert {:ok, pid} = YellowDog.Application.start_server_agent(@agent_module)
    assert_receive {:server_agent_started, ^pid, opts, nil}
    assert opts[:data_dir] == data_dir
    assert opts[:reconnect_initial_ms] == 1_000
    assert opts[:reconnect_max_ms] == 30_000
  end

  test "missing URL, token, ID, or valid retry bounds never supplies outbound socket options" do
    cases = [
      {:missing_url, [management_token: @secret]},
      {:missing_token, [management_url: "wss://management.example.test"]},
      {:missing_id,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         server_id: nil
       ]},
      {:partial_retry,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         reconnect_initial_ms: 100
       ]},
      {:nonpositive_retry,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         reconnect_initial_ms: 0,
         reconnect_max_ms: 1_000
       ]},
      {:malformed_retry,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         reconnect_initial_ms: :invalid,
         reconnect_max_ms: 1_000
       ]},
      {:reversed_retry,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         reconnect_initial_ms: 2_000,
         reconnect_max_ms: 1_000
       ]},
      {:above_bound_retry,
       [
         management_url: "wss://management.example.test",
         management_token: @secret,
         reconnect_initial_ms: 1_000,
         reconnect_max_ms: 86_400_001
       ]}
    ]

    for {label, runtime} <- cases do
      stop_config()
      config = server_config(id: if(label == :missing_id, do: nil, else: "server-1"))
      start_config!(config)
      Application.put_env(:yellow_dog_server_agent, :runtime, runtime)

      assert {:ok, pid} = YellowDog.Application.start_server_agent(@agent_module), inspect(label)
      assert_receive {:server_agent_started, ^pid, opts, nil}, 500, inspect(label)

      if label == :missing_id do
        assert opts == []
      else
        assert opts[:server_id] == "server-1"
        refute Keyword.has_key?(opts, :management_url)
        refute Keyword.has_key?(opts, :management_token)
        refute Keyword.has_key?(opts, :reconnect_initial_ms)
        refute Keyword.has_key?(opts, :reconnect_max_ms)
        refute Keyword.has_key?(opts, :socket)
        refute Keyword.has_key?(opts, :client_opts)
      end

      GenServer.stop(pid)
    end
  end

  test "a complete unavailable endpoint starts the real agent without failing Server boot", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_server_config(tmp_dir, server_id: "real-agent-server")
    data_dir = Path.join(tmp_dir, "real-agent-data")

    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog, :server_agent_module, YellowDog.ServerAgent)

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_url: "https://127.0.0.1:1",
      management_token: @secret,
      server_id: "real-agent-server",
      data_dir: data_dir,
      reconnect_initial_ms: 60_000,
      reconnect_max_ms: 60_000
    )

    handler_id = "real-agent-start-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:yellow_dog, :service, :started],
        fn _event, _measurements, metadata, owner ->
          if metadata.service == :server_agent do
            send(owner, {:real_server_agent_started, metadata.pid})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert_receive {:real_server_agent_started, _safe_pid}, 2_000

    assert {YellowDog.ServerAgent, pid, :supervisor, _modules} =
             Enum.find(
               Supervisor.which_children(YellowDog.Supervisor),
               &(elem(&1, 0) == YellowDog.ServerAgent)
             )

    assert Process.alive?(pid)
    assert Process.alive?(Process.whereis(YellowDog.ServerAgent.Client))
    assert Process.alive?(Process.whereis(YellowDog.Supervisor))

    refute :yellow_dog_server_agent in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  test "stored child specs recursively exclude management material, sockets, and functions" do
    child_spec = YellowDog.Application.server_agent_child_spec(@agent_module)

    assert child_spec.id == YellowDog.ServerAgent
    assert child_spec.start == {YellowDog.Application, :start_server_agent, [@agent_module]}
    refute contains?(child_spec, @secret)
    refute contains?(child_spec, "management.example.test")
    refute contains_key?(child_spec, [:management_url, :management_token, :token, :socket])
    refute contains_function?(child_spec)
  end

  test "agent start failures and telemetry metadata redact runtime token", %{tmp_dir: tmp_dir} do
    config_path = write_server_config(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)
    Application.put_env(:yellow_dog, :application_test_agent_result, {:error, {:secret, @secret}})

    Application.put_env(:yellow_dog_server_agent, :runtime,
      management_url: "wss://management.example.test",
      management_token: @secret,
      server_id: "server-1",
      reconnect_initial_ms: 100,
      reconnect_max_ms: 1_000
    )

    handler_id = "application-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:yellow_dog, :application, :error],
        fn _event, _measurements, metadata, owner ->
          send(owner, {:application_error, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)
    assert_receive {:server_agent_failed, _opts, supervisor}, 2_000
    assert is_pid(supervisor)
    assert_receive {:application_error, metadata}, 2_000
    assert metadata.service == :server_agent
    assert metadata.reason == :start_failed
    refute inspect(metadata) =~ @secret
    refute inspect(metadata) =~ "management.example.test"
  end

  defp start_config!(config) do
    stop_config()
    assert {:ok, pid} = YellowDog.Config.start_link(config)
    Process.unlink(pid)
    pid
  end

  defp stop_config do
    case Process.whereis(YellowDog.Config) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp server_config(opts) do
    services =
      Keyword.get(opts, :services, %{
        "dns" => false,
        "mdns" => false,
        "dhcpv4" => false,
        "dhcpv6" => false,
        "netboot" => false,
        "identity" => false,
        "fingerprint" => false,
        "server_agent" => true
      })

    %{
      "data_dir" => Keyword.get(opts, :data_dir, "data"),
      "yellow_dog_server" => %{
        "profile" => "custom",
        "id" => Keyword.get(opts, :id),
        "name" => Keyword.get(opts, :name),
        "management" => %{"url" => Keyword.get(opts, :management_url)},
        "services" => services
      }
    }
  end

  defp write_server_config(tmp_dir, opts \\ []) do
    suffix = Keyword.get(opts, :suffix, System.unique_integer([:positive]))
    path = Path.join(tmp_dir, "server-#{suffix}.toml")
    server_agent = Keyword.get(opts, :server_agent, true)

    agent_line =
      if Keyword.get(opts, :omit_server_agent, false),
        do: "",
        else: "server_agent = #{server_agent}\n"

    File.write!(
      path,
      """
      data_dir = "#{tmp_dir}"

      [yellow_dog_server]
      profile = "custom"
      id = "#{Keyword.get(opts, :server_id, "profile-server")}"
      name = "Release Test Server"

      [yellow_dog_server.services]
      dns = false
      mdns = false
      dhcpv4 = false
      dhcpv6 = false
      netboot = false
      identity = false
      fingerprint = false
      #{agent_line}
      """
    )

    path
  end

  defp write_legacy_config(tmp_dir, server_agent \\ true) do
    path = Path.join(tmp_dir, "legacy.toml")

    File.write!(
      path,
      """
      data_dir = "#{tmp_dir}"

      [core]
      dns = false
      mdns = false
      dhcpv4 = false
      dhcpv6 = false
      netboot = false
      identity = false
      server_agent = #{server_agent}
      """
    )

    path
  end

  defp expected_capabilities(config) do
    resolved = YellowDog.Server.ProfileResolver.resolve(config)

    enabled_domains =
      [
        {:dns, "dns"},
        {:mdns, "mdns"},
        {:dhcpv4, "dhcp"},
        {:dhcpv6, "dhcp"},
        {:netboot, "netboot"},
        {:identity, "identity"}
      ]
      |> Enum.filter(fn {service, _domain} ->
        resolved.services[service] and service_available?(service)
      end)
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(["runtime"]))

    ServerOperation.all()
    |> Map.values()
    |> Enum.map(& &1.capability)
    |> Enum.filter(&(capability_domain(&1) in enabled_domains))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp service_available?(service) do
    {:ok, metadata} = ServiceRegistry.fetch(service)
    metadata.available?
  end

  defp child_pid(child_id) do
    case child_entry(child_id) do
      {_id, pid, _type, _modules} when is_pid(pid) -> pid
      _missing -> nil
    end
  end

  defp child_entry(child_id) do
    Enum.find(Supervisor.which_children(YellowDog.Supervisor), &(elem(&1, 0) == child_id))
  end

  defp install_startup_barrier do
    ref = make_ref()
    Application.put_env(:yellow_dog, :application_test_startup_barrier, {self(), ref})
    ref
  end

  defp await_startup_barrier(ref) do
    assert_receive {:application_startup_selection_waiting, startup_task, ^ref}, 2_000
    startup_task
  end

  defp release_startup_barrier(startup_task, ref) do
    send(startup_task, {:application_startup_selection_continue, ref})
    assert_receive {:application_startup_selection_complete, ^ref}, 2_000
  end

  defp service_flag(service) do
    YellowDog.Server.ProfileResolver.resolve()
    |> Map.fetch!(:services)
    |> Map.fetch!(service)
  end

  defp capability_domain(capability), do: capability |> String.split(".", parts: 2) |> hd()

  defp contains?(term, value) when term == value, do: true
  defp contains?(term, value) when is_map(term), do: Enum.any?(term, &contains?(&1, value))
  defp contains?(term, value) when is_tuple(term), do: term |> Tuple.to_list() |> contains?(value)
  defp contains?(term, value) when is_list(term), do: Enum.any?(term, &contains?(&1, value))
  defp contains?(_term, _value), do: false

  defp contains_key?(term, forbidden) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      key in forbidden or contains_key?(value, forbidden)
    end)
  end

  defp contains_key?(term, forbidden) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_key?(forbidden)

  defp contains_key?(term, forbidden) when is_list(term) do
    Enum.any?(term, fn
      {key, value} -> key in forbidden or contains_key?(value, forbidden)
      value -> contains_key?(value, forbidden)
    end)
  end

  defp contains_key?(_term, _forbidden), do: false

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(term) when is_map(term), do: Enum.any?(term, &contains_function?/1)

  defp contains_function?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_function?()

  defp contains_function?(term) when is_list(term), do: Enum.any?(term, &contains_function?/1)
  defp contains_function?(_term), do: false

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
