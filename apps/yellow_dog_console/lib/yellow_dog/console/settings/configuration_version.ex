defmodule YellowDog.Console.Settings.ConfigurationVersion do
  @moduledoc """
  Tracks configuration versions for optimistic locking.
  Uses ETS for storage and Agent for atomic operations.

  This module implements a hybrid optimistic locking approach:
  - In-memory version counter (fast check for web console conflicts)
  - File modification timestamp (detects external file edits)
  """

  use Agent

  @table_name :config_versions

  @type version_info :: %{
          version: non_neg_integer(),
          timestamp: integer(),
          file_path: String.t()
        }

  @doc """
  Starts the ConfigurationVersion Agent.

  Creates an ETS table for version tracking and initializes the version counter to 0.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(
      fn ->
        try do: :ets.delete(@table_name), catch: (_, _ -> :ok)
        :ets.new(@table_name, [:set, :public, :named_table])
        %{current_version: 0}
      end,
      name: __MODULE__
    )
  end

  @doc """
  Gets the current version and file timestamp for a configuration file.

  ## Parameters
    - file_path: Absolute path to the configuration file

  ## Returns
    - Map with version, timestamp, and file_path
  """
  @spec get_version(String.t()) :: version_info()
  def get_version(file_path) do
    version = Agent.get(__MODULE__, & &1.current_version)
    timestamp = get_file_timestamp(file_path)

    %{
      version: version,
      timestamp: timestamp,
      file_path: file_path
    }
  end

  @doc """
  Atomic compare-and-swap operation for version checking and increment.

  Checks both version counter and file timestamp before incrementing version.

  ## Parameters
    - file_path: Path to configuration file
    - expected_version: Expected current version
    - expected_timestamp: Expected file modification timestamp

  ## Returns
    - `:ok` if versions match and version was incremented
    - `{:error, :version_mismatch}` if version counter doesn't match
    - `{:error, :file_modified}` if file timestamp changed
  """
  @spec compare_and_swap(String.t(), non_neg_integer(), integer()) ::
          :ok | {:error, :version_mismatch | :file_modified}
  def compare_and_swap(file_path, expected_version, expected_timestamp) do
    current_timestamp = get_file_timestamp(file_path)

    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        state.current_version != expected_version ->
          {{:error, :version_mismatch}, state}

        current_timestamp != expected_timestamp ->
          {{:error, :file_modified}, state}

        true ->
          new_version = state.current_version + 1
          {:ok, %{state | current_version: new_version}}
      end
    end)
  end

  @doc """
  Forces version increment.

  Used when external file modification is detected (e.g., manual config edit).
  """
  @spec increment_version() :: :ok
  def increment_version do
    Agent.update(__MODULE__, fn state ->
      %{state | current_version: state.current_version + 1}
    end)
  end

  # Private Functions

  defp get_file_timestamp(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix()

      {:error, _} ->
        0
    end
  end
end
