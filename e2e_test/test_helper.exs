# E2E Test Helper
# Configure ExUnit for E2E tests with service lifecycle management.

# Start required applications for E2E tests
# These provide infrastructure needed by the service servers
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:logger)

# Start YellowDog Config GenServer directly (not the full app which has complex dependencies)
# The E2E tests only need the Config process to be running
# Pass an empty map (not list) since Config uses Agent with Map operations
case YellowDog.Config.start_link(%{}) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Add support modules to the code path
Code.compile_file("support/service_helper.ex", __DIR__)
Code.compile_file("support/dns_client.ex", __DIR__)
Code.compile_file("support/dhcp_client.ex", __DIR__)

ExUnit.start(
  # Run tests sequentially - E2E tests start real services
  async: false,
  # Longer timeout for service startup (60 seconds)
  timeout: 60_000,
  # Clear formatting for CI output
  formatters: [ExUnit.CLIFormatter],
  # Exclude security tests (unimplemented features) and skip tags
  exclude: [:security, :skip]
)
