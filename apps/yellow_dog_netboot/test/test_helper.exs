# Start the Netboot supervision tree since the Application module was removed.
# Tests depend on named processes (Asset.Store, ScriptEngine, TransferSupervisor, etc.)
{:ok, _} = YellowDog.Netboot.Supervisor.start_link([])

ExUnit.start()
