defmodule YellowDog.Management.PostgresToolsFixture do
  def install! do
    directory =
      Path.join(System.tmp_dir!(), "postgres-tools-#{System.unique_integer([:positive])}")

    bin = Path.join(directory, "bin")
    File.mkdir_p!(bin)
    File.chmod!(directory, 0o700)
    python = System.find_executable("python3") || raise "python3 is required for native fixtures"

    for tool <- ["pg_dump", "pg_restore", "tar"] do
      path = Path.join(bin, tool)
      File.write!(path, "#!#{python}\n" <> executable())
      File.chmod!(path, 0o700)
    end

    fixture = %{
      directory: directory,
      bin: bin,
      pid_path: Path.join(directory, "helper.pid"),
      heartbeat: Path.join(directory, "heartbeat"),
      original_path: System.get_env("PATH")
    }

    System.put_env("PATH", bin <> ":" <> (fixture.original_path || ""))

    ExUnit.Callbacks.on_exit(fn ->
      cleanup_process(fixture)
      restore_env("PATH", fixture.original_path)
      File.rm_rf!(directory)
    end)

    fixture
  end

  def arguments(fixture, mode, extra \\ []) do
    [mode, fixture.pid_path, fixture.heartbeat | extra]
  end

  def pid(fixture) do
    case File.read(fixture.pid_path) do
      {:ok, value} -> String.to_integer(String.trim(value))
      {:error, :enoent} -> nil
    end
  end

  def alive?(pid) when is_integer(pid), do: File.exists?("/proc/#{pid}")
  def alive?(nil), do: false

  def wait_until(predicate, attempts \\ 200)
  def wait_until(_predicate, 0), do: false

  def wait_until(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  defp cleanup_process(fixture) do
    case pid(fixture) do
      nil ->
        :ok

      pid ->
        case File.read("/proc/#{pid}/cmdline") do
          {:ok, command} ->
            if String.contains?(command, fixture.bin <> "/") do
              System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
              wait_until(fn -> not alive?(pid) end)
            end

          {:error, _reason} ->
            :ok
        end
    end
  end

  defp executable do
    """
    import json
    import os
    import sys
    import time

    mode, pid_path, heartbeat = sys.argv[1:4]
    with open(pid_path, "w") as output:
        output.write(str(os.getpid()))
        output.flush()
        os.fsync(output.fileno())

    def write_forever():
        with open(heartbeat, "ab", buffering=0) as output:
            while True:
                output.write(b"tick" + bytes([10]))
                time.sleep(0.01)

    if mode == "inspect":
        names = ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE",
                 "PGCONNECT_TIMEOUT", "PGAPPNAME", "PGSSLMODE"]
        print(json.dumps({"tool": os.path.basename(sys.argv[0]),
                          "args": sys.argv[4:],
                          "env": {name: os.environ.get(name) for name in names}}))
    elif mode == "success":
        os.write(1, b"stdout" + bytes([10]))
        os.write(2, b"stderr" + bytes([10]))
    elif mode == "exit":
        os.write(2, os.environ.get("PGPASSWORD", "").encode())
        sys.exit(7)
    elif mode == "exact_output":
        os.write(1, b"x" * 65536)
    elif mode == "overflow":
        with open(heartbeat, "ab", buffering=0) as output:
            output.write(b"started" + bytes([10]))
        os.write(1, b"x" * 65537)
        write_forever()
    elif mode == "write_forever":
        write_forever()
    else:
        sys.exit(9)
    """
  end
end
