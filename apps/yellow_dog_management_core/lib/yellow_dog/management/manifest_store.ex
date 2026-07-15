defmodule YellowDog.Management.ManifestStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Sync.Error

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def update_section(path, section, updater)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(updater, 1) do
    GenServer.call(__MODULE__, {:update_section, path, section, updater})
  end

  @doc false
  def update_section_with(path, section, updater, after_write)
      when is_binary(path) and is_binary(section) and section != "" and
             is_function(updater, 1) and is_function(after_write, 0) do
    GenServer.call(__MODULE__, {:update_section_with, path, section, updater, after_write})
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call({:update_section, path, section, updater}, _from, state) do
    result =
      with {:ok, manifest, _existed?} <- read_manifest(path),
           {:ok, updated_section} <- apply_update(updater, Map.get(manifest, section)),
           {:ok, _path} <- AtomicJson.replace(path, Map.put(manifest, section, updated_section)) do
        {:ok, updated_section}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:update_section_with, path, section, updater, after_write},
        _from,
        state
      ) do
    result = update_section_with_commit(path, section, updater, after_write)
    {:reply, result, state}
  end

  defp update_section_with_commit(path, section, updater, after_write) do
    with {:ok, manifest, existed?} <- read_manifest(path),
         previous_section = Map.fetch(manifest, section),
         {:ok, updated_section} <- apply_update(updater, Map.get(manifest, section)),
         {:ok, _path} <- AtomicJson.replace(path, Map.put(manifest, section, updated_section)) do
      case run_after_write(after_write) do
        :ok ->
          :ok

        {:ok, _value} = success ->
          success

        {:error, _reason} = error ->
          rollback_section(path, section, previous_section, existed?)
          error
      end
    end
  end

  defp read_manifest(path) do
    case AtomicJson.read(path) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest, true}
      {:ok, _invalid} -> invalid_manifest()
      {:error, %Error{code: :not_found}} -> {:ok, %{}, false}
      {:error, %Error{}} = error -> error
    end
  end

  defp apply_update(updater, current_section) do
    case updater.(current_section) do
      updated_section when is_map(updated_section) -> {:ok, updated_section}
      _invalid -> invalid_manifest()
    end
  rescue
    _exception -> invalid_manifest()
  end

  defp run_after_write(after_write) do
    case after_write.() do
      :ok -> :ok
      {:ok, _value} = success -> success
      {:error, %Error{}} = error -> error
      _invalid -> invalid_manifest()
    end
  rescue
    _exception -> internal_error()
  catch
    :exit, _reason -> internal_error()
    :throw, _reason -> internal_error()
  end

  defp rollback_section(path, section, previous_section, existed?) do
    with {:ok, current_manifest, _current_existed?} <- read_manifest(path) do
      restored_manifest = restore_section(current_manifest, section, previous_section)

      case restore_manifest(path, restored_manifest, existed?) do
        :ok -> :ok
        {:error, _reason} = error -> log_rollback_failure(path, error)
      end
    else
      {:error, _reason} = error -> log_rollback_failure(path, error)
    end
  end

  defp restore_section(manifest, section, {:ok, previous_section}),
    do: Map.put(manifest, section, previous_section)

  defp restore_section(manifest, section, :error), do: Map.delete(manifest, section)

  defp restore_manifest(path, manifest, false) when map_size(manifest) == 0 do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_manifest(path, manifest, _existed?) do
    case AtomicJson.replace(path, manifest) do
      {:ok, _path} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp log_rollback_failure(path, error) do
    Logger.error("Failed to roll back manifest section in #{path}: #{inspect(error)}")
    error
  end

  defp invalid_manifest,
    do: {:error, Error.new(:invalid, "invalid management manifest", %{})}

  defp internal_error,
    do: {:error, Error.new(:internal, "management manifest commit failed", %{})}
end
