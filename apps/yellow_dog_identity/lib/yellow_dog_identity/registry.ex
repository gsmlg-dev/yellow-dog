defmodule YellowDogIdentity.Registry do
  @moduledoc """
  TOML-based host identity and token storage.

  Manages persistent storage of host records and provisioning tokens
  using the copy-validate-replace pattern consistent with other Yellowdog stores.

  ## File Layout

      <data_dir>/identity/
      ├── hosts/
      │   ├── <uuid>.toml
      │   └── ...
      ├── tokens/
      │   ├── <uuid>.toml
      │   └── ...
      └── audit.log
  """

  use GenServer

  alias YellowDogIdentity.Host
  alias YellowDogIdentity.Token

  @type state :: %{
          data_dir: String.t(),
          hosts: %{String.t() => Host.t()},
          tokens: %{String.t() => Token.t()},
          fingerprint_index: %{String.t() => String.t()}
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stores a host record, persisting to TOML."
  @spec put_host(Host.t()) :: :ok | {:error, term()}
  def put_host(%Host{} = host), do: GenServer.call(__MODULE__, {:put_host, host})

  @doc "Gets a host by ID."
  @spec get_host(String.t()) :: {:ok, Host.t()} | :not_found
  def get_host(id), do: GenServer.call(__MODULE__, {:get_host, id})

  @doc "Gets a host by key fingerprint."
  @spec get_host_by_fingerprint(String.t()) :: {:ok, Host.t()} | :not_found
  def get_host_by_fingerprint(fingerprint),
    do: GenServer.call(__MODULE__, {:get_host_by_fingerprint, fingerprint})

  @doc "Gets a host by hostname."
  @spec get_host_by_hostname(String.t()) :: {:ok, Host.t()} | :not_found
  def get_host_by_hostname(hostname),
    do: GenServer.call(__MODULE__, {:get_host_by_hostname, hostname})

  @doc "Lists all host records."
  @spec list_hosts() :: [Host.t()]
  def list_hosts, do: GenServer.call(__MODULE__, :list_hosts)

  @doc "Lists hosts filtered by status."
  @spec list_hosts_by_status(Host.status()) :: [Host.t()]
  def list_hosts_by_status(status), do: GenServer.call(__MODULE__, {:list_hosts_by_status, status})

  @doc "Deletes a host record."
  @spec delete_host(String.t()) :: :ok | {:error, term()}
  def delete_host(id), do: GenServer.call(__MODULE__, {:delete_host, id})

  @doc "Stores a provisioning token."
  @spec put_token(Token.t()) :: :ok | {:error, term()}
  def put_token(%Token{} = token), do: GenServer.call(__MODULE__, {:put_token, token})

  @doc "Gets a token by ID."
  @spec get_token(String.t()) :: {:ok, Token.t()} | :not_found
  def get_token(id), do: GenServer.call(__MODULE__, {:get_token, id})

  @doc "Lists all tokens."
  @spec list_tokens() :: [Token.t()]
  def list_tokens, do: GenServer.call(__MODULE__, :list_tokens)

  @doc "Deletes a token."
  @spec delete_token(String.t()) :: :ok | {:error, term()}
  def delete_token(id), do: GenServer.call(__MODULE__, {:delete_token, id})

  @doc "Appends an entry to the append-only audit log."
  @spec append_audit(String.t(), String.t(), map()) :: :ok
  def append_audit(event, host_id, details \\ %{}) do
    GenServer.cast(__MODULE__, {:append_audit, event, host_id, details})
  end

  @doc "Reads the audit log, returning parsed entries. Options: limit, host_id, event."
  @spec read_audit_log(keyword()) :: [map()]
  def read_audit_log(opts \\ []) do
    GenServer.call(__MODULE__, {:read_audit_log, opts})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, default_data_dir())
    hosts_dir = Path.join(data_dir, "hosts")
    tokens_dir = Path.join(data_dir, "tokens")

    File.mkdir_p!(hosts_dir)
    File.mkdir_p!(tokens_dir)

    # Load existing data from disk
    {hosts, fingerprint_index} = load_hosts(hosts_dir)
    tokens = load_tokens(tokens_dir)

    state = %{
      data_dir: data_dir,
      hosts: hosts,
      tokens: tokens,
      fingerprint_index: fingerprint_index
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:put_host, host}, _from, state) do
    case persist_host(state.data_dir, host) do
      :ok ->
        hosts = Map.put(state.hosts, host.id, host)
        fingerprint_index = Map.put(state.fingerprint_index, host.key_fingerprint, host.id)
        {:reply, :ok, %{state | hosts: hosts, fingerprint_index: fingerprint_index}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get_host, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil -> {:reply, :not_found, state}
      host -> {:reply, {:ok, host}, state}
    end
  end

  def handle_call({:get_host_by_fingerprint, fingerprint}, _from, state) do
    case Map.get(state.fingerprint_index, fingerprint) do
      nil -> {:reply, :not_found, state}
      id -> {:reply, {:ok, Map.fetch!(state.hosts, id)}, state}
    end
  end

  def handle_call({:get_host_by_hostname, hostname}, _from, state) do
    case Enum.find(state.hosts, fn {_id, h} -> h.hostname == hostname end) do
      nil -> {:reply, :not_found, state}
      {_id, host} -> {:reply, {:ok, host}, state}
    end
  end

  def handle_call(:list_hosts, _from, state) do
    {:reply, Map.values(state.hosts), state}
  end

  def handle_call({:list_hosts_by_status, status}, _from, state) do
    filtered = state.hosts |> Map.values() |> Enum.filter(&(&1.status == status))
    {:reply, filtered, state}
  end

  def handle_call({:delete_host, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      host ->
        path = host_path(state.data_dir, id)
        File.rm(path)
        hosts = Map.delete(state.hosts, id)
        fingerprint_index = Map.delete(state.fingerprint_index, host.key_fingerprint)
        {:reply, :ok, %{state | hosts: hosts, fingerprint_index: fingerprint_index}}
    end
  end

  def handle_call({:put_token, token}, _from, state) do
    case persist_token(state.data_dir, token) do
      :ok ->
        tokens = Map.put(state.tokens, token.id, token)
        {:reply, :ok, %{state | tokens: tokens}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get_token, id}, _from, state) do
    case Map.get(state.tokens, id) do
      nil -> {:reply, :not_found, state}
      token -> {:reply, {:ok, token}, state}
    end
  end

  def handle_call(:list_tokens, _from, state) do
    {:reply, Map.values(state.tokens), state}
  end

  def handle_call({:delete_token, id}, _from, state) do
    path = token_path(state.data_dir, id)
    File.rm(path)
    tokens = Map.delete(state.tokens, id)
    {:reply, :ok, %{state | tokens: tokens}}
  end

  def handle_call({:read_audit_log, opts}, _from, state) do
    entries = read_audit_entries(state.data_dir, opts)
    {:reply, entries, state}
  end

  @impl true
  def handle_cast({:append_audit, event, host_id, details}, state) do
    write_audit_entry(state.data_dir, event, host_id, details)
    {:noreply, state}
  end

  # Persistence helpers

  defp persist_host(data_dir, host) do
    path = host_path(data_dir, host.id)
    toml_map = Host.to_toml_map(host)
    atomic_write_toml(path, toml_map)
  end

  defp persist_token(data_dir, token) do
    path = token_path(data_dir, token.id)
    toml_map = Token.to_toml_map(token)
    atomic_write_toml(path, toml_map)
  end

  defp atomic_write_toml(path, map) do
    content = encode_toml(map)
    tmp_path = path <> ".tmp"
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    with :ok <- File.write(tmp_path, content),
         # Validate round-trip
         {:ok, _} <- read_and_parse_toml(tmp_path),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp read_and_parse_toml(path) do
    case File.read(path) do
      {:ok, content} -> Toml.decode(content)
      error -> error
    end
  end

  defp encode_toml(map) do
    encode_toml_section(map, [])
  end

  defp encode_toml_section(map, path) when is_map(map) do
    {simple, nested} = Enum.split_with(map, fn {_k, v} -> not is_map(v) end)

    simple_lines =
      if path != [] and simple != [] do
        header = "[#{Enum.join(path, ".")}]\n"
        lines = Enum.map_join(simple, "\n", fn {k, v} -> "#{k} = #{encode_toml_value(v)}" end)
        header <> lines <> "\n"
      else
        Enum.map_join(simple, "\n", fn {k, v} -> "#{k} = #{encode_toml_value(v)}" end)
        |> then(fn s -> if s == "", do: "", else: s <> "\n" end)
      end

    nested_lines =
      Enum.map_join(nested, "\n", fn {k, v} ->
        encode_toml_section(v, path ++ [k])
      end)

    simple_lines <> nested_lines
  end

  defp encode_toml_value(v) when is_binary(v), do: ~s("#{String.replace(v, "\"", "\\\"")}")
  defp encode_toml_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_toml_value(v) when is_float(v), do: Float.to_string(v)
  defp encode_toml_value(true), do: "true"
  defp encode_toml_value(false), do: "false"
  defp encode_toml_value(nil), do: ~s("")

  defp encode_toml_value(v) when is_list(v) do
    items = Enum.map_join(v, ", ", &encode_toml_value/1)
    "[#{items}]"
  end

  defp encode_toml_value(v) when is_map(v) do
    items =
      Enum.map_join(v, ", ", fn {k, val} ->
        "#{k} = #{encode_toml_value(val)}"
      end)

    "{#{items}}"
  end

  defp encode_toml_value(v), do: ~s("#{inspect(v)}")

  # Loading helpers

  defp load_hosts(hosts_dir) do
    hosts_dir
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.reduce({%{}, %{}}, fn path, {hosts, idx} ->
      case load_host_file(path) do
        {:ok, host} ->
          {Map.put(hosts, host.id, host), Map.put(idx, host.key_fingerprint, host.id)}

        {:error, _reason} ->
          {hosts, idx}
      end
    end)
  end

  defp load_host_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Toml.decode(content),
         {:ok, host} <- Host.from_toml_map(data) do
      {:ok, host}
    end
  end

  defp load_tokens(tokens_dir) do
    tokens_dir
    |> Path.join("*.toml")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc ->
      case load_token_file(path) do
        {:ok, token} -> Map.put(acc, token.id, token)
        {:error, _} -> acc
      end
    end)
  end

  defp load_token_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Toml.decode(content),
         {:ok, token} <- Token.from_toml_map(data) do
      {:ok, token}
    end
  end

  defp write_audit_entry(data_dir, event, host_id, details) do
    audit_path = Path.join(data_dir, "audit.log")
    timestamp = DateTime.to_iso8601(DateTime.utc_now())
    details_str = if details == %{}, do: "", else: " " <> inspect(details)

    entry = "#{timestamp} #{event} host=#{host_id}#{details_str}\n"

    File.write(audit_path, entry, [:append])
  rescue
    _ -> :ok
  end

  defp read_audit_entries(data_dir, opts) do
    audit_path = Path.join(data_dir, "audit.log")
    limit = Keyword.get(opts, :limit, 100)
    host_filter = Keyword.get(opts, :host_id)
    event_filter = Keyword.get(opts, :event)

    case File.read(audit_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Stream.map(&parse_audit_line/1)
        |> Stream.reject(&is_nil/1)
        |> maybe_filter(:host_id, host_filter)
        |> maybe_filter(:event, event_filter)
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_audit_line(line) do
    # Format: "2024-01-01T00:00:00Z event host=<id> <details>"
    case Regex.run(~r/^(\S+)\s+(\S+)\s+host=(\S+)(.*)$/, line) do
      [_, timestamp, event, host_id, rest] ->
        %{
          timestamp: timestamp,
          event: event,
          host_id: host_id,
          details: String.trim(rest)
        }

      _ ->
        nil
    end
  end

  defp maybe_filter(stream, _field, nil), do: stream
  defp maybe_filter(stream, field, value), do: Stream.filter(stream, &(&1[field] == value))

  defp host_path(data_dir, id), do: Path.join([data_dir, "hosts", "#{id}.toml"])
  defp token_path(data_dir, id), do: Path.join([data_dir, "tokens", "#{id}.toml"])

  defp default_data_dir do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          Path.join(YellowDog.Config.get_service_data_dir(:identity), "")
        rescue
          _ -> "data/identity"
        catch
          :exit, _ -> "data/identity"
        end

      _ ->
        "data/identity"
    end
  end
end
