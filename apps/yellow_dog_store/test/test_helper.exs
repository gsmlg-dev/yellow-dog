# Start processes required by Store facade modules.
# EventBridge dispatches via TaskSupervisor, and both must be running
# before any Store mutation (which calls EventBridge.notify/3).
{:ok, _} = Task.Supervisor.start_link(name: YellowDog.Store.TaskSupervisor)
{:ok, _} = YellowDog.Store.EventBridge.start_link()

ExUnit.start()

# Compile test support files
Code.require_file("support/store_helper.ex", __DIR__)
