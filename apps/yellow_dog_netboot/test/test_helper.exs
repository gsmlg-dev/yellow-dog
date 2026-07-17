# Start the Netboot supervision tree since the Application module was removed.
# Tests depend on named processes (Asset.Store, ScriptEngine, TransferSupervisor, etc.)
device_root =
  Path.join(System.tmp_dir!(), "yellow_dog_netboot_tests_#{System.unique_integer([:positive])}")

device_config = %{
  managed_devices_path: Path.join(device_root, "managed_devices.json"),
  persist_path: Path.join(device_root, "devices.toml")
}

{:ok, _} = YellowDog.Netboot.Supervisor.start_link(config: device_config)

ExUnit.start()
ExUnit.after_suite(fn _result -> File.rm_rf!(device_root) end)
