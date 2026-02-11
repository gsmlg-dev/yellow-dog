defmodule YellowDog.Netboot.Asset.Store do
  @moduledoc """
  Boot asset file management.

  Manages the TFTP root directory — listing, uploading, and deleting
  boot assets (kernels, initrds, iPXE binaries).
  """

  use GenServer

  @default_root "/srv/netboot/tftp"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all files in the TFTP root."
  @spec list_files() :: [map()]
  def list_files do
    GenServer.call(__MODULE__, :list_files)
  end

  @doc "Get file info by relative path."
  @spec get_file(String.t()) :: {:ok, map()} | {:error, :not_found | :path_traversal}
  def get_file(relative_path) do
    GenServer.call(__MODULE__, {:get_file, relative_path})
  end

  @doc "Delete a file from the TFTP root."
  @spec delete_file(String.t()) :: :ok | {:error, term()}
  def delete_file(relative_path) do
    GenServer.call(__MODULE__, {:delete_file, relative_path})
  end

  @doc "Get the root directory path."
  @spec root_dir() :: String.t()
  def root_dir do
    GenServer.call(__MODULE__, :root_dir)
  end

  @doc "Upload a file to the TFTP root."
  @spec upload_file(String.t(), String.t()) :: :ok | {:error, term()}
  def upload_file(relative_path, source_path) do
    GenServer.call(__MODULE__, {:upload_file, relative_path, source_path})
  end

  @doc "Build a directory tree structure."
  @spec file_tree() :: [map()]
  def file_tree do
    GenServer.call(__MODULE__, :file_tree)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    root = Map.get(config, :tftp_root, @default_root)
    {:ok, %{root: root}}
  end

  @impl true
  def handle_call(:list_files, _from, state) do
    files = scan_files(state.root, "")
    {:reply, files, state}
  end

  @impl true
  def handle_call({:get_file, path}, _from, state) do
    result = safe_file_info(path, state.root)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_file, path}, _from, state) do
    if YellowDog.Netboot.TFTP.FileIndex.path_traversal?(path) do
      {:reply, {:error, :path_traversal}, state}
    else
      full_path = Path.join(state.root, path)

      case File.rm(full_path) do
        :ok -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:upload_file, path, source}, _from, state) do
    if YellowDog.Netboot.TFTP.FileIndex.path_traversal?(path) do
      {:reply, {:error, :path_traversal}, state}
    else
      dest = Path.join(state.root, path)
      dest_dir = Path.dirname(dest)

      with :ok <- File.mkdir_p(dest_dir),
           {:ok, _bytes} <- File.copy(source, dest) do
        {:reply, :ok, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:root_dir, _from, state) do
    {:reply, state.root, state}
  end

  @impl true
  def handle_call(:file_tree, _from, state) do
    tree = build_tree(state.root, "")
    {:reply, tree, state}
  end

  # --- Private ---

  defp scan_files(root, prefix) do
    full = Path.join(root, prefix)

    if File.dir?(full) do
      case File.ls(full) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            rel = if prefix == "", do: entry, else: Path.join(prefix, entry)
            scan_files(root, rel)
          end)

        _ ->
          []
      end
    else
      case File.stat(full) do
        {:ok, stat} ->
          [
            %{
              path: prefix,
              size: stat.size,
              modified: stat.mtime,
              type: :file
            }
          ]

        _ ->
          []
      end
    end
  end

  defp safe_file_info(path, root) do
    if YellowDog.Netboot.TFTP.FileIndex.path_traversal?(path) do
      {:error, :path_traversal}
    else
      full = Path.join(root, path)

      case File.stat(full) do
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

          if File.dir?(entry_path) do
            %{name: entry, path: rel, type: :directory, children: build_tree(root, rel)}
          else
            case File.stat(entry_path) do
              {:ok, stat} -> %{name: entry, path: rel, type: :file, size: stat.size}
              _ -> %{name: entry, path: rel, type: :file, size: 0}
            end
          end
        end)

      _ ->
        []
    end
  end
end
