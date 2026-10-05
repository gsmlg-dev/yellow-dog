defmodule YellowDog.Management.PostgresTools do
  @max_output 65_536
  @timeout 120_000

  def run(tool, args, opts \\ []) when tool in ["pg_dump", "pg_restore", "tar"] do
    case System.find_executable(tool) do
      nil -> {:error, {:missing_tool, tool}}
      executable -> execute(executable, args, opts)
    end
  end

  def connection_env(url) do
    uri =
      case URI.new(url) do
        {:ok, uri} -> uri
        {:error, _reason} -> raise ArgumentError, "A PostgreSQL database URL is required"
      end

    query = URI.decode_query(uri.query || "")
    [username | password] = String.split(uri.userinfo || "", ":", parts: 2)
    database = (uri.path || "") |> String.trim_leading("/") |> URI.decode()

    unless uri.scheme in ["postgres", "postgresql"] and username != "" and database != "" and
             is_binary(uri.host) and valid_host?(uri.host) and (uri.port || 5432) in 1..65_535 and
             is_nil(uri.fragment),
           do: raise(ArgumentError, "A PostgreSQL database URL is required")

    env = [
      {"PGHOST", query["socket_dir"] || uri.host || "localhost"},
      {"PGPORT", Integer.to_string(uri.port || 5432)},
      {"PGUSER", URI.decode(username)},
      {"PGDATABASE", database},
      {"PGCONNECT_TIMEOUT", "10"},
      {"PGAPPNAME", "yellow-dog-management-backup"}
    ]

    env =
      if password == [],
        do: [{"PGPASSWORD", nil} | env],
        else: [{"PGPASSWORD", password |> hd() |> URI.decode()} | env]

    if query["sslmode"], do: [{"PGSSLMODE", query["sslmode"]} | env], else: env
  rescue
    _exception -> raise ArgumentError, "A PostgreSQL database URL is required"
  end

  defp valid_host?(host) do
    if String.contains?(host, ":") do
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, ip} -> tuple_size(ip) == 8
        _error -> false
      end
    else
      Regex.match?(~r/^[^:\[\]@\s\/]+$/, host)
    end
  end

  defp execute(executable, args, opts) do
    caller = self()
    reference = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        caller_monitor = Process.monitor(caller)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :hide,
              args: Enum.map(args, &String.to_charlist/1),
              env:
                Enum.map(Keyword.get(opts, :env, []), fn {key, value} ->
                  {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
                end)
            ]
          )

        timer =
          Process.send_after(self(), :command_timeout, Keyword.get(opts, :timeout, @timeout))

        result = collect(port, caller_monitor, [], 0)
        Process.cancel_timer(timer)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reference, result})
      end)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :command_failed}
    end
  end

  defp collect(port, caller_monitor, chunks, size) do
    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= @max_output ->
        collect(port, caller_monitor, [bytes | chunks], size + byte_size(bytes))

      {^port, {:data, _bytes}} ->
        terminate(port)
        {:error, :command_output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, {:command_exit, status}}

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        terminate(port)
        {:error, :cancelled}

      :command_timeout ->
        terminate(port)
        {:error, :command_timeout}
    end
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end
end
