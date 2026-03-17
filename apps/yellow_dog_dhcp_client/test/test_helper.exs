# Start the DHCP client supervision tree since the Application module was
# converted to a Supervisor. Tests depend on Registry, DynamicSupervisor,
# and ConfigWatcher.
{:ok, _} = YellowDog.DhcpClient.Application.start_link([])

ExUnit.start()
