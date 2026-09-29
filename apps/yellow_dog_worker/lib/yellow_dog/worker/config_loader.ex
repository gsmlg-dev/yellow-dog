defmodule YellowDog.Worker.ConfigLoader do
  @moduledoc """
  Loads one complete, self-contained C0 WorkerPlan from a local TOML file.

  Resource content is embedded in the plan. External resource references are not
  part of the shared C0 format and are rejected by ConfigSpec.
  """

  alias YellowDog.ConfigSpec

  @max_bytes 1_048_576

  @spec load(Path.t(), String.t()) :: {:ok, map()} | {:error, [map()]}
  def load(path, worker_id) when is_binary(path) and is_binary(worker_id) do
    with :ok <- safe_source_path(path),
         {:ok, input} <- bounded_read(path),
         {:ok, plan} <- bounded_decode(input),
         true <- plan["worker_id"] == worker_id do
      {:ok, plan}
    else
      false ->
        error(["worker_id"], :worker_id_mismatch, "plan targets another Worker")

      {:error, reason} when is_atom(reason) ->
        error([], reason, "cannot read WorkerPlan: #{reason}")

      other ->
        other
    end
  end

  def load(_, _), do: error([], :invalid_type, "path and worker ID must be strings")

  defp bounded_read(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size <= @max_bytes,
         {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.read(file, @max_bytes + 1) do
          {:ok, input} when byte_size(input) <= @max_bytes -> {:ok, input}
          {:ok, _} -> {:error, :too_large}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(file)
      end
    else
      false -> {:error, :invalid_source_or_too_large}
      error -> error
    end
  end

  defp safe_source_path(path) do
    if ".." in Path.split(path) do
      {:error, :path_traversal}
    else
      path
      |> Path.expand()
      |> Path.split()
      |> Enum.reduce_while("", fn part, prefix ->
        next = if prefix == "" and part == "/", do: "/", else: Path.join(prefix, part)

        case File.lstat(next) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_source}}
          {:ok, _} -> {:cont, next}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, _} = error -> error
        _ -> :ok
      end
    end
  end

  defp bounded_decode(input) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 8_000_000, kill: true, error_logger: false})
        send(caller, {token, ConfigSpec.decode(input)})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        error([], :parse_limit, "TOML parser exceeded its resource limit")
    after
      5_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        error([], :parse_limit, "TOML parser exceeded its time limit")
    end
  end

  defp error(path, code, message),
    do: {:error, [%{path: path, code: code, message: message}]}
end
