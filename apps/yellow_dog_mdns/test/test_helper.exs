ExUnit.start()

# Load test support files
Path.wildcard("test/support/**/*.ex") |> Enum.each(&Code.require_file/1)
