defmodule YellowDog.Netboot.Asset.Store do
  @moduledoc """
  Owns managed Netboot asset metadata and safe payload lifecycle operations.
  """

  use GenServer

  alias YellowDog.Netboot.Asset.FileOps, as: AssetFileOps
  alias YellowDog.Netboot.Asset.Ledger
  alias YellowDog.Netboot.Asset.ManagedAsset
  alias YellowDog.Netboot.ManagedStorage.FileOps, as: StorageFileOps
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
  @spec control_delete_asset(String.t(), GenServer.server()) ::
          {:ok, map()} | {:error, atom()}
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

    file_ops = Keyword.get(opts, :file_ops, {StorageFileOps, nil})
    asset_file_ops = Keyword.get(opts, :asset_file_ops, {AssetFileOps, []})
    index_ops = Keyword.get(opts, :index_ops, FileIndex)

    state = %{
      root: root,
      ledger_path: ledger_path,
      ledger: Ledger.empty(),
      file_ops: file_ops,
      asset_file_ops: asset_file_ops,
      index_ops: index_ops
    }

    with :ok <- validate_storage_paths(root, ledger_path),
         :ok <- index_call(index_ops, :init, []),
         :ok <- index_call(index_ops, :replace, [[]]),
         {:ok, ledger} <- load_ledger(ledger_path, file_ops),
         {:ok, ledger} <- recover_interrupted_deletes(ledger, %{state | ledger: ledger}),
         :ok <- rebuild_startup_index(ledger, state) do
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
    case delete_asset(asset_id, state) do
      {:ok, resource, ledger} ->
        {:reply, {:ok, resource}, %{state | ledger: ledger}}

      {:error, reason, ledger} ->
        {:reply, {:error, reason}, %{state | ledger: ledger}}
    end
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

  defp delete_asset(asset_id, state) when is_binary(asset_id) do
    case Ledger.fetch(state.ledger, asset_id) do
      {:ok, %ManagedAsset{lifecycle: :active} = asset} ->
        begin_delete(asset, state)

      {:ok, %ManagedAsset{lifecycle: :tombstoned} = asset} ->
        resume_delete(asset, state.ledger, state)

      {:error, :not_found} ->
        {:error, :not_found, state.ledger}
    end
  end

  defp delete_asset(_asset_id, state), do: {:error, :invalid, state.ledger}

  defp begin_delete(asset, state) do
    payload_path = asset_path(state.root, asset.filename)
    tombstone_filename = ManagedAsset.tombstone_filename(asset)
    tombstone_path = asset_path(state.root, tombstone_filename)

    with {:ok, previous_index} <- index_snapshot(state.index_ops),
         :ok <- move_verified(payload_path, tombstone_path, asset, state.asset_file_ops),
         {:ok, tombstoned} <- ManagedAsset.tombstone(asset, tombstone_filename),
         {:ok, candidate_ledger} <- Ledger.replace(state.ledger, tombstoned) do
      commit_tombstoned_candidate(
        asset,
        candidate_ledger,
        previous_index,
        payload_path,
        tombstone_path,
        state
      )
    else
      {:error, :source_missing} ->
        deactivate_asset_paths(asset, state)
        {:error, :not_found, state.ledger}

      {:error, reason} when reason in [:source_mismatch, :source_changed] ->
        deactivate_asset_paths(asset, state)
        {:error, :conflict, state.ledger}

      {:error, :target_exists} ->
        {:error, :conflict, state.ledger}

      {:error, _reason} ->
        {:error, :apply_failed, state.ledger}
    end
  end

  defp commit_tombstoned_candidate(
         asset,
         candidate_ledger,
         previous_index,
         payload_path,
         tombstone_path,
         state
       ) do
    case write_ledger(state.ledger_path, candidate_ledger, state.file_ops) do
      :ok ->
        activate_candidate_or_rollback(
          asset,
          candidate_ledger,
          previous_index,
          payload_path,
          tombstone_path,
          state
        )

      {:error, _reason} ->
        rollback_before_activation(
          asset,
          state.ledger,
          candidate_ledger,
          previous_index,
          payload_path,
          tombstone_path,
          state,
          false
        )
    end
  end

  defp activate_candidate_or_rollback(
         asset,
         candidate_ledger,
         previous_index,
         payload_path,
         tombstone_path,
         state
       ) do
    with {:ok, candidate_index} <- build_index(candidate_ledger, state),
         :ok <- index_call(state.index_ops, :replace, [candidate_index]) do
      finish_delete(asset, candidate_ledger, tombstone_path, state)
    else
      {:error, _reason} ->
        rollback_before_activation(
          asset,
          state.ledger,
          candidate_ledger,
          previous_index,
          payload_path,
          tombstone_path,
          state,
          true
        )
    end
  end

  defp rollback_before_activation(
         asset,
         previous_ledger,
         candidate_ledger,
         previous_index,
         payload_path,
         tombstone_path,
         state,
         restore_ledger?
       ) do
    deactivate_asset_paths(asset, state)

    with :ok <-
           restore_payload(payload_path, tombstone_path, asset, state.asset_file_ops),
         :ok <-
           maybe_restore_ledger(
             restore_ledger?,
             state.ledger_path,
             previous_ledger,
             state.file_ops
           ),
         :ok <- index_call(state.index_ops, :replace, [previous_index]) do
      {:error, :apply_failed, previous_ledger}
    else
      {:error, _reason} ->
        preserve_tombstoned_candidate(asset, candidate_ledger, state)
    end
  end

  defp resume_delete(asset, ledger, state) do
    payload_path = asset_path(state.root, asset.filename)
    tombstone_path = asset_path(state.root, asset.tombstone_filename)

    case {path_state(payload_path), path_state(tombstone_path)} do
      {:missing, :regular} ->
        with {:ok, candidate_index} <- build_index(ledger, state),
             :ok <- index_call(state.index_ops, :replace, [candidate_index]) do
          finish_delete(asset, ledger, tombstone_path, state)
        else
          {:error, _reason} -> {:error, :apply_failed, ledger}
        end

      {:missing, :missing} ->
        with {:ok, candidate_index} <- build_index(ledger, state),
             :ok <- index_call(state.index_ops, :replace, [candidate_index]) do
          finalize_ledger(asset, ledger, state)
        else
          {:error, _reason} -> {:error, :apply_failed, ledger}
        end

      {:regular, :missing} ->
        with :ok <-
               move_verified(payload_path, tombstone_path, asset, state.asset_file_ops) do
          resume_delete(asset, ledger, state)
        else
          {:error, reason}
          when reason in [:source_mismatch, :source_changed, :target_exists] ->
            deactivate_asset_paths(asset, state)
            {:error, :conflict, ledger}

          {:error, _reason} ->
            {:error, :apply_failed, ledger}
        end

      _other ->
        {:error, :conflict, ledger}
    end
  end

  defp finish_delete(asset, ledger, tombstone_path, state) do
    case remove_verified(tombstone_path, asset, state.asset_file_ops) do
      :ok ->
        finalize_ledger(asset, ledger, state)

      {:error, reason} when reason in [:source_mismatch, :source_changed] ->
        deactivate_asset_paths(asset, state)
        {:error, :conflict, ledger}

      {:error, _reason} ->
        {:error, :apply_failed, ledger}
    end
  end

  defp finalize_ledger(asset, ledger, state) do
    final_ledger = Ledger.delete(ledger, asset.asset_id)

    case write_ledger(state.ledger_path, final_ledger, state.file_ops) do
      :ok -> {:ok, ManagedAsset.to_resource(asset), final_ledger}
      {:error, _reason} -> {:error, :apply_failed, ledger}
    end
  end

  defp recover_interrupted_deletes(ledger, state) do
    Enum.reduce_while(Ledger.list(ledger), {:ok, ledger}, fn asset, {:ok, current_ledger} ->
      state = %{state | ledger: current_ledger}

      case recover_asset(asset, state) do
        {:ok, recovered_ledger} -> {:cont, {:ok, recovered_ledger}}
        {:error, reason} -> {:halt, {:error, {:recovery_failed, reason}}}
      end
    end)
  end

  defp recover_asset(%ManagedAsset{lifecycle: :active} = asset, state) do
    payload_path = asset_path(state.root, asset.filename)
    tombstone_path = asset_path(state.root, ManagedAsset.tombstone_filename(asset))

    case {path_state(payload_path), path_state(tombstone_path)} do
      {:missing, :regular} ->
        with :ok <-
               move_verified(tombstone_path, payload_path, asset, state.asset_file_ops) do
          {:ok, state.ledger}
        else
          {:error, reason} -> {:error, reason}
        end

      {:regular, :regular} ->
        {:error, :conflict}

      {_payload, :other} ->
        {:error, :conflict}

      _other ->
        {:ok, state.ledger}
    end
  end

  defp recover_asset(%ManagedAsset{lifecycle: :tombstoned} = asset, state) do
    case resume_delete(asset, state.ledger, state) do
      {:ok, _resource, ledger} -> {:ok, ledger}
      {:error, reason, _ledger} -> {:error, reason}
    end
  end

  defp rescan(scope, state) when scope in ["all", "missing"] do
    with {:ok, previous_index} <- index_snapshot(state.index_ops),
         {:ok, candidate_index} <- build_index(state.ledger, state),
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

  defp build_index(ledger, state, extra_excluded \\ []) do
    excluded =
      ledger
      |> Ledger.list()
      |> Enum.flat_map(fn
        %ManagedAsset{
          lifecycle: :tombstoned,
          filename: filename,
          tombstone_filename: tombstone_filename
        } ->
          [filename, tombstone_filename]

        _asset ->
          []
      end)
      |> Kernel.++(extra_excluded)
      |> Enum.uniq()

    index_call(state.index_ops, :build_snapshot, [state.root, [exclude: excluded]])
  end

  defp rebuild_startup_index(ledger, state) do
    snapshot =
      if File.dir?(state.root),
        do: build_index(ledger, state),
        else: {:ok, []}

    with {:ok, candidate_index} <- snapshot do
      index_call(state.index_ops, :replace, [candidate_index])
    end
  end

  defp preserve_tombstoned_candidate(asset, candidate_ledger, state) do
    _ledger_result = write_ledger(state.ledger_path, candidate_ledger, state.file_ops)
    _index_result = activate_nonserving_index(asset, candidate_ledger, state)
    {:error, :rollback_failed, candidate_ledger}
  end

  defp activate_nonserving_index(asset, ledger, state) do
    with {:ok, candidate_index} <- build_index(ledger, state),
         :ok <- index_call(state.index_ops, :replace, [candidate_index]) do
      :ok
    else
      {:error, _reason} -> remove_asset_paths(asset, state)
    end
  end

  defp deactivate_asset_paths(asset, state) do
    _result = remove_asset_paths(asset, state)
    :ok
  end

  defp remove_asset_paths(asset, state) do
    paths = ManagedAsset.owned_filenames(asset)

    case index_call(state.index_ops, :remove, [paths]) do
      :ok -> :ok
      {:error, _reason} -> FileIndex.remove(paths)
    end
  end

  defp index_snapshot(index_ops) do
    case index_call(index_ops, :snapshot, []) do
      snapshot when is_list(snapshot) -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_snapshot}
    end
  end

  defp load_ledger(path, file_ops) do
    case Ledger.load(path, file_ops: file_ops) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger_load_failed, reason}}
    end
  end

  defp write_ledger(path, ledger, file_ops) do
    Ledger.write(path, ledger, file_ops: file_ops)
  end

  defp restore_payload(payload_path, tombstone_path, asset, asset_file_ops) do
    move_verified(tombstone_path, payload_path, asset, asset_file_ops)
  end

  defp maybe_restore_ledger(false, _path, _ledger, _file_ops), do: :ok

  defp maybe_restore_ledger(true, path, ledger, file_ops),
    do: write_ledger(path, ledger, file_ops)

  defp path_state(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :regular
      {:error, :enoent} -> :missing
      _other -> :other
    end
  end

  defp move_verified(source, target, asset, asset_file_ops) do
    asset_call(asset_file_ops, :move_verified, [source, target, asset])
  end

  defp remove_verified(path, asset, asset_file_ops) do
    asset_call(asset_file_ops, :remove_verified, [path, asset])
  end

  defp asset_call({module, context}, operation, arguments) do
    if is_atom(module) and Code.ensure_loaded?(module) and
         function_exported?(module, operation, length(arguments) + 1) do
      apply(module, operation, arguments ++ [context])
    else
      {:error, :unsupported_asset_file_ops}
    end
  rescue
    _exception -> {:error, :asset_file_ops_exception}
  catch
    _kind, _reason -> {:error, :asset_file_ops_exit}
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

  defp asset_path(root, filename), do: Path.join(root, filename)

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
