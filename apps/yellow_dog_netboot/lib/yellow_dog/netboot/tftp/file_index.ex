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
    with {:ok, snapshot} <- build_snapshot(root_dir),
         :ok <- replace(snapshot) do
      {:ok, length(snapshot)}
    end
  end

  @doc false
  @spec build_snapshot(String.t(), keyword()) ::
          {:ok, [{String.t(), String.t(), non_neg_integer()}]} | {:error, term()}
  def build_snapshot(root_dir, opts \\ [])

  def build_snapshot(root_dir, opts) when is_binary(root_dir) and is_list(opts) do
    root = Path.expand(root_dir)

    with true <- File.dir?(root),
         {:ok, excluded} <- excluded_paths(opts) do
      snapshot =
        root
        |> scan_recursive("", excluded)
        |> Enum.sort()

      {:ok, snapshot}
    else
      false -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  def build_snapshot(_root_dir, _opts), do: {:error, :invalid_options}

  @doc false
  @spec snapshot() :: [{String.t(), String.t(), non_neg_integer()}]
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Enum.sort()
  end

  @doc false
  @spec replace([{String.t(), String.t(), non_neg_integer()}]) ::
          :ok | {:error, :invalid_snapshot}
  def replace(snapshot) when is_list(snapshot) do
    with :ok <- validate_snapshot(snapshot) do
      init()
      :ets.delete_all_objects(@table)
      true = :ets.insert(@table, snapshot)
      :ok
    end
  rescue
    _exception -> {:error, :invalid_snapshot}
  end

  def replace(_snapshot), do: {:error, :invalid_snapshot}

  @doc false
  @spec remove([String.t()]) :: :ok | {:error, :invalid_paths}
  def remove(paths) when is_list(paths) do
    if Enum.all?(paths, &valid_relative_path?/1) do
      init()
      Enum.each(paths, &:ets.delete(@table, &1))
      :ok
    else
      {:error, :invalid_paths}
    end
  end

  def remove(_paths), do: {:error, :invalid_paths}

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

  defp scan_recursive(root, prefix, excluded) do
    full_path = Path.join(root, prefix)

    case File.lstat(full_path) do
      {:ok, %{type: :directory}} ->
        case File.ls(full_path) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              relative = if prefix == "", do: entry, else: Path.join(prefix, entry)
              scan_recursive(root, relative, excluded)
            end)

          {:error, _reason} ->
            []
        end

      {:ok, %{size: size, type: :regular}} ->
        normalized = normalize_path(prefix)

        if MapSet.member?(excluded, normalized) do
          []
        else
          [{normalized, Path.expand(full_path), size}]
        end

      _other ->
        []
    end
  end

  defp excluded_paths(opts) do
    case Keyword.get(opts, :exclude, []) do
      paths when is_list(paths) ->
        if Enum.all?(paths, &valid_relative_path?/1) do
          {:ok, MapSet.new(paths)}
        else
          {:error, :invalid_options}
        end

      _paths ->
        {:error, :invalid_options}
    end
  end

  defp validate_snapshot(snapshot) do
    valid_entries? = Enum.all?(snapshot, &valid_entry?/1)
    filenames = Enum.map(snapshot, &elem(&1, 0))

    if valid_entries? and length(filenames) == length(Enum.uniq(filenames)),
      do: :ok,
      else: {:error, :invalid_snapshot}
  end

  defp valid_entry?({filename, absolute_path, size}) do
    valid_relative_path?(filename) and
      is_binary(absolute_path) and
      Path.type(absolute_path) == :absolute and
      is_integer(size) and
      size >= 0
  end

  defp valid_entry?(_entry), do: false

  defp valid_relative_path?(path) when is_binary(path) and path != "" do
    not path_traversal?(path) and normalize_path(path) == path
  end

  defp valid_relative_path?(_path), do: false

  defp normalize_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end
end
