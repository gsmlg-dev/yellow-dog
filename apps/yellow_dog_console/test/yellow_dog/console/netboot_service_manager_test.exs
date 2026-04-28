defmodule YellowDog.Console.NetbootServiceManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServiceManager

  @default_config %{
    "core" => %{
      "dns" => false,
      "mdns" => false,
      "dhcpv4" => false,
      "dhcpv6" => false,
      "netboot" => false
    },
    "netboot" => %{"tftp_port" => 0}
  }

  setup do
    ensure_config_started()
    ensure_yellow_dog_supervisor_started()
    original_config = YellowDog.Config.get_all()

    tftp_root =
      Path.join(System.tmp_dir!(), "yellow_dog_netboot_#{System.unique_integer([:positive])}")

    data_dir =
      Path.join(System.tmp_dir!(), "yellow_dog_data_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tftp_root)
    YellowDog.Config.update(:netboot, %{"tftp_port" => 0, "tftp_root" => tftp_root})
    YellowDog.Config.set_service_enabled(:netboot, false)

    on_exit(fn ->
      if Process.whereis(YellowDog.Netboot.Supervisor) do
        ServiceManager.stop_service(:netboot)
      end

      File.rm_rf!(tftp_root)
      File.rm_rf!(data_dir)
      Agent.update(YellowDog.Config, fn _state -> original_config end)
    end)

    {:ok, tftp_root: tftp_root, data_dir: data_dir}
  end

  test "start_service starts the netboot supervisor and TFTP server", %{tftp_root: tftp_root} do
    assert :ok = ServiceManager.start_service(:netboot)
    assert is_pid(Process.whereis(YellowDog.Netboot.Supervisor))
    assert ServiceManager.get_service_status(:netboot).running

    assert %{
             running: true,
             root_dir: ^tftp_root
           } = YellowDog.Netboot.TFTP.Server.status()
  end

  test "start_service uses the data directory when no TFTP root is configured", %{
    data_dir: data_dir
  } do
    expected_root = Path.join(data_dir, "netboot/tftp")
    File.rm_rf!(expected_root)

    Agent.update(YellowDog.Config, fn state ->
      state
      |> Map.put("data_dir", data_dir)
      |> Map.put("netboot", %{"tftp_port" => 0})
      |> put_in(["core", "netboot"], false)
    end)

    assert :ok = ServiceManager.start_service(:netboot)

    assert %{
             running: true,
             root_dir: ^expected_root
           } = YellowDog.Netboot.TFTP.Server.status()

    assert File.dir?(expected_root)
  end

  defp ensure_config_started do
    case Process.whereis(YellowDog.Config) do
      nil ->
        start_supervised!({YellowDog.Config, @default_config})

      _pid ->
        :ok
    end
  end

  defp ensure_yellow_dog_supervisor_started do
    case Process.whereis(YellowDog.Supervisor) do
      nil ->
        start_supervised!(%{
          id: :yellow_dog_dynamic_test_supervisor,
          start:
            {Supervisor, :start_link, [[], [strategy: :one_for_one, name: YellowDog.Supervisor]]},
          type: :supervisor
        })

      _pid ->
        :ok
    end
  end
end
