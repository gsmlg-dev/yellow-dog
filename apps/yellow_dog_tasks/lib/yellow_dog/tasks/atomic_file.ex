defmodule YellowDog.Tasks.AtomicFile do
  @moduledoc """
  Validated atomic file replacement for downloaded task data.
  """

  @spec replace(Path.t(), iodata(), (Path.t() -> term())) :: {:ok, Path.t()} | {:error, term()}
  def replace(path, contents, validator) when is_function(validator, 1) do
    tmp_path = tmp_path(path)

    result =
      try do
        with :ok <- path |> Path.dirname() |> File.mkdir_p(),
             :ok <- File.write(tmp_path, contents),
             :ok <- validate(tmp_path, validator),
             :ok <- File.rename(tmp_path, path) do
          {:ok, path}
        end
      rescue
        exception -> {:error, exception}
      end

    case result do
      {:ok, ^path} ->
        {:ok, path}

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp validate(tmp_path, validator) do
    case validator.(tmp_path) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid}
      false -> {:error, :invalid}
      other -> {:error, {:invalid_result, other}}
    end
  end

  defp tmp_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.#{suffix}.tmp"
  end
end
