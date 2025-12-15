# E2E Test Helper
# Configure ExUnit for E2E tests with service lifecycle management.

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
  # Include slow tests
  exclude: []
)
