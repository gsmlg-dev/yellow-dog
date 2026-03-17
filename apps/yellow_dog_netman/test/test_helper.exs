Application.put_env(:yellow_dog_netman, :profile_dir, Path.join(__DIR__, "support/test_profiles"))
Application.put_env(:yellow_dog_netman, :reconciliation_interval_ms, 60_000)
Application.put_env(:yellow_dog_netman, :netlink_backend, :mock)

# Start the DHCP client supervision tree since it was converted from an
# Application to a Supervisor. Netman FSM tests call DhcpClient.start_interface/2
# which requires Registry and DynamicSupervisor to be running.
{:ok, _} = YellowDog.DhcpClient.Application.start_link([])

ExUnit.start(exclude: [:integration, :privileged])
