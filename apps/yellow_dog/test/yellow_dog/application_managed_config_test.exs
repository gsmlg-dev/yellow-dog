defmodule YellowDog.ApplicationManagedConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.BootConfig
  alias YellowDog.ApplicationManagedConfigTest.{ManagerFake, SelectorFake}

  @revision String.duplicate("a", 64)

  setup do
    Application.stop(:yellow_dog)
    stop_config()

    saved = %{
      boot_config: Application.fetch_env(:yellow_dog, BootConfig),
      config_file_path: Application.fetch_env(:yellow_dog, :config_file_path),
      data_dir: Application.fetch_env(:yellow_dog, :data_dir),
      runtime: Application.fetch_env(:yellow_dog_server_agent, :runtime)
    }

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-managed-boot-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    SelectorFake.configure({:ok, @revision})
    ManagerFake.configure(@revision)

    Application.put_env(:yellow_dog, BootConfig,
      selector: SelectorFake,
      manager: ManagerFake
    )

    on_exit(fn ->
      Application.stop(:yellow_dog)
      stop_config()
      SelectorFake.clear()
      ManagerFake.clear()
      restore_env(:yellow_dog, BootConfig, saved.boot_config)
      restore_env(:yellow_dog, :config_file_path, saved.config_file_path)
      restore_env(:yellow_dog, :data_dir, saved.data_dir)
      restore_env(:yellow_dog_server_agent, :runtime, saved.runtime)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "boots the exact acknowledged managed revision while retaining local bootstrap", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_bootstrap(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    agent_data_dir = Path.join(tmp_dir, "agent")

    Application.put_env(:yellow_dog_server_agent, :runtime,
      data_dir: agent_data_dir,
      server_id: "server-a"
    )

    handler_id = "managed-boot-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:yellow_dog, :config, :boot_selected],
        fn _event, _measurements, metadata, owner -> send(owner, {:boot_selected, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _apps} = Application.ensure_all_started(:yellow_dog)

    assert YellowDog.Config.bootstrap()["dns"]["port"] == 53
    assert YellowDog.Config.get_all()["dns"]["port"] == 5_353
    assert YellowDog.Config.bootstrap()["yellow_dog_server"]["id"] == "server-a"

    assert SelectorFake.take_calls() == [{agent_data_dir, "server-a"}]
    assert [{^agent_data_dir, @revision, bootstrap}] = ManagerFake.take_calls()
    assert bootstrap["dns"]["port"] == 53

    assert_receive {:boot_selected, metadata}, 1_000
    assert metadata.source == :managed_known_good
    assert metadata.revision == @revision
    assert metadata.error == nil
    refute Map.has_key?(metadata, :config)
    refute inspect(metadata) =~ "bootstrap-token"
  end

  test "managed config data directory prefers the local agent override", %{tmp_dir: tmp_dir} do
    agent_data_dir = Path.join(tmp_dir, "agent")
    Application.put_env(:yellow_dog_server_agent, :runtime, data_dir: agent_data_dir)

    assert YellowDog.Application.managed_config_data_dir(%{"data_dir" => "/ignored"}) ==
             agent_data_dir

    Application.put_env(:yellow_dog_server_agent, :runtime, [])

    assert YellowDog.Application.managed_config_data_dir(%{"data_dir" => tmp_dir}) == tmp_dir
  end

  test "refuses to start from local TOML when managed ownership evidence is corrupt", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_bootstrap(tmp_dir)
    Application.put_env(:yellow_dog, :config_file_path, config_path)

    Application.put_env(:yellow_dog_server_agent, :runtime,
      data_dir: Path.join(tmp_dir, "agent"),
      server_id: "server-a"
    )

    SelectorFake.configure({:error, :corrupt})

    assert {:error, {:managed_config_unavailable, :corrupt_journal}} =
             YellowDog.Application.start(:normal, [])

    refute Process.whereis(YellowDog.Config)
    assert ManagerFake.take_calls() == []
  end

  defp write_bootstrap(tmp_dir) do
    path = Path.join(tmp_dir, "yellow-dog.toml")

    File.write!(
      path,
      """
      data_dir = "#{tmp_dir}"

      [dns]
      port = 53

      [yellow_dog_server]
      profile = "custom"
      id = "server-a"

      [yellow_dog_server.management]
      token = "bootstrap-token"

      [yellow_dog_server.services]
      dns = false
      mdns = false
      dhcpv4 = false
      dhcpv6 = false
      netboot = false
      identity = false
      fingerprint = false
      server_agent = false
      """
    )

    path
  end

  defp stop_config do
    case Process.whereis(YellowDog.Config) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defmodule SelectorFake do
    @key {__MODULE__, :state}

    def configure(result), do: :persistent_term.put(@key, %{result: result, calls: []})
    def clear, do: :persistent_term.erase(@key)

    def select(data_dir, server_id) do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: [{data_dir, server_id} | state.calls]})
      state.result
    end

    def take_calls do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: []})
      Enum.reverse(state.calls)
    end
  end

  defmodule ManagerFake do
    @key {__MODULE__, :state}

    def configure(revision), do: :persistent_term.put(@key, %{revision: revision, calls: []})
    def clear, do: :persistent_term.erase(@key)

    def boot_config(data_dir, revision, bootstrap) do
      state = :persistent_term.get(@key)
      call = {data_dir, revision, bootstrap}
      :persistent_term.put(@key, %{state | calls: [call | state.calls]})

      {:ok,
       %{
         revision: state.revision,
         config: put_in(bootstrap, ["dns", "port"], 5_353)
       }}
    end

    def take_calls do
      state = :persistent_term.get(@key)
      :persistent_term.put(@key, %{state | calls: []})
      Enum.reverse(state.calls)
    end
  end
end
