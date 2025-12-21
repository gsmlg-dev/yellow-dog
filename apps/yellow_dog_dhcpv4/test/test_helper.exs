ExUnit.start(exclude: [:integration, :privileged_port])

# Enable debug logging for tests to capture debug log messages
Logger.configure(level: :debug)
