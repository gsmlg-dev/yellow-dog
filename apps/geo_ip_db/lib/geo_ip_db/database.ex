defmodule GeoIpDb.Database do
  @moduledoc """
  GenServer for loading and managing MMDB database files.

  This module handles:
  - Loading MMDB files from disk
  - Caching parsed database structures in ETS
  - Performing IP lookups against loaded databases

  ## Database Storage

  Databases are stored in an ETS table with the structure:
  - Key: database name (atom)
  - Value: {metadata, tree, data} tuple from MMDB2Decoder
  """

  use GenServer

  require Logger

  @table_name :geo_ip_db_databases
  @default_databases %{
    city: "dbip-city-lite.mmdb",
    country: "dbip-country-lite.mmdb"
  }

  # Client API

  @doc """
  Starts the database server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up an IP address in the specified database.

  Returns the raw MMDB data structure. Use `GeoIpDb.lookup/2` for
  a normalized result.
  """
  @spec lookup(:inet.ip_address(), atom()) :: {:ok, map() | nil} | {:error, term()}
  def lookup(ip, database \\ :city) do
    case :ets.lookup(@table_name, database) do
      [{^database, meta, tree, data}] ->
        # MMDB2Decoder.lookup returns {:ok, data} or {:error, reason}
        MMDB2Decoder.lookup(ip, meta, tree, data)

      [] ->
        {:error, {:database_not_loaded, database}}
    end
  end

  @doc """
  Loads a database from a file path.
  """
  @spec load(atom(), Path.t()) :: :ok | {:error, term()}
  def load(name, path) do
    GenServer.call(__MODULE__, {:load, name, path})
  end

  @doc """
  Unloads a database.
  """
  @spec unload(atom()) :: :ok
  def unload(name) do
    GenServer.call(__MODULE__, {:unload, name})
  end

  @doc """
  Lists all loaded database names.
  """
  @spec list_databases() :: [atom()]
  def list_databases do
    :ets.tab2list(@table_name)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Gets metadata for a loaded database.
  """
  @spec get_metadata(atom()) :: {:ok, map()} | {:error, term()}
  def get_metadata(database) do
    case :ets.lookup(@table_name, database) do
      [{^database, meta, _tree, _data}] ->
        {:ok, format_metadata(meta)}

      [] ->
        {:error, {:database_not_loaded, database}}
    end
  end

  @doc """
  Checks if a database is loaded.
  """
  @spec loaded?(atom()) :: boolean()
  def loaded?(name) do
    :ets.member(@table_name, name)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])

    # Load default databases on startup
    load_default_databases()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:load, name, path}, _from, state) do
    result = do_load(name, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:unload, name}, _from, state) do
    :ets.delete(@table_name, name)
    {:reply, :ok, state}
  end

  # Private Functions

  defp load_default_databases do
    priv_dir = :code.priv_dir(:geo_ip_db)

    configured_databases =
      Application.get_env(:geo_ip_db, :databases, @default_databases)

    Enum.each(configured_databases, fn {name, filename} ->
      path =
        if Path.type(filename) == :absolute do
          filename
        else
          Path.join([priv_dir, "data", filename])
        end

      case do_load(name, path) do
        :ok ->
          Logger.info("[GeoIpDb] Loaded database", database: name, path: path)

        {:error, :enoent} ->
          Logger.warning("[GeoIpDb] Database file not found", path: path)

        {:error, reason} ->
          Logger.error("[GeoIpDb] Failed to load database",
            database: name,
            error: inspect(reason)
          )
      end
    end)
  end

  defp do_load(name, path) do
    with {:ok, data} <- File.read(path),
         {:ok, meta, tree, db_data} <- MMDB2Decoder.parse_database(data) do
      :ets.insert(@table_name, {name, meta, tree, db_data})
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp format_metadata(meta) do
    %{
      binary_format_major_version: meta.binary_format_major_version,
      binary_format_minor_version: meta.binary_format_minor_version,
      build_epoch: DateTime.from_unix!(meta.build_epoch),
      database_type: meta.database_type,
      description: meta.description,
      ip_version: meta.ip_version,
      languages: meta.languages,
      node_count: meta.node_count,
      record_size: meta.record_size
    }
  end
end
