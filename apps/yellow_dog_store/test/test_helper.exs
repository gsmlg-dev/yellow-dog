# EventBridge dispatches callbacks via TaskSupervisor. Start it globally
# since it's stateless. EventBridge itself is started per-test via
# start_supervised! for proper isolation.
{:ok, _} = Task.Supervisor.start_link(name: YellowDog.Store.TaskSupervisor)

ExUnit.start()

# Compile test support files
Code.require_file("support/store_helper.ex", __DIR__)
