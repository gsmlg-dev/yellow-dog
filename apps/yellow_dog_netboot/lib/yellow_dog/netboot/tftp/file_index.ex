defmodule YellowDog.Netboot.TFTP.FileIndex do
  @moduledoc """
  ETS-cached file index for TFTP root directory.

  Provides safe file lookup with path traversal prevention.
  Files are indexed by their relative path from the TFTP root.
  """

  @table __MODULE__

  @doc "Initialize the ETS table for the file index."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "Scan the TFTP root directory and populate the index."
  @spec scan(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def scan(root_dir) do
    root = Path.expand(root_dir)

    if File.dir?(root) do
      :ets.delete_all_objects(@table)

      count =
        root
        |> scan_recursive("")
        |> Enum.count()

      {:ok, count}
    else
      {:error, :not_a_directory}
    end
  end

  @doc """
  Look up a file by its relative path.

  Returns `{:ok, absolute_path, size}` if found and safe,
  or `{:error, reason}` if not found or path traversal detected.
  """
  @spec lookup(String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, :not_found | :path_traversal}
  def lookup(filename, root_dir) do
    if path_traversal?(filename) do
      {:error, :path_traversal}
    else
      normalized = normalize_path(filename)

      case :ets.lookup(@table, normalized) do
        [{^normalized, abs_path, size}] ->
          root = Path.expand(root_dir)

          if String.starts_with?(abs_path, root) do
            {:ok, abs_path, size}
          else
            {:error, :path_traversal}
          end

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc "List all indexed files."
  @spec list() :: [{String.t(), String.t(), non_neg_integer()}]
  def list do
    :ets.tab2list(@table)
  end

  @doc "Return the number of indexed files."
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  @doc "Check if a path contains traversal sequences."
  @spec path_traversal?(String.t()) :: boolean()
  def path_traversal?(path) do
    String.contains?(path, "..") or
      String.starts_with?(path, "/") or
      String.contains?(path, "\\")
  end

  # --- Private ---

  defp scan_recursive(root, prefix) do
    full_path = Path.join(root, prefix)

    if File.dir?(full_path) do
      case File.ls(full_path) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            relative = if prefix == "", do: entry, else: Path.join(prefix, entry)
            scan_recursive(root, relative)
          end)

        {:error, _} ->
          []
      end
    else
      case File.stat(full_path) do
        {:ok, %{size: size, type: :regular}} ->
          normalized = normalize_path(prefix)
          abs_path = Path.expand(full_path)
          :ets.insert(@table, {normalized, abs_path, size})
          [normalized]

        _ ->
          []
      end
    end
  end

  defp normalize_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end
end
