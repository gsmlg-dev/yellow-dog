defmodule YellowDog.Netboot.Asset.Store do
  @moduledoc """
  Owns managed Netboot asset metadata and the live TFTP file index.

  Remote asset mutation remains unsupported. The local path-based upload and
  delete APIs are retained for console compatibility.
  """

  use GenServer

  alias YellowDog.Netboot.Asset.Ledger
  alias YellowDog.Netboot.Asset.ManagedAsset
  alias YellowDog.Netboot.TFTP.FileIndex

  @default_root "/srv/netboot/tftp"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec control_snapshot(GenServer.server()) :: {:ok, [map()]}
  def control_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :control_snapshot)
  end

  @doc false
  @spec control_delete_asset(term(), GenServer.server()) ::
          {:error, :invalid | :unsupported}
  def control_delete_asset(asset_id, server \\ __MODULE__) do
    GenServer.call(server, {:control_delete_asset, asset_id})
  end

  @doc false
  @spec control_rescan(String.t(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def control_rescan(scope, server \\ __MODULE__) do
    GenServer.call(server, {:control_rescan, scope})
  end

  @doc "List all files in the TFTP root without claiming management ownership."
  @spec list_files(GenServer.server()) :: [map()]
  def list_files(server \\ __MODULE__) do
    GenServer.call(server, :list_files)
  end

  @doc "Get file info by relative path."
  @spec get_file(String.t(), GenServer.server()) ::
          {:ok, map()} | {:error, :not_found | :path_traversal}
  def get_file(relative_path, server \\ __MODULE__) do
    GenServer.call(server, {:get_file, relative_path})
  end

  @doc "Delete a local file from the TFTP root."
  @spec delete_file(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def delete_file(relative_path, server \\ __MODULE__) do
    GenServer.call(server, {:delete_file, relative_path})
  end

  @doc "Get the root directory path."
  @spec root_dir(GenServer.server()) :: String.t()
  def root_dir(server \\ __MODULE__) do
    GenServer.call(server, :root_dir)
  end

  @doc false
  @spec managed_assets_path(GenServer.server()) :: String.t()
  def managed_assets_path(server \\ __MODULE__) do
    GenServer.call(server, :managed_assets_path)
  end

  @doc "Copy a local file into the TFTP root."
  @spec upload_file(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def upload_file(relative_path, source_path, server \\ __MODULE__) do
    GenServer.call(server, {:upload_file, relative_path, source_path})
  end

  @doc "Build a directory tree structure."
  @spec file_tree(GenServer.server()) :: [map()]
  def file_tree(server \\ __MODULE__) do
    GenServer.call(server, :file_tree)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    root = config_value(config, :tftp_root, @default_root) |> Path.expand()

    ledger_path =
      config_value(
        config,
        :managed_assets_path,
        Path.join(Path.dirname(root), "managed_assets.json")
      )
      |> Path.expand()

    index_ops = Keyword.get(opts, :index_ops, FileIndex)

    state = %{
      root: root,
      ledger_path: ledger_path,
      ledger: Ledger.empty(),
      index_ops: index_ops
    }

    with :ok <- validate_storage_paths(root, ledger_path),
         :ok <- index_call(index_ops, :init, []),
         {:ok, ledger} <- load_ledger(ledger_path),
         :ok <- rebuild_startup_index(state) do
      {:ok, %{state | ledger: ledger}}
    else
      {:error, {:ledger_load_failed, _reason} = reason} -> {:stop, reason}
      {:error, reason} -> {:stop, {:asset_store_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:control_snapshot, _from, state) do
    resources =
      state.ledger
      |> Ledger.list_active()
      |> Enum.map(&ManagedAsset.to_resource/1)

    {:reply, {:ok, resources}, state}
  end

  @impl true
  def handle_call({:control_delete_asset, asset_id}, _from, state) do
    result =
      if ManagedAsset.valid_asset_id?(asset_id),
        do: {:error, :unsupported},
        else: {:error, :invalid}

    {:reply, result, state}
  end

  @impl true
  def handle_call({:control_rescan, scope}, _from, state) do
    {:reply, rescan(scope, state), state}
  end

  @impl true
  def handle_call(:list_files, _from, state) do
    {:reply, scan_files(state.root, ""), state}
  end

  @impl true
  def handle_call({:get_file, path}, _from, state) do
    {:reply, safe_file_info(path, state.root), state}
  end

  @impl true
  def handle_call({:delete_file, path}, _from, state) do
    result =
      if FileIndex.path_traversal?(path),
        do: {:error, :path_traversal},
        else: File.rm(Path.join(state.root, path))

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upload_file, path, source}, _from, state) do
    result =
      if FileIndex.path_traversal?(path) do
        {:error, :path_traversal}
      else
        destination = Path.join(state.root, path)

        with :ok <- File.mkdir_p(Path.dirname(destination)),
             {:ok, _bytes} <- File.copy(source, destination) do
          :ok
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:root_dir, _from, state) do
    {:reply, state.root, state}
  end

  @impl true
  def handle_call(:managed_assets_path, _from, state) do
    {:reply, state.ledger_path, state}
  end

  @impl true
  def handle_call(:file_tree, _from, state) do
    {:reply, build_tree(state.root, ""), state}
  end

  defp rescan(scope, state) when scope in ["all", "missing"] do
    with {:ok, previous_index} <- index_snapshot(state.index_ops),
         {:ok, candidate_index} <- build_index(state),
         :ok <- index_call(state.index_ops, :replace, [candidate_index]) do
      count =
        case scope do
          "all" ->
            length(candidate_index)

          "missing" ->
            previous = previous_index |> Enum.map(&elem(&1, 0)) |> MapSet.new()
            Enum.count(candidate_index, &(not MapSet.member?(previous, elem(&1, 0))))
        end

      {:ok, count}
    else
      {:error, _reason} -> {:error, :apply_failed}
    end
  end

  defp rescan(_scope, _state), do: {:error, :invalid}

  defp build_index(state) do
    index_call(state.index_ops, :build_snapshot, [state.root, []])
  end

  defp rebuild_startup_index(state) do
    snapshot =
      if File.dir?(state.root),
        do: build_index(state),
        else: {:ok, []}

    with {:ok, candidate_index} <- snapshot do
      index_call(state.index_ops, :replace, [candidate_index])
    end
  end

  defp index_snapshot(index_ops) do
    case index_call(index_ops, :snapshot, []) do
      snapshot when is_list(snapshot) -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_snapshot}
    end
  end

  defp load_ledger(path) do
    case Ledger.load(path) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger_load_failed, reason}}
    end
  end

  defp index_call(module, operation, arguments) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, operation, length(arguments)) do
      apply(module, operation, arguments)
    else
      {:error, :unsupported_index_ops}
    end
  rescue
    _exception -> {:error, :index_ops_exception}
  catch
    _kind, _reason -> {:error, :index_ops_exit}
  end

  defp index_call({module, context}, operation, arguments) when is_atom(module) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, operation, length(arguments) + 1) do
      apply(module, operation, arguments ++ [context])
    else
      {:error, :unsupported_index_ops}
    end
  rescue
    _exception -> {:error, :index_ops_exception}
  catch
    _kind, _reason -> {:error, :index_ops_exit}
  end

  defp validate_storage_paths(root, ledger_path) do
    if inside_root?(ledger_path, root), do: {:error, :ledger_inside_tftp_root}, else: :ok
  end

  defp inside_root?(path, root) do
    prefix = if root == "/", do: root, else: root <> "/"
    path == root or String.starts_with?(path, prefix)
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp scan_files(root, prefix) do
    full = Path.join(root, prefix)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        case File.ls(full) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              rel = if prefix == "", do: entry, else: Path.join(prefix, entry)
              scan_files(root, rel)
            end)

          _error ->
            []
        end

      {:ok, %{type: :regular} = stat} ->
        [%{path: prefix, size: stat.size, modified: stat.mtime, type: :file}]

      _other ->
        []
    end
  end

  defp safe_file_info(path, root) do
    if FileIndex.path_traversal?(path) do
      {:error, :path_traversal}
    else
      full = Path.join(root, path)

      case File.lstat(full) do
        {:ok, stat} ->
          {:ok,
           %{
             path: path,
             size: stat.size,
             modified: stat.mtime,
             type: if(stat.type == :directory, do: :directory, else: :file)
           }}

        {:error, :enoent} ->
          {:error, :not_found}
      end
    end
  end

  defp build_tree(root, prefix) do
    full = Path.join(root, prefix)

    case File.ls(full) do
      {:ok, entries} ->
        Enum.map(Enum.sort(entries), fn entry ->
          rel = if prefix == "", do: entry, else: Path.join(prefix, entry)
          entry_path = Path.join(full, entry)

          case File.lstat(entry_path) do
            {:ok, %{type: :directory}} ->
              %{name: entry, path: rel, type: :directory, children: build_tree(root, rel)}

            {:ok, %{type: :regular, size: size}} ->
              %{name: entry, path: rel, type: :file, size: size}

            _other ->
              %{name: entry, path: rel, type: :file, size: 0}
          end
        end)

      _error ->
        []
    end
  end
end
