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

  @required_host_keys ~w(
    id
    hostname
    ssh_pubkey
    key_fingerprint
    age_recipient
    status
    trust_level
    trust_provider
    created_at
  )
  @optional_host_keys ~w(
    machine_id
    role
    datacenter
    approved_at
    approved_by
    revoked_at
    revoked_by
    revoke_reason
    trust_evidence
    metadata
    previous_keys
  )
  @valid_statuses ~w(pending approved revoked)
  @valid_trust_levels ~w(
    cloud_verified
    netboot_verified
    network_verified
    network_partial
    token_verified
    unverified
  )
  @valid_trust_providers ~w(dhcp netboot aws gcp azure token none)
  @max_control_id_bytes 128
  @max_control_name_bytes 1_024
  @max_persisted_collection_size 1_000

  @type state :: %{
          data_dir: String.t(),
          hosts: %{String.t() => Host.t()},
          tokens: %{String.t() => Token.t()},
          fingerprint_index: %{String.t() => String.t()},
          host_load_status: :ok | :persistence_failed,
          file_ops: module() | {module(), term()}
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

  @doc false
  @spec control_list_hosts() :: {:ok, [Host.t()]} | {:error, :persistence_failed}
  def control_list_hosts, do: GenServer.call(__MODULE__, :control_list_hosts)

  @doc false
  @spec control_get_host(String.t()) ::
          {:ok, Host.t()} | {:error, :not_found | :persistence_failed}
  def control_get_host(id), do: GenServer.call(__MODULE__, {:control_get_host, id})

  @doc "Lists hosts filtered by status."
  @spec list_hosts_by_status(Host.status()) :: [Host.t()]
  def list_hosts_by_status(status),
    do: GenServer.call(__MODULE__, {:list_hosts_by_status, status})

  @doc "Deletes a host record."
  @spec delete_host(String.t()) :: :ok | {:error, term()}
  def delete_host(id), do: GenServer.call(__MODULE__, {:delete_host, id})

  @doc false
  @spec control_approve_host(String.t(), String.t()) ::
          {:ok, Host.t(), Host.t()} | {:error, term()}
  def control_approve_host(id, approved_by),
    do: GenServer.call(__MODULE__, {:control_approve_host, id, approved_by})

  @doc false
  @spec control_revoke_host(String.t(), String.t(), String.t()) ::
          {:ok, Host.t(), Host.t()} | {:error, term()}
  def control_revoke_host(id, revoked_by, reason),
    do: GenServer.call(__MODULE__, {:control_revoke_host, id, revoked_by, reason})

  @doc false
  @spec control_delete_host(String.t()) :: {:ok, Host.t()} | {:error, term()}
  def control_delete_host(id), do: GenServer.call(__MODULE__, {:control_delete_host, id})

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

  @doc false
  @spec control_read_audit_log(keyword()) ::
          {:ok, [map()]} | {:error, :persistence_failed}
  def control_read_audit_log(opts \\ []) do
    GenServer.call(__MODULE__, {:control_read_audit_log, opts})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, default_data_dir())
    file_ops = Keyword.get(opts, :file_ops, File)
    hosts_dir = Path.join(data_dir, "hosts")
    tokens_dir = Path.join(data_dir, "tokens")

    with :ok <- file_call(file_ops, :mkdir_p, [hosts_dir]),
         :ok <- file_call(file_ops, :mkdir_p, [tokens_dir]) do
      # Load existing data from disk
      {hosts, fingerprint_index, host_load_status} = load_hosts(hosts_dir, file_ops)
      tokens = load_tokens(tokens_dir, file_ops)

      state = %{
        data_dir: data_dir,
        hosts: hosts,
        tokens: tokens,
        fingerprint_index: fingerprint_index,
        host_load_status: host_load_status,
        file_ops: file_ops
      }

      {:ok, state}
    else
      _failure -> {:stop, :persistence_failed}
    end
  end

  @impl true
  def handle_call({:put_host, host}, _from, state) do
    case persist_host(state, host, :legacy) do
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

  def handle_call(
        {:control_get_host, _id},
        _from,
        %{host_load_status: :persistence_failed} = state
      ) do
    {:reply, {:error, :persistence_failed}, state}
  end

  def handle_call({:control_get_host, id}, _from, state) do
    case Map.get(state.hosts, id) do
      nil -> {:reply, {:error, :not_found}, state}
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

  def handle_call(
        :control_list_hosts,
        _from,
        %{host_load_status: :persistence_failed} = state
      ) do
    {:reply, {:error, :persistence_failed}, state}
  end

  def handle_call(:control_list_hosts, _from, state) do
    {:reply, {:ok, Map.values(state.hosts)}, state}
  end

  def handle_call({:list_hosts_by_status, status}, _from, state) do
    filtered = state.hosts |> Map.values() |> Enum.filter(&(&1.status == status))
    {:reply, filtered, state}
  end

  def handle_call({:delete_host, id}, _from, state) do
    case legacy_delete_host_record(state, id) do
      {:ok, _host, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:control_approve_host, _id, _approved_by},
        _from,
        %{host_load_status: :persistence_failed} = state
      ) do
    {:reply, {:error, :persistence_failed}, state}
  end

  def handle_call({:control_approve_host, id, approved_by}, _from, state) do
    case Map.get(state.hosts, id) do
      %Host{status: :pending} = host ->
        updated = %{
          host
          | status: :approved,
            approved_at: DateTime.utc_now(),
            approved_by: approved_by
        }

        reply_host_update(state, host, updated)

      %Host{status: status} ->
        {:reply, {:error, {:invalid_status, status}}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:control_revoke_host, _id, _revoked_by, _reason},
        _from,
        %{host_load_status: :persistence_failed} = state
      ) do
    {:reply, {:error, :persistence_failed}, state}
  end

  def handle_call({:control_revoke_host, id, revoked_by, reason}, _from, state) do
    case Map.get(state.hosts, id) do
      %Host{status: status} = host when status in [:approved, :pending] ->
        updated = %{
          host
          | status: :revoked,
            revoked_at: DateTime.utc_now(),
            revoked_by: revoked_by,
            revoke_reason: reason
        }

        reply_host_update(state, host, updated)

      %Host{status: :revoked} ->
        {:reply, {:error, :already_revoked}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:control_delete_host, _id},
        _from,
        %{host_load_status: :persistence_failed} = state
      ) do
    {:reply, {:error, :persistence_failed}, state}
  end

  def handle_call({:control_delete_host, id}, _from, state) do
    case delete_host_record(state, id) do
      {:ok, host, state} -> {:reply, {:ok, host}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_token, token}, _from, state) do
    case persist_token(state, token, :legacy) do
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
    case legacy_delete_token_record(state, id) do
      {:ok, _token, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:consume_token, raw_token, hostname}, _from, state) do
    tokens = Map.values(state.tokens)

    case do_consume_token(tokens, raw_token, hostname, state) do
      {:ok, updated_token} ->
        new_tokens = Map.put(state.tokens, updated_token.id, updated_token)
        {:reply, {:ok, updated_token}, %{state | tokens: new_tokens}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read_audit_log, opts}, _from, state) do
    entries =
      case read_audit_entries(state.data_dir, opts, state.file_ops, :best_effort) do
        {:ok, entries} -> entries
        {:error, :persistence_failed} -> []
      end

    {:reply, entries, state}
  end

  def handle_call({:control_read_audit_log, opts}, _from, state) do
    {:reply, read_audit_entries(state.data_dir, opts, state.file_ops, :strict), state}
  end

  @impl true
  def handle_cast({:append_audit, event, host_id, details}, state) do
    write_audit_entry(state.data_dir, event, host_id, details)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Token consumption helper (used by consume_token handle_call)

  defp do_consume_token(tokens, raw_token, hostname, state) do
    Enum.reduce_while(tokens, {:error, :invalid_token}, fn token, acc ->
      case Token.verify(token, raw_token, hostname) do
        :ok ->
          updated = Token.increment_use(token)

          case persist_token(state, updated, :legacy) do
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

  defp reply_host_update(state, prior, updated) do
    case persist_host(state, updated, :control) do
      :ok ->
        hosts = Map.put(state.hosts, updated.id, updated)
        fingerprint_index = Map.put(state.fingerprint_index, updated.key_fingerprint, updated.id)

        {:reply, {:ok, prior, updated},
         %{state | hosts: hosts, fingerprint_index: fingerprint_index}}

      {:error, :persistence_failed} = error ->
        {:reply, error, state}
    end
  end

  defp delete_host_record(state, id) do
    case Map.get(state.hosts, id) do
      nil ->
        {:error, :not_found}

      host ->
        with :ok <- delete_file(host_path(state.data_dir, id), :host, state.file_ops) do
          hosts = Map.delete(state.hosts, id)
          fingerprint_index = Map.delete(state.fingerprint_index, host.key_fingerprint)
          {:ok, host, %{state | hosts: hosts, fingerprint_index: fingerprint_index}}
        end
    end
  end

  defp legacy_delete_host_record(state, id) do
    case Map.get(state.hosts, id) do
      nil ->
        {:error, :not_found}

      host ->
        legacy_delete_file(host_path(state.data_dir, id), :host, state.file_ops)
        hosts = Map.delete(state.hosts, id)
        fingerprint_index = Map.delete(state.fingerprint_index, host.key_fingerprint)
        {:ok, host, %{state | hosts: hosts, fingerprint_index: fingerprint_index}}
    end
  end

  defp legacy_delete_token_record(state, id) do
    case Map.get(state.tokens, id) do
      nil ->
        {:error, :not_found}

      token ->
        legacy_delete_file(token_path(state.data_dir, id), :token, state.file_ops)
        {:ok, token, %{state | tokens: Map.delete(state.tokens, id)}}
    end
  end

  defp legacy_delete_file(path, kind, file_ops) do
    case legacy_file_call(file_ops, :rm, [path]) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete #{kind} file #{path}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.warning(
        "Unexpected error deleting #{kind} file #{path}: #{Exception.message(exception)}"
      )
  catch
    caught_kind, reason ->
      Logger.warning(
        "Unexpected #{caught_kind} deleting #{kind} file #{path}: #{inspect(reason)}"
      )
  end

  defp delete_file(path, kind, file_ops) do
    case file_call(file_ops, :rm, [path]) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, :persistence_failed} ->
        Logger.warning("Failed to delete #{kind} persistence record")
        {:error, :persistence_failed}
    end
  end

  # Persistence helpers

  defp persist_host(state, host, mode) do
    path = host_path(state.data_dir, host.id)
    toml_map = Host.to_toml_map(host)
    atomic_write_toml(path, toml_map, state.file_ops, mode)
  end

  defp persist_token(state, token, mode) do
    path = token_path(state.data_dir, token.id)
    toml_map = Token.to_toml_map(token)
    atomic_write_toml(path, toml_map, state.file_ops, mode)
  end

  defp atomic_write_toml(path, map, file_ops, :legacy) do
    content = encode_toml(map)
    tmp_path = path <> ".tmp"
    dir = Path.dirname(path)

    with :ok <- legacy_file_call(file_ops, :mkdir_p, [dir]),
         :ok <- legacy_file_call(file_ops, :write, [tmp_path, content]),
         {:ok, _parsed} <- legacy_read_and_parse_toml(tmp_path, file_ops),
         :ok <- legacy_file_call(file_ops, :rename, [tmp_path, path]) do
      :ok
    else
      {:error, reason} ->
        _cleanup_result = legacy_file_call(file_ops, :rm, [tmp_path])
        {:error, reason}
    end
  end

  defp atomic_write_toml(path, map, file_ops, :control) do
    tmp_path = path <> ".tmp"
    dir = Path.dirname(path)

    result =
      try do
        content = encode_toml(map)

        with :ok <- file_call(file_ops, :mkdir_p, [dir]),
             :ok <- file_call(file_ops, :write, [tmp_path, content]),
             {:ok, _parsed} <- read_and_parse_toml(tmp_path, file_ops),
             :ok <- file_call(file_ops, :rename, [tmp_path, path]) do
          :ok
        else
          _failure -> {:error, :persistence_failed}
        end
      rescue
        _exception -> {:error, :persistence_failed}
      catch
        _kind, _reason -> {:error, :persistence_failed}
      end

    if result != :ok do
      _cleanup_result = file_call(file_ops, :rm, [tmp_path])
    end

    result
  end

  defp legacy_read_and_parse_toml(path, file_ops) do
    case legacy_file_call(file_ops, :read, [path]) do
      {:ok, content} -> Toml.decode(content)
      error -> error
    end
  end

  defp read_and_parse_toml(path, file_ops) do
    case file_call(file_ops, :read, [path]) do
      {:ok, content} -> Toml.decode(content)
      _failure -> {:error, :persistence_failed}
    end
  end

  defp legacy_file_call({module, context}, operation, arguments),
    do: apply(module, operation, [context | arguments])

  defp legacy_file_call(module, operation, arguments),
    do: apply(module, operation, arguments)

  defp file_call({module, context}, operation, arguments) do
    module
    |> apply(operation, [context | arguments])
    |> normalize_file_result()
  rescue
    _exception -> {:error, :persistence_failed}
  catch
    _kind, _reason -> {:error, :persistence_failed}
  end

  defp file_call(module, operation, arguments) do
    module
    |> apply(operation, arguments)
    |> normalize_file_result()
  rescue
    _exception -> {:error, :persistence_failed}
  catch
    _kind, _reason -> {:error, :persistence_failed}
  end

  defp normalize_file_result(:ok), do: :ok
  defp normalize_file_result({:ok, _value} = result), do: result
  defp normalize_file_result({:error, :enoent}), do: {:error, :enoent}
  defp normalize_file_result(_failure), do: {:error, :persistence_failed}

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

  defp load_hosts(hosts_dir, file_ops) do
    case list_toml_paths(hosts_dir, file_ops) do
      {:ok, paths} ->
        Enum.reduce(paths, {%{}, %{}, :ok}, fn path, {hosts, idx, status} ->
          case load_host_file(path, file_ops) do
            {:ok, host} ->
              {
                Map.put(hosts, host.id, host),
                Map.put(idx, host.key_fingerprint, host.id),
                status
              }

            {:error, :persistence_failed} ->
              {hosts, idx, :persistence_failed}
          end
        end)

      {:error, :persistence_failed} ->
        {%{}, %{}, :persistence_failed}
    end
  end

  defp load_host_file(path, file_ops) do
    try do
      with {:ok, content} <- file_call(file_ops, :read, [path]),
           {:ok, data} <- Toml.decode(content),
           :ok <- validate_persisted_host(data),
           {:ok, %Host{} = host} <- Host.from_toml_map(data) do
        {:ok, host}
      else
        _failure -> {:error, :persistence_failed}
      end
    rescue
      _exception -> {:error, :persistence_failed}
    catch
      _kind, _reason -> {:error, :persistence_failed}
    end
  end

  defp validate_persisted_host(%{"host" => data} = document)
       when map_size(document) == 1 and is_map(data) do
    with :ok <- validate_host_keys(data),
         :ok <- validate_nonempty_text(data["id"], @max_control_id_bytes),
         :ok <- validate_nonempty_text(data["hostname"], @max_control_name_bytes),
         :ok <- validate_nonempty_binary(data["ssh_pubkey"]),
         :ok <- validate_nonempty_binary(data["key_fingerprint"]),
         :ok <- validate_nonempty_binary(data["age_recipient"]),
         true <- data["status"] in @valid_statuses,
         true <- data["trust_level"] in @valid_trust_levels,
         true <- data["trust_provider"] in @valid_trust_providers,
         :ok <- validate_optional_datetime(data, "created_at"),
         :ok <- validate_optional_datetime(data, "approved_at"),
         :ok <- validate_optional_datetime(data, "revoked_at"),
         :ok <- validate_optional_text_fields(data),
         :ok <- validate_optional_map(data, "trust_evidence"),
         :ok <- validate_optional_map(data, "metadata"),
         :ok <- validate_previous_keys(data) do
      :ok
    else
      _failure -> {:error, :persistence_failed}
    end
  end

  defp validate_persisted_host(_data), do: {:error, :persistence_failed}

  defp validate_host_keys(data) do
    keys = Map.keys(data)
    allowed_keys = @required_host_keys ++ @optional_host_keys

    if Enum.all?(@required_host_keys, &Map.has_key?(data, &1)) and
         Enum.all?(keys, &(&1 in allowed_keys)) do
      :ok
    else
      {:error, :persistence_failed}
    end
  end

  defp validate_bounded_text(value, maximum)
       when is_binary(value) and byte_size(value) <= maximum do
    if String.valid?(value), do: :ok, else: {:error, :persistence_failed}
  end

  defp validate_bounded_text(_value, _maximum), do: {:error, :persistence_failed}

  defp validate_nonempty_text(value, maximum) do
    with :ok <- validate_bounded_text(value, maximum),
         false <- value == "" do
      :ok
    else
      _failure -> {:error, :persistence_failed}
    end
  end

  defp validate_nonempty_binary(value) when is_binary(value) and value != "", do: :ok
  defp validate_nonempty_binary(_value), do: {:error, :persistence_failed}

  defp validate_optional_datetime(data, key) do
    case Map.fetch(data, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} -> :ok
          _failure -> {:error, :persistence_failed}
        end

      {:ok, _value} ->
        {:error, :persistence_failed}
    end
  end

  defp validate_optional_text_fields(data) do
    fields = ~w(machine_id role datacenter approved_by revoked_by revoke_reason)

    if Enum.all?(fields, fn field ->
         case Map.fetch(data, field) do
           :error -> true
           {:ok, value} -> is_binary(value) and String.valid?(value)
         end
       end) do
      :ok
    else
      {:error, :persistence_failed}
    end
  end

  defp validate_optional_map(data, key) do
    case Map.fetch(data, key) do
      :error -> :ok
      {:ok, value} when is_map(value) and map_size(value) <= @max_persisted_collection_size -> :ok
      {:ok, _value} -> {:error, :persistence_failed}
    end
  end

  defp validate_previous_keys(data) do
    case Map.fetch(data, "previous_keys") do
      :error ->
        :ok

      {:ok, value} when is_list(value) ->
        if length(value) <= @max_persisted_collection_size and Enum.all?(value, &is_map/1),
          do: :ok,
          else: {:error, :persistence_failed}

      {:ok, _value} ->
        {:error, :persistence_failed}
    end
  end

  defp load_tokens(tokens_dir, file_ops) do
    case list_toml_paths(tokens_dir, file_ops) do
      {:ok, paths} ->
        Enum.reduce(paths, %{}, fn path, tokens ->
          case load_token_file(path, file_ops) do
            {:ok, token} -> Map.put(tokens, token.id, token)
            {:error, :persistence_failed} -> tokens
          end
        end)

      {:error, :persistence_failed} ->
        %{}
    end
  end

  defp load_token_file(path, file_ops) do
    try do
      with {:ok, content} <- file_call(file_ops, :read, [path]),
           {:ok, data} <- Toml.decode(content),
           {:ok, %Token{} = token} <- Token.from_toml_map(data) do
        {:ok, token}
      else
        _failure -> {:error, :persistence_failed}
      end
    rescue
      _exception -> {:error, :persistence_failed}
    catch
      _kind, _reason -> {:error, :persistence_failed}
    end
  end

  defp list_toml_paths(directory, file_ops) do
    try do
      case file_call(file_ops, :ls, [directory]) do
        {:ok, entries} when is_list(entries) ->
          if Enum.all?(entries, &is_binary/1) do
            paths =
              entries
              |> Enum.filter(&String.ends_with?(&1, ".toml"))
              |> Enum.sort()
              |> Enum.map(&Path.join(directory, &1))

            {:ok, paths}
          else
            {:error, :persistence_failed}
          end

        _failure ->
          {:error, :persistence_failed}
      end
    rescue
      _exception -> {:error, :persistence_failed}
    catch
      _kind, _reason -> {:error, :persistence_failed}
    end
  end

  defp write_audit_entry(data_dir, event, host_id, details) do
    audit_path = Path.join(data_dir, "audit.log")
    timestamp = DateTime.to_iso8601(DateTime.utc_now())
    details_str = if details == %{}, do: "", else: " " <> inspect(details)

    entry = "#{timestamp} #{event} host=#{host_id}#{details_str}\n"

    case File.write(audit_path, entry, [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to write audit log entry: #{reason}")
    end
  rescue
    e -> Logger.warning("Unexpected error writing audit log: #{Exception.message(e)}")
  end

  defp read_audit_entries(data_dir, opts, file_ops, mode) do
    audit_path = Path.join(data_dir, "audit.log")

    case file_call(file_ops, :read, [audit_path]) do
      {:ok, content} ->
        parse_audit_entries(content, opts, mode)

      {:error, :enoent} ->
        {:ok, []}

      {:error, :persistence_failed} = error ->
        error
    end
  end

  defp parse_audit_entries(content, opts, mode) do
    try do
      if is_binary(content) and String.valid?(content) do
        limit = Keyword.get(opts, :limit, 100)
        host_filter = Keyword.get(opts, :host_id)
        event_filter = Keyword.get(opts, :event)

        with {:ok, entries} <- parse_audit_lines(content, mode) do
          entries
          |> maybe_filter(:host_id, host_filter)
          |> maybe_filter(:event, event_filter)
          |> take_audit_entries(limit)
        end
      else
        {:error, :persistence_failed}
      end
    rescue
      _exception -> {:error, :persistence_failed}
    catch
      _kind, _reason -> {:error, :persistence_failed}
    end
  end

  defp parse_audit_lines(content, :best_effort) do
    entries =
      content
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.flat_map(fn line ->
        case parse_audit_line(line) do
          nil -> []
          entry -> [entry]
        end
      end)

    {:ok, entries}
  end

  defp parse_audit_lines(content, :strict) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, entries} ->
      case parse_audit_line(line) do
        nil -> {:halt, {:error, :persistence_failed}}
        entry -> {:cont, {:ok, [entry | entries]}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, :persistence_failed} = error -> error
    end
  end

  defp parse_audit_lines(_content, _mode), do: {:error, :persistence_failed}

  defp take_audit_entries(entries, :all), do: {:ok, Enum.to_list(entries)}

  defp take_audit_entries(entries, limit) when is_integer(limit),
    do: {:ok, Enum.take(entries, limit)}

  defp take_audit_entries(_entries, _limit), do: {:error, :persistence_failed}

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
