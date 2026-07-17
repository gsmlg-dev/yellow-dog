defmodule YellowDog.ServerAgent.Supervisor do
  @moduledoc false

  use Supervisor

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Dispatcher
  alias YellowDog.ServerAgent.Heartbeat
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Identity.Server
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Hello

  @durable_options [:data_dir, :server_id, :profile, :capabilities]
  @outbound_options [
    :management_url,
    :management_token,
    :server_name,
    :server_version,
    :config_revision,
    :reconnect_initial_ms,
    :reconnect_max_ms
  ]
  @scrubbed_outbound_options @outbound_options -- [:management_url, :management_token]
  @common_options [
    :name,
    :agent_id,
    :command_journal_name,
    :config_store_name,
    :config_apply_store_name,
    :config_applier_name,
    :client_name,
    :supervisor_name,
    :command_journal_opts,
    :config_store_opts,
    :config_apply_store_opts,
    :config_applier_opts,
    :client_opts
  ]
  @public_options @durable_options ++ @outbound_options ++ @common_options
  @allowed_options @public_options ++ [:credential_ref, :credential_owner]
  @command_journal_options [:max_records, :clock, :directory_scanner, :storage_opts]
  @config_store_options [:max_bytes, :storage_opts]
  @config_apply_store_options [:clock, :max_bytes, :storage_opts]
  @config_applier_options [:runtime_adapter]
  @client_options [
    :dispatcher,
    :dispatcher_runtime_adapter,
    :socket,
    :timer,
    :monotonic_clock,
    :wall_clock,
    :connection_poll_interval,
    :connect_timeout,
    :join_timeout,
    :push_timeout,
    :heartbeat_interval,
    :status_interval
  ]
  @default_client_options [
    dispatcher: Dispatcher,
    dispatcher_runtime_adapter: :"Elixir.YellowDog.Server.Control",
    timer: Client.Timer,
    monotonic_clock: Client.MonotonicClock,
    wall_clock: Client.WallClock,
    connection_poll_interval: 100,
    connect_timeout: 10_000,
    join_timeout: 5_000,
    push_timeout: 5_000,
    heartbeat_interval: 30_000,
    status_interval: 30_000
  ]
  @heartbeat_only_options [:name, :agent_id, :supervisor_name]
  @restart_cleanup_timeout 1_000

  def child_spec(opts) do
    case local_child_spec_options(opts) do
      {:ok, local_opts} ->
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [local_opts]},
          type: :supervisor
        }

      {:error, :invalid_configuration} ->
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_invalid, []},
          type: :supervisor
        }
    end
  end

  def start_link(opts \\ []) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         {:ok, supervisor_name} <-
           supervisor_name(Keyword.get(opts, :supervisor_name, __MODULE__)),
         {:ok, prepared_opts} <- prepare_options(opts) do
      result =
        if Keyword.has_key?(prepared_opts, :credential_ref) do
          start_supervisor({:claim_credentials, prepared_opts}, supervisor_name)
        else
          start_supervisor(prepared_opts, supervisor_name)
        end

      cleanup_failed_start(result, prepared_opts)
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @doc false
  def local_child_spec_options(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         :ok <- validate_public_top_level(opts),
         {:ok, false} <- outbound_mode(opts),
         {:ok, _children} <- children(opts) do
      {:ok, opts}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @doc false
  def start_prepared_child_link(prepared_opts)
      when is_list(prepared_opts) do
    if Keyword.keyword?(prepared_opts) do
      start_prepared_child(prepared_opts)
    else
      {:error, :invalid_configuration}
    end
  end

  def start_prepared_child_link(_prepared_opts), do: {:error, :invalid_configuration}

  @doc false
  def start_invalid, do: {:error, :invalid_configuration}

  @doc false
  def prepare_options(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         :ok <- validate_public_top_level(opts),
         {:ok, _children} <- children(opts) do
      prepare_outbound_options(opts)
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @doc false
  def start_prepared_link(opts, owner) when is_pid(owner) and owner == self() do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         false <- raw_credentials?(opts),
         prepared_opts = put_credential_owner(opts, owner),
         :ok <- await_child_names(prepared_opts),
         {:ok, _children} <- children(prepared_opts),
         {:ok, supervisor_name} <-
           supervisor_name(Keyword.get(prepared_opts, :supervisor_name, __MODULE__)) do
      start_supervisor({:owned_credentials, prepared_opts}, supervisor_name)
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  def start_prepared_link(_opts, _owner), do: {:error, :invalid_configuration}

  defp start_prepared_child(prepared_opts) do
    case Keyword.fetch(prepared_opts, :credential_ref) do
      {:ok, credential_ref} ->
        with :ok <- Client.claim_credentials(credential_ref) do
          result = start_prepared_link(prepared_opts, self())
          cleanup_failed_start(result, prepared_opts)
        else
          _invalid -> {:error, :invalid_configuration}
        end

      :error ->
        start_prepared_link(prepared_opts, self())
    end
  end

  defp put_credential_owner(opts, owner) do
    if Keyword.has_key?(opts, :credential_ref),
      do: Keyword.put(opts, :credential_owner, owner),
      else: opts
  end

  defp await_child_names(opts) do
    deadline = System.monotonic_time(:millisecond) + @restart_cleanup_timeout
    await_child_names(configured_child_names(opts), deadline)
  end

  defp await_child_names(names, deadline) do
    if Enum.all?(names, &(GenServer.whereis(&1) == nil)) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        await_child_names(names, deadline)
      else
        {:error, :invalid_configuration}
      end
    end
  end

  defp configured_child_names(opts) do
    durable_names =
      if Enum.all?(@durable_options, &Keyword.has_key?(opts, &1)) do
        [
          Keyword.get(opts, :name, Heartbeat),
          Keyword.get(opts, :command_journal_name, CommandJournal),
          Keyword.get(opts, :config_store_name, ConfigStore),
          Keyword.get(opts, :config_apply_store_name, ConfigApplyStore),
          Keyword.get(opts, :config_applier_name, ConfigApplier)
        ]
      else
        [Keyword.get(opts, :name, Heartbeat)]
      end

    if Keyword.has_key?(opts, :credential_ref),
      do: durable_names ++ [Keyword.get(opts, :client_name, Client)],
      else: durable_names
  end

  @impl Supervisor
  def init({:claim_credentials, opts}) do
    with {:ok, credential_ref} <- Keyword.fetch(opts, :credential_ref),
         :ok <- Client.claim_credentials(credential_ref) do
      opts
      |> Keyword.put(:credential_owner, self())
      |> init_children()
    else
      _invalid -> :ignore
    end
  end

  def init({:owned_credentials, opts}), do: init_children(opts)

  def init(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case outbound_mode(opts) do
        {:ok, :raw} -> :ignore
        _other -> init_children(opts)
      end
    else
      :ignore
    end
  end

  def init(_opts), do: :ignore

  defp init_children(opts) do
    case children(opts) do
      {:ok, children} -> Supervisor.init(children, strategy: :one_for_one)
      {:error, :invalid_configuration} -> :ignore
    end
  end

  defp children(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_top_level(opts),
         {:ok, durable?} <- durable_mode(opts),
         {:ok, outbound?} <- outbound_mode(opts),
         {:ok, journal_opts} <-
           child_options(Keyword.get(opts, :command_journal_opts, []), @command_journal_options),
         {:ok, store_opts} <-
           child_options(Keyword.get(opts, :config_store_opts, []), @config_store_options),
         {:ok, apply_store_opts} <-
           child_options(
             Keyword.get(opts, :config_apply_store_opts, []),
             @config_apply_store_options
           ),
         {:ok, applier_opts} <-
           child_options(Keyword.get(opts, :config_applier_opts, []), @config_applier_options),
         {:ok, client_opts} <-
           child_options(Keyword.get(opts, :client_opts, []), @client_options) do
      build_children(
        opts,
        durable?,
        outbound?,
        journal_opts,
        store_opts,
        apply_store_opts,
        applier_opts,
        client_opts
      )
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp children(_opts), do: {:error, :invalid_configuration}

  defp build_children(
         opts,
         false,
         false,
         _journal_opts,
         _store_opts,
         _apply_store_opts,
         _applier_opts,
         _client_opts
       ) do
    heartbeat_opts = Keyword.take(opts, [:name, :agent_id])
    heartbeat_name = Keyword.get(heartbeat_opts, :name, Heartbeat)

    if heartbeat_only_options?(opts) and valid_name?(heartbeat_name) do
      {:ok, [child_spec(:heartbeat, Heartbeat, heartbeat_opts)]}
    else
      {:error, :invalid_configuration}
    end
  end

  defp build_children(
         opts,
         true,
         outbound_mode,
         journal_opts,
         store_opts,
         apply_store_opts,
         applier_opts,
         client_opts
       ) do
    outbound? = outbound_mode != false
    journal_name = Keyword.get(opts, :command_journal_name, CommandJournal)
    store_name = Keyword.get(opts, :config_store_name, ConfigStore)
    apply_store_name = Keyword.get(opts, :config_apply_store_name, ConfigApplyStore)
    applier_name = Keyword.get(opts, :config_applier_name, ConfigApplier)
    client_name = Keyword.get(opts, :client_name, Client)
    heartbeat_name = Keyword.get(opts, :name, Heartbeat)
    server_id = Keyword.fetch!(opts, :server_id)
    agent_id = Keyword.get(opts, :agent_id, server_id)

    child_names =
      [heartbeat_name, journal_name, store_name, apply_store_name, applier_name] ++
        if(outbound?, do: [client_name], else: [])

    with true <- valid_name?(heartbeat_name),
         true <- valid_name?(journal_name),
         true <- valid_name?(store_name),
         true <- valid_name?(apply_store_name),
         true <- valid_name?(applier_name),
         true <- not outbound? or valid_name?(client_name),
         true <- distinct_names?(child_names),
         true <- agent_id == server_id,
         {:ok, outbound_config} <- outbound_configuration(opts, outbound_mode) do
      shared = Keyword.take(opts, @durable_options)
      data_dir = Keyword.fetch!(shared, :data_dir)
      profile = Keyword.fetch!(shared, :profile)
      capabilities = Keyword.fetch!(shared, :capabilities)

      heartbeat_opts = [
        name: heartbeat_name,
        agent_id: server_id,
        connection_state: if(outbound?, do: :connecting, else: :disabled)
      ]

      journal_opts =
        journal_opts
        |> Keyword.put(:name, journal_name)
        |> Keyword.put(:data_dir, data_dir)
        |> Keyword.put(:server_id, server_id)
        |> Keyword.put(:capabilities, capabilities)

      store_opts =
        store_opts
        |> Keyword.put(:name, store_name)
        |> Keyword.put(:data_dir, data_dir)
        |> Keyword.put(:server_id, server_id)
        |> Keyword.put(:profile, profile)

      apply_store_opts =
        apply_store_opts
        |> Keyword.put(:name, apply_store_name)
        |> Keyword.put(:data_dir, data_dir)
        |> Keyword.put(:server_id, server_id)
        |> Keyword.put(:profile, profile)
        |> Keyword.put(:config_store, store_name)

      applier_opts =
        applier_opts
        |> Keyword.put(:name, applier_name)
        |> Keyword.put(:server_id, server_id)
        |> Keyword.put(:profile, profile)
        |> Keyword.put(:config_store, store_name)
        |> Keyword.put(:config_apply_store, apply_store_name)

      local_children = [
        child_spec(:heartbeat, Heartbeat, heartbeat_opts),
        child_spec(:command_journal, CommandJournal, journal_opts),
        child_spec(:config_store, ConfigStore, store_opts),
        child_spec(:config_apply_store, ConfigApplyStore, apply_store_opts),
        child_spec(:config_applier, ConfigApplier, applier_opts)
      ]

      {:ok,
       maybe_add_client(
         local_children,
         outbound_config,
         client_opts,
         client_name,
         journal_name,
         apply_store_name,
         applier_name
       )}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp build_children(
         _opts,
         _durable?,
         _outbound?,
         _journal_opts,
         _store_opts,
         _apply_store_opts,
         _applier_opts,
         _client_opts
       ),
       do: {:error, :invalid_configuration}

  defp maybe_add_client(
         children,
         nil,
         _client_opts,
         _client_name,
         _journal,
         _apply_store,
         _applier
       ),
       do: children

  defp maybe_add_client(
         children,
         %{credential_ref: credential_ref, credential_owner: credential_owner} = outbound,
         client_opts,
         client_name,
         journal_name,
         apply_store_name,
         applier_name
       ) do
    client_opts =
      @default_client_options
      |> Keyword.merge(client_opts)
      |> Keyword.merge(
        enabled: true,
        name: client_name,
        credential_ref: credential_ref,
        credential_owner: credential_owner,
        identity: outbound.identity,
        command_journal: journal_name,
        config_applier: applier_name,
        config_apply_store: apply_store_name,
        initial_backoff: outbound.initial_backoff,
        max_backoff: outbound.max_backoff
      )

    children ++ [child_spec(:client, Client, client_opts)]
  end

  defp maybe_add_client(
         children,
         %{mode: :raw},
         _client_opts,
         client_name,
         _journal_name,
         _apply_store_name,
         _applier_name
       ) do
    children ++ [child_spec(:client, Client, enabled: false, name: client_name)]
  end

  defp validate_top_level(opts) do
    keys = Keyword.keys(opts)

    if Enum.all?(keys, &(&1 in @allowed_options)) and
         length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :invalid_configuration}
    end
  end

  defp validate_public_top_level(opts) do
    keys = Keyword.keys(opts)

    if Enum.all?(keys, &(&1 in @public_options)) and
         length(keys) == length(Enum.uniq(keys)) do
      :ok
    else
      {:error, :invalid_configuration}
    end
  end

  defp heartbeat_only_options?(opts) do
    Enum.all?(Keyword.keys(opts), &(&1 in @heartbeat_only_options))
  end

  defp durable_mode(opts) do
    present = Enum.count(@durable_options, &Keyword.has_key?(opts, &1))

    case present do
      0 -> {:ok, false}
      4 -> {:ok, true}
      _partial -> {:error, :invalid_configuration}
    end
  end

  defp outbound_mode(opts) do
    raw_present = Enum.count(@outbound_options, &Keyword.has_key?(opts, &1))
    scrubbed_present = Enum.count(@scrubbed_outbound_options, &Keyword.has_key?(opts, &1))
    credential_ref? = Keyword.has_key?(opts, :credential_ref)
    credential_owner? = Keyword.has_key?(opts, :credential_owner)
    client_opts = Keyword.get(opts, :client_opts, [])

    cond do
      raw_present == 0 and not credential_ref? and not credential_owner? and client_opts == [] ->
        {:ok, false}

      raw_present == length(@outbound_options) and not credential_ref? and
          not credential_owner? ->
        {:ok, :raw}

      raw_present == scrubbed_present and
        scrubbed_present == length(@scrubbed_outbound_options) and credential_ref? and
          credential_owner? ->
        {:ok, :prepared}

      true ->
        {:error, :invalid_configuration}
    end
  end

  defp outbound_configuration(_opts, false), do: {:ok, nil}

  defp outbound_configuration(opts, :raw) do
    with {:ok, identity} <- server_identity(opts),
         initial when is_integer(initial) and initial > 0 <-
           Keyword.fetch!(opts, :reconnect_initial_ms),
         maximum when is_integer(maximum) and maximum >= initial <-
           Keyword.fetch!(opts, :reconnect_max_ms) do
      {:ok,
       %{
         mode: :raw,
         identity: identity,
         initial_backoff: initial,
         max_backoff: maximum
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp outbound_configuration(opts, :prepared) do
    with {:ok, identity} <- server_identity(opts),
         {:ok, credential_ref} <- credential_ref(Keyword.fetch!(opts, :credential_ref)),
         credential_owner when is_pid(credential_owner) <-
           Keyword.fetch!(opts, :credential_owner),
         {:ok, _client_opts} <-
           child_options(
             Keyword.get(opts, :client_opts, []),
             @client_options -- [:socket]
           ),
         initial when is_integer(initial) and initial > 0 <-
           Keyword.fetch!(opts, :reconnect_initial_ms),
         maximum when is_integer(maximum) and maximum >= initial <-
           Keyword.fetch!(opts, :reconnect_max_ms) do
      {:ok,
       %{
         credential_ref: credential_ref,
         credential_owner: credential_owner,
         identity: identity,
         initial_backoff: initial,
         max_backoff: maximum
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp prepare_outbound_options(opts) do
    case outbound_mode(opts) do
      {:ok, false} ->
        {:ok, opts}

      {:ok, :raw} ->
        client_opts = Keyword.get(opts, :client_opts, [])
        socket = Keyword.get(client_opts, :socket, Client.Socket)

        credential_opts = [
          management_url: Keyword.fetch!(opts, :management_url),
          token: Keyword.fetch!(opts, :management_token),
          server_id: Keyword.fetch!(opts, :server_id),
          socket: socket
        ]

        case Client.prepare_credentials(credential_opts) do
          {:ok, credential_ref} ->
            prepared_opts =
              opts
              |> Keyword.delete(:management_url)
              |> Keyword.delete(:management_token)
              |> Keyword.update(:client_opts, [], &Keyword.delete(&1, :socket))
              |> Keyword.put(:credential_ref, credential_ref)

            {:ok, prepared_opts}

          {:error, :invalid_options} ->
            {:error, :invalid_configuration}
        end

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp cleanup_failed_start({:ok, _supervisor} = result, _opts), do: result

  defp cleanup_failed_start(result, opts) do
    case Keyword.fetch(opts, :credential_ref) do
      {:ok, credential_ref} -> Client.release_credentials(credential_ref)
      :error -> :ok
    end

    case result do
      :ignore -> {:error, :invalid_configuration}
      other -> other
    end
  end

  defp raw_credentials?(opts) do
    Keyword.has_key?(opts, :management_url) or
      Keyword.has_key?(opts, :management_token) or
      opts
      |> Keyword.get(:client_opts, [])
      |> Keyword.has_key?(:socket)
  end

  defp credential_ref({provider, capability} = credential_ref)
       when is_pid(provider) and is_reference(capability) do
    if Process.alive?(provider), do: {:ok, credential_ref}, else: :error
  end

  defp credential_ref(_value), do: :error

  defp server_identity(opts) do
    with {:ok, server_id} <- server_id(Keyword.fetch!(opts, :server_id)),
         {:ok, name} <- nonempty_message(Keyword.fetch!(opts, :server_name)),
         {:ok, version} <- nonempty_message(Keyword.fetch!(opts, :server_version)),
         {:ok, profile} <- profile(Keyword.fetch!(opts, :profile)),
         {:ok, capabilities} <- capabilities(Keyword.fetch!(opts, :capabilities)),
         {:ok, revision} <- Digest.validate(Keyword.fetch!(opts, :config_revision)),
         identity = %Server{
           id: server_id,
           name: name,
           version: version,
           profile: profile,
           capabilities: capabilities,
           config_revision: revision
         },
         message = %Hello{identity: identity},
         {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded) do
      {:ok, identity}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp server_id(value) do
    with {:ok, value} <- nonempty_id(value),
         true <- value not in [".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp profile(value) when is_atom(value), do: profile(Atom.to_string(value))
  defp profile(value), do: nonempty_message(value)

  defp capabilities(values) do
    with {:ok, values} <- Bounds.list(values),
         true <- Enum.all?(values, &match?({:ok, _value}, nonempty_message(&1))),
         true <- length(values) == length(Enum.uniq(values)) do
      {:ok, values}
    else
      _invalid -> :error
    end
  end

  defp nonempty_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp nonempty_message(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp child_options(opts, allowed) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in allowed)),
         true <- length(keys) == length(Enum.uniq(keys)) do
      {:ok, opts}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp valid_name?(name) when is_atom(name), do: not is_nil(name)
  defp valid_name?({:global, _term}), do: true

  defp valid_name?({:via, module, _term}) when is_atom(module) and not is_nil(module),
    do: true

  defp valid_name?(_name), do: false

  defp distinct_names?(names), do: length(names) == length(Enum.uniq(names))

  defp supervisor_name(nil), do: {:ok, nil}
  defp supervisor_name(name), do: if(valid_name?(name), do: {:ok, name}, else: :error)

  defp child_spec(id, module, opts) do
    Supervisor.child_spec({module, opts}, id: id)
  end

  defp start_supervisor(opts, nil),
    do: Supervisor.start_link(__MODULE__, opts)

  defp start_supervisor(opts, name),
    do: Supervisor.start_link(__MODULE__, opts, name: name)
end
