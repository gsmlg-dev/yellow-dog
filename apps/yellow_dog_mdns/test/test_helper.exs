ExUnit.start()

# Enable debug logging for tests to capture log messages
Logger.configure(level: :debug)

# Load test support files
Path.wildcard("test/support/**/*.ex") |> Enum.each(&Code.require_file/1)
