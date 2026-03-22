defmodule YellowDog.Fingerprint.OuiDatabase do
  @moduledoc """
  Runtime-reloadable OUI (MAC manufacturer) database.

  Stores the lookup table in ETS for fast concurrent reads.
  On startup, loads the compiled `gsmlg_mac` table as the baseline.
  Supports downloading the latest Wireshark `manuf.txt` and hot-reloading
  the lookup table without restarting the application.
  """

  use GenServer

  require Logger

  @table_name :oui_database_lookup
  @manuf_filename "manuf.txt"
  @manuf_url "https://www.wireshark.org/download/automated/data/manuf"

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up a MAC address in the runtime OUI database.

  Returns `{:ok, short_name, full_name}` or `:error`.
  """
  @spec lookup(String.t()) :: {:ok, String.t(), String.t()} | :error
  def lookup(mac) when is_binary(mac) do
    if :ets.whereis(@table_name) != :undefined do
      case :ets.lookup(@table_name, :lookup_table) do
        [{:lookup_table, table}] ->
          do_lookup(table, mac)

        [] ->
          :error
      end
    else
      :error
    end
  end

  @doc """
  Returns metadata about the currently loaded database.
  """
  @spec info() :: map()
  def info do
    GenServer.call(__MODULE__, :info)
  end

  @doc """
  Downloads the latest manuf.txt from Wireshark and reloads the lookup table.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec download() :: {:ok, Path.t()} | {:error, term()}
  def download do
    GenServer.call(__MODULE__, :download, :timer.minutes(5))
  end

  @doc """
  Reloads the lookup table from the on-disk manuf.txt file.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/fingerprint")

    try do: :ets.delete(@table_name), catch: (_, _ -> :ok)
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    manuf_path = Path.join(data_dir, @manuf_filename)

    {source, entry_count} =
      if File.exists?(manuf_path) do
        case load_from_file(manuf_path) do
          {:ok, count} -> {:file, count}
          {:error, _} -> load_compiled_fallback()
        end
      else
        load_compiled_fallback()
      end

    file_info = read_file_info(manuf_path)

    {:ok,
     %{
       data_dir: data_dir,
       source: source,
       entry_count: entry_count,
       file_info: file_info,
       loaded_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      source: state.source,
      entry_count: state.entry_count,
      loaded_at: state.loaded_at,
      file_info: state.file_info,
      manuf_path: Path.join(state.data_dir, @manuf_filename),
      download_url: @manuf_url
    }

    {:reply, info, state}
  end

  def handle_call(:download, _from, state) do
    manuf_path = Path.join(state.data_dir, @manuf_filename)

    case do_download(manuf_path) do
      {:ok, path} ->
        case load_from_file(path) do
          {:ok, count} ->
            file_info = read_file_info(path)

            new_state = %{
              state
              | source: :file,
                entry_count: count,
                file_info: file_info,
                loaded_at: DateTime.utc_now()
            }

            Logger.info("[OuiDatabase] Updated database",
              entries: count,
              path: path
            )

            {:reply, {:ok, path}, new_state}

          {:error, reason} ->
            {:reply, {:error, {:parse_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reload, _from, state) do
    manuf_path = Path.join(state.data_dir, @manuf_filename)

    if File.exists?(manuf_path) do
      case load_from_file(manuf_path) do
        {:ok, count} ->
          file_info = read_file_info(manuf_path)

          new_state = %{
            state
            | source: :file,
              entry_count: count,
              file_info: file_info,
              loaded_at: DateTime.utc_now()
          }

          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :enoent}, state}
    end
  end

  # --- Private ---

  defp load_from_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        table = GSMLG.MAC.Compiler.build_lookup_table(contents)
        count = GSMLG.MAC.Compiler.count_entries(table)
        :ets.insert(@table_name, {:lookup_table, table})
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_compiled_fallback do
    table = GSMLG.MAC.Vendor.mac_lookup_table()
    count = GSMLG.MAC.Compiler.count_entries(table)
    :ets.insert(@table_name, {:lookup_table, table})
    {:compiled, count}
  end

  defp do_download(target_path) do
    target_path |> Path.dirname() |> File.mkdir_p!()

    Logger.info("[OuiDatabase] Downloading manuf.txt", url: @manuf_url)

    Application.ensure_all_started(:http_fetch)

    case HTTP.fetch(@manuf_url) |> HTTP.Promise.await() do
      %{ok: true, body: body} ->
        case File.write(target_path, body) do
          :ok -> {:ok, target_path}
          {:error, reason} -> {:error, {:write_failed, reason}}
        end

      %{status: status} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp do_lookup(table, mac) do
    {key, bit_mac} =
      case GSMLG.MAC.Parser.to_bitstring(mac) do
        <<key::bits-size(24), _::bits-size(24)>> = bit_mac -> {key, bit_mac}
        _ -> {nil, nil}
      end

    case table[key] do
      vendor when is_list(vendor) ->
        {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}

      {key_bitsize, %{} = sub_match_map} ->
        <<sub_key::bits-size(key_bitsize), _::bits>> = bit_mac

        case sub_match_map[sub_key] do
          vendor when is_list(vendor) -> {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp read_file_info(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        %{size: size, mtime: mtime}

      _ ->
        nil
    end
  end
end
