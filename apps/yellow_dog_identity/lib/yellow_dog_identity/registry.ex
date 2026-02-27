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

  require Logger

  alias YellowDogIdentity.Host
  alias YellowDogIdentity.Token

  # Clean up expired tokens every hour
  @token_cleanup_interval_ms :timer.hours(1)

  @type state :: %{
          data_dir: String.t(),
          hosts: %{String.t() => Host.t()},
          tokens: %{String.t() => Token.t()},
          fingerprint_index: %{String.t() => String.t()},
          hostname_index: %{String.t() => String.t()},
          instance_id_index: %{String.t() => String.t()}
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

  @doc """
  Atomically checks fingerprint and instance ID uniqueness, then stores a host.

  Avoids TOCTOU races where two concurrent registrations with the same
  fingerprint or cloud instance ID both pass uniqueness checks before either persists.
  """
  @spec put_host_checked(Host.t()) ::
          :ok
          | {:error, :fingerprint_conflict}
          | {:error, :instance_id_conflict}
          | {:error, term()}
  def put_host_checked(%Host{} = host),
    do: GenServer.call(__MODULE__, {:put_host_checked, host})

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
  def list_hosts_by_status(status),
    do: GenServer.call(__MODULE__, {:list_hosts_by_status, status})

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

  @doc """
  Atomically verifies a raw token and increments its use count in a single GenServer call.

  Avoids the TOCTOU race where two concurrent callers both pass the use-count check
  before either has persisted the increment.
  """
  @spec consume_token(String.t(), String.t()) :: {:ok, Token.t()} | {:error, term()}
  def consume_token(raw_token, hostname),
    do: GenServer.call(__MODULE__, {:consume_token, raw_token, hostname})

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

    with :ok <- File.mkdir_p(hosts_dir),
         :ok <- File.mkdir_p(tokens_dir) do
      # Load existing data from disk
      {hosts, fingerprint_index, hostname_index} = load_hosts(hosts_dir)
      tokens = load_tokens(tokens_dir)
      instance_id_index = build_instance_id_index(hosts)

      state = %{
        data_dir: data_dir,
        hosts: hosts,
        tokens: tokens,
        fingerprint_index: fingerprint_index,
        hostname_index: hostname_index,
        instance_id_index: instance_id_index
      }

      Process.send_after(self(), :cleanup_expired_tokens, @token_cleanup_interval_ms)
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to create identity data directories: #{inspect(reason)}")
        {:stop, {:mkdir_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put_host, host}, _from, state) do
    do_put_host(host, state)
  end

  def handle_call({:put_host_checked, host}, _from, state) do
    cond do
      has_fingerprint_conflict?(state.fingerprint_index, host.key_fingerprint, host.id) ->
        {:reply, {:error, :fingerprint_conflict}, state}

      has_instance_id_conflict?(state.instance_id_index, host.trust_evidence, host.id) ->
        {:reply, {:error, :instance_id_conflict}, state}

      true ->
        do_put_host(host, state)
    end
  end

  @impl true
  def handle_call({:get_host, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil -> {:reply, :not_found, state}
      host -> {:reply, {:ok, host}, state}
    end
  end

  @impl true
  def handle_call({:get_host_by_fingerprint, fingerprint}, _from, state) do
    case Map.get(state.fingerprint_index, fingerprint) do
      nil ->
        {:reply, :not_found, state}

      id ->
        case Map.fetch(state.hosts, id) do
          {:ok, host} -> {:reply, {:ok, host}, state}
          :error -> {:reply, :not_found, state}
        end
    end
  end

  @impl true
  def handle_call({:get_host_by_hostname, hostname}, _from, state) do
    case Map.get(state.hostname_index, hostname) do
      nil ->
        {:reply, :not_found, state}

      id ->
        case Map.fetch(state.hosts, id) do
          {:ok, host} -> {:reply, {:ok, host}, state}
          :error -> {:reply, :not_found, state}
        end
    end
  end

  @impl true
  def handle_call(:list_hosts, _from, state) do
    {:reply, Map.values(state.hosts), state}
  end

  @impl true
  def handle_call({:list_hosts_by_status, status}, _from, state) do
    filtered = state.hosts |> Map.values() |> Enum.filter(&(&1.status == status))
    {:reply, filtered, state}
  end

  @impl true
  def handle_call({:delete_host, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      host ->
        path = host_path(state.data_dir, id)

        delete_result =
          case File.rm(path) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, reason}
          end

        case delete_result do
          :ok ->
            hosts = Map.delete(state.hosts, id)
            fingerprint_index = Map.delete(state.fingerprint_index, host.key_fingerprint)
            hostname_index = Map.delete(state.hostname_index, host.hostname)

            instance_id_index =
              case get_instance_id(host.trust_evidence) do
                nil -> state.instance_id_index
                iid -> Map.delete(state.instance_id_index, iid)
              end

            {:reply, :ok,
             %{
               state
               | hosts: hosts,
                 fingerprint_index: fingerprint_index,
                 hostname_index: hostname_index,
                 instance_id_index: instance_id_index
             }}

          {:error, reason} ->
            Logger.warning("Failed to delete host file #{path}: #{reason}")
            {:reply, {:error, :delete_failed}, state}
        end
    end
  end

  @impl true
  def handle_call({:put_token, token}, _from, state) do
    case persist_token(state.data_dir, token) do
      :ok ->
        tokens = Map.put(state.tokens, token.id, token)
        {:reply, :ok, %{state | tokens: tokens}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_token, id}, _from, state) do
    case Map.get(state.tokens, id) do
      nil -> {:reply, :not_found, state}
      token -> {:reply, {:ok, token}, state}
    end
  end

  @impl true
  def handle_call(:list_tokens, _from, state) do
    {:reply, Map.values(state.tokens), state}
  end

  @impl true
  def handle_call({:delete_token, id}, _from, state) do
    case Map.get(state.tokens, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _token ->
        path = token_path(state.data_dir, id)

        delete_result =
          case File.rm(path) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, reason}
          end

        case delete_result do
          :ok ->
            tokens = Map.delete(state.tokens, id)
            {:reply, :ok, %{state | tokens: tokens}}

          {:error, reason} ->
            Logger.warning("Failed to delete token file #{path}: #{reason}")
            {:reply, {:error, :delete_failed}, state}
        end
    end
  end

  @impl true
  def handle_call({:consume_token, raw_token, hostname}, _from, state) do
    tokens = Map.values(state.tokens)

    case do_consume_token(tokens, raw_token, hostname, state.data_dir) do
      {:ok, updated_token} ->
        new_tokens = Map.put(state.tokens, updated_token.id, updated_token)
        {:reply, {:ok, updated_token}, %{state | tokens: new_tokens}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:read_audit_log, opts}, _from, state) do
    entries = read_audit_entries(state.data_dir, opts)
    {:reply, entries, state}
  end

  @impl true
  def handle_cast({:append_audit, event, host_id, details}, state) do
    write_audit_entry(state.data_dir, event, host_id, details)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_expired_tokens, state) do
    now = DateTime.utc_now()

    expired_ids =
      state.tokens
      |> Enum.filter(fn {_id, token} -> DateTime.compare(now, token.expires_at) == :gt end)
      |> Enum.map(fn {id, _token} -> id end)

    state =
      Enum.reduce(expired_ids, state, fn id, acc ->
        path = token_path(acc.data_dir, id)

        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> Logger.warning("Failed to delete expired token #{id}: #{reason}")
        end

        %{acc | tokens: Map.delete(acc.tokens, id)}
      end)

    if expired_ids != [] do
      Logger.info("Cleaned up #{length(expired_ids)} expired token(s)")
    end

    Process.send_after(self(), :cleanup_expired_tokens, @token_cleanup_interval_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Token consumption helper (used by consume_token handle_call)

  defp do_consume_token(tokens, raw_token, hostname, data_dir) do
    Enum.reduce_while(tokens, {:error, :invalid_token}, fn token, acc ->
      case Token.verify(token, raw_token, hostname) do
        :ok ->
          updated = Token.increment_use(token)

          case persist_token(data_dir, updated) do
            :ok -> {:halt, {:ok, updated}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, :hostname_mismatch} ->
          {:cont, {:error, :hostname_mismatch}}

        {:error, _} ->
          {:cont, acc}
      end
    end)
  end

  # Internal helpers for put_host

  defp do_put_host(host, state) do
    case persist_host(state.data_dir, host) do
      :ok ->
        old_host = Map.get(state.hosts, host.id)

        # Remove stale fingerprint index entry if host existed with a different key
        fingerprint_index =
          case old_host do
            %{key_fingerprint: old_fp} when old_fp != host.key_fingerprint ->
              Map.delete(state.fingerprint_index, old_fp)

            _ ->
              state.fingerprint_index
          end

        # Remove stale hostname index entry if host changed hostname
        hostname_index =
          case old_host do
            %{hostname: old_hn} when old_hn != host.hostname ->
              Map.delete(state.hostname_index, old_hn)

            _ ->
              state.hostname_index
          end

        # Remove stale instance_id index entry if host changed instance ID
        instance_id_index =
          case old_host do
            %{trust_evidence: old_ev} ->
              old_iid = get_instance_id(old_ev)
              new_iid = get_instance_id(host.trust_evidence)

              if old_iid && old_iid != new_iid do
                Map.delete(state.instance_id_index, old_iid)
              else
                state.instance_id_index
              end

            _ ->
              state.instance_id_index
          end

        hosts = Map.put(state.hosts, host.id, host)
        fingerprint_index = Map.put(fingerprint_index, host.key_fingerprint, host.id)
        hostname_index = Map.put(hostname_index, host.hostname, host.id)

        # Add new instance_id to index
        new_iid = get_instance_id(host.trust_evidence)

        instance_id_index =
          if new_iid,
            do: Map.put(instance_id_index, new_iid, host.id),
            else: instance_id_index

        {:reply, :ok,
         %{
           state
           | hosts: hosts,
             fingerprint_index: fingerprint_index,
             hostname_index: hostname_index,
             instance_id_index: instance_id_index
         }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp has_fingerprint_conflict?(fingerprint_index, fingerprint, host_id) do
    case Map.get(fingerprint_index, fingerprint) do
      nil -> false
      ^host_id -> false
      _other_id -> true
    end
  end

  defp has_instance_id_conflict?(instance_id_index, trust_evidence, host_id) do
    case get_instance_id(trust_evidence) do
      nil ->
        false

      iid ->
        case Map.get(instance_id_index, iid) do
          nil -> false
          ^host_id -> false
          _other_id -> true
        end
    end
  end

  defp get_instance_id(evidence) when is_map(evidence) do
    id = Map.get(evidence, :instance_id) || Map.get(evidence, "instance_id")
    if id, do: to_string(id), else: nil
  end

  defp get_instance_id(_), do: nil

  defp build_instance_id_index(hosts) do
    Enum.reduce(hosts, %{}, fn {id, host}, acc ->
      case get_instance_id(host.trust_evidence) do
        nil -> acc
        iid -> Map.put(acc, iid, id)
      end
    end)
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

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, content),
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

  defp encode_toml_value(v) when is_binary(v) do
    escaped =
      v
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end
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
    |> Enum.reduce({%{}, %{}, %{}}, fn path, {hosts, fp_idx, hn_idx} ->
      case load_host_file(path) do
        {:ok, host} ->
          {
            Map.put(hosts, host.id, host),
            Map.put(fp_idx, host.key_fingerprint, host.id),
            Map.put(hn_idx, host.hostname, host.id)
          }

        {:error, _reason} ->
          {hosts, fp_idx, hn_idx}
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

    # Sanitize to prevent log injection via embedded newlines
    safe_event = sanitize_log_field(event)
    safe_host_id = sanitize_log_field(host_id)
    safe_details = sanitize_log_field(details_str)

    entry = "#{timestamp} #{safe_event} host=#{safe_host_id}#{safe_details}\n"

    case File.write(audit_path, entry, [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to write audit log entry: #{reason}")
    end
  rescue
    e -> Logger.warning("Unexpected error writing audit log: #{Exception.message(e)}")
  end

  defp sanitize_log_field(value) when is_binary(value) do
    String.replace(value, ~r/[\r\n]/, " ")
  end

  defp sanitize_log_field(value), do: sanitize_log_field(to_string(value))

  defp read_audit_entries(data_dir, opts) do
    audit_path = Path.join(data_dir, "audit.log")
    limit = opts |> Keyword.get(:limit, 100) |> min(1000)
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
    e -> Logger.debug("Failed to read audit entries: #{inspect(e)}")
    []
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
