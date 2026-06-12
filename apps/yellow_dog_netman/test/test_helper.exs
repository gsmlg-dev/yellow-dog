Application.put_env(:yellow_dog_netman, :profile_dir, Path.join(__DIR__, "support/test_profiles"))
Application.put_env(:yellow_dog_netman, :reconciliation_interval_ms, 60_000)
Application.put_env(:yellow_dog_netman, :netlink_backend, :mock)

# Start the DHCP client supervision tree since it was converted from an
# Application to a Supervisor. Netman FSM tests call DhcpClient.start_interface/2
# which requires Registry and DynamicSupervisor to be running.
{:ok, _} = YellowDog.DhcpClient.Application.start_link([])

# On macOS the netman Application intentionally skips its supervision tree
# (no Linux netlink). Tests run against the :mock netlink backend, so start
# the tree explicitly here to match what the Application does on Linux.
if :os.type() == {:unix, :darwin} do
  {:ok, _} = YellowDog.Resolved.Supervisor.start_link([])
  {:ok, _} = YellowDog.Netman.Supervisor.start_link([])
end

ExUnit.start(exclude: [:integration, :privileged])
