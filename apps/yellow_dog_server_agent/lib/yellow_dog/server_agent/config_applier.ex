defmodule YellowDog.ServerAgent.ConfigApplier do
  @moduledoc """
  Serialized durable Server configuration application and rollback sequencing.
  """

  use GenServer

  import Kernel, except: [apply: 2]

  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.ConfigState

  @default_runtime_adapter :"Elixir.YellowDog.Server.Control"
  @max_publications 3
  @max_version 9_223_372_036_854_775_807
  @allowed_options [
    :name,
    :server_id,
    :profile,
    :config_store,
    :config_apply_store,
    :runtime_adapter
  ]
  @adapter_callbacks [
    validate_config: 1,
    install_config: 2,
    activate_config: 1,
    restore_config: 1
  ]
  @side_effect_checkpoints [
    :before_install,
    :before_activate,
    :before_restore,
    :before_reactivate
  ]
  @transition_contracts %{
    delivered: {:delivered, :staged, :stable},
    before_validate: {:delivered, :before_validate, :stable},
    validation_failed: {:failed, :complete, :stable},
    before_install: {:applying, :before_install, :stable},
    before_activate: {:applying, :before_activate, :stable},
    apply_failed: {:failed, :complete, :unknown},
    before_restore: {:applying, :before_restore, :unknown},
    before_reactivate: {:applying, :before_reactivate, :unknown},
    rollback_succeeded: {:failed, :complete, :known},
    rollback_failed: {:failed, :complete, :unknown},
    applied: {:applied, :complete, :known},
    uncertain_after_side_effect: {:applying, :unknown, :unknown}
  }
  @init_applying_runtime %{
    before_install: :stable,
    before_activate: :stable,
    before_restore: :unknown,
    before_reactivate: :unknown,
    unknown: :unknown
  }
  @publication_keys [:encoded_message, :message, :sequence]
  @error_messages %{
    not_connected: "not connected",
    not_found: "resource not found",
    invalid: "invalid value",
    conflict: "operation conflict",
    unsupported: "unsupported operation",
    timeout: "operation timed out",
    apply_failed: "apply failed",
    rollback_failed: "rollback failed",
    internal: "internal error"
  }

  @type server :: GenServer.server()
  @type publication :: ConfigApplyStore.publication()
  @type result :: %{
          status: :applied | :failed | :replay,
          publications: [publication()]
        }
  @type state :: %{
          server_id: String.t(),
          profile: String.t(),
          config_store: server(),
          config_apply_store: server(),
          runtime_adapter: module()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config, name} <- validate_options(opts) do
      case name do
        nil -> GenServer.start_link(__MODULE__, config)
        name -> GenServer.start_link(__MODULE__, config, name: name)
      end
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec apply(Envelope.t(), server()) :: {:ok, result()} | {:error, Error.t()}
  def apply(envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:apply, envelope}, :infinity)

  @impl true
  def init(config) do
    ownership_key = {__MODULE__, :server_id, config.server_id}

    case claim_ownership(ownership_key) do
      :ok ->
        config = Map.put(config, :ownership_key, ownership_key)

        case recover_uncertain_side_effect(config) do
          :ok ->
            {:ok, config}

          {:error, phase} ->
            release_ownership(ownership_key)
            {:stop, {:config_applier_recovery_failed, phase}}
        end

      {:error, :already_started} ->
        {:stop, :config_applier_already_started}

      {:error, :registration} ->
        {:stop, :config_applier_ownership_failed}
    end
  end

  @impl true
  def terminate(_reason, %{ownership_key: ownership_key}) do
    release_ownership(ownership_key)
    :ok
  end

  @impl true
  def handle_call({:apply, envelope}, _from, state) do
    case apply_envelope(envelope, state) do
      {:fail_stop, reason, reply} -> {:stop, reason, reply, state}
      reply -> {:reply, reply, state}
    end
  end

  defp apply_envelope(envelope, config) do
    case preflight(envelope, config) do
      {:admit, :new} ->
        with {:ok, candidate} <- stage_exact(envelope, config),
             {:ok, _snapshot} <-
               transition(:delivered, %{candidate: candidate}, config) do
          validate_and_apply(envelope, :staged, config)
        end

      {:resume, checkpoint} when checkpoint in [:staged, :before_validate] ->
        with {:ok, _candidate} <- stage_exact(envelope, config) do
          validate_and_apply(envelope, checkpoint, config)
        end

      {:replay, _snapshot} ->
        result(:replay, config)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp validate_and_apply(envelope, :staged, config) do
    case transition(:before_validate, %{version: envelope.config_version}, config) do
      {:ok, _snapshot} -> validate_and_apply(envelope, :before_validate, config)
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_and_apply(envelope, :before_validate, config) do
    cond do
      not adapter_available?(config.runtime_adapter) ->
        validation_failed(envelope, "runtime adapter unavailable", config)

      callback(config.runtime_adapter, :validate_config, [envelope.payload]) == :ok ->
        begin_install(envelope, config)

      true ->
        validation_failed(envelope, "runtime config validation failed", config)
    end
  end

  defp validation_failed(envelope, reason, config) do
    case transition(
           :validation_failed,
           %{version: envelope.config_version, reason: reason},
           config
         ) do
      {:ok, _snapshot} -> result(:failed, config)
      {:error, %Error{}} = error -> error
    end
  end

  defp begin_install(envelope, config) do
    case transition(:before_install, %{version: envelope.config_version}, config) do
      {:ok, snapshot} ->
        install(envelope, snapshot.attempt.previous, config)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp install(envelope, previous, config) do
    opts = [
      version: envelope.config_version,
      digest: envelope.payload_digest,
      expected_revision: envelope.expected_revision,
      operation: envelope.operation,
      profile: config.profile
    ]

    case callback(config.runtime_adapter, :install_config, [envelope.payload, opts]) do
      {:ok, revision} ->
        case Digest.validate(revision) do
          {:ok, revision} ->
            before_activate(envelope, revision, previous, config)

          {:error, %Error{}} ->
            recover_candidate(envelope, previous, "config install failed", config)
        end

      _error_or_malformed ->
        recover_candidate(envelope, previous, "config install failed", config)
    end
  end

  defp before_activate(envelope, revision, previous, config) do
    attrs = %{version: envelope.config_version, installed_revision: revision}

    case transition_after_side_effect(:before_activate, attrs, envelope.config_version, config) do
      {:ok, _snapshot} ->
        activate_candidate(envelope, revision, previous, config)

      error_or_stop ->
        error_or_stop
    end
  end

  defp activate_candidate(envelope, revision, previous, config) do
    case callback(config.runtime_adapter, :activate_config, [revision]) do
      :ok ->
        case transition_after_side_effect(
               :applied,
               %{version: envelope.config_version},
               envelope.config_version,
               config
             ) do
          {:ok, _snapshot} -> result(:applied, config)
          error_or_stop -> error_or_stop
        end

      _error_or_malformed ->
        recover_candidate(envelope, previous, "config activation failed", config)
    end
  end

  defp recover_candidate(envelope, nil, reason, config) do
    case transition_after_side_effect(
           :apply_failed,
           %{version: envelope.config_version, reason: reason},
           envelope.config_version,
           config
         ) do
      {:ok, _snapshot} -> result(:failed, config)
      error_or_stop -> error_or_stop
    end
  end

  defp recover_candidate(envelope, previous, reason, config) do
    attrs = %{version: envelope.config_version, trigger_reason: reason}

    case transition_after_side_effect(
           :before_restore,
           attrs,
           envelope.config_version,
           config
         ) do
      {:ok, _snapshot} -> restore_previous(envelope, previous, config)
      error_or_stop -> error_or_stop
    end
  end

  defp restore_previous(envelope, previous, config) do
    case callback(config.runtime_adapter, :restore_config, [previous.revision]) do
      :ok ->
        before_reactivate(envelope, previous, config)

      _error_or_malformed ->
        rollback_failed(envelope, "config restore failed", config)
    end
  end

  defp before_reactivate(envelope, previous, config) do
    case transition_after_side_effect(
           :before_reactivate,
           %{version: envelope.config_version},
           envelope.config_version,
           config
         ) do
      {:ok, _snapshot} -> reactivate_previous(envelope, previous, config)
      error_or_stop -> error_or_stop
    end
  end

  defp reactivate_previous(envelope, previous, config) do
    case callback(config.runtime_adapter, :activate_config, [previous.revision]) do
      :ok ->
        case transition_after_side_effect(
               :rollback_succeeded,
               %{version: envelope.config_version},
               envelope.config_version,
               config
             ) do
          {:ok, _snapshot} -> result(:failed, config)
          error_or_stop -> error_or_stop
        end

      _error_or_malformed ->
        rollback_failed(envelope, "config reactivation failed", config)
    end
  end

  defp rollback_failed(envelope, reason, config) do
    attrs = %{version: envelope.config_version, reason: reason}

    case transition_after_side_effect(
           :rollback_failed,
           attrs,
           envelope.config_version,
           config
         ) do
      {:ok, _snapshot} -> result(:failed, config)
      error_or_stop -> error_or_stop
    end
  end

  defp transition_after_side_effect(event, attrs, version, config) do
    case transition(event, attrs, config) do
      {:ok, _snapshot} = success -> success
      {:error, %Error{}} -> latch_unknown(version, config)
    end
  end

  defp latch_unknown(version, config) do
    case transition(:uncertain_after_side_effect, %{version: version}, config) do
      {:ok, %{runtime_status: :unknown, attempt: %{checkpoint: :unknown}}} ->
        internal()

      _not_durable ->
        {:fail_stop, {:config_applier_inconsistent_persistence, :uncertain_after_side_effect},
         internal()}
    end
  end

  defp stage_exact(envelope, config) do
    case local_call(fn -> ConfigStore.stage(envelope, config.config_store) end) do
      {:ok, candidate} when is_map(candidate) ->
        case local_call(fn -> ConfigStore.current(config.config_store) end) do
          {:ok, ^candidate} -> {:ok, candidate}
          {:error, %Error{}} = error -> error
          _mismatch_or_malformed -> internal()
        end

      {:error, %Error{}} = error ->
        error

      _malformed ->
        internal()
    end
  end

  defp preflight(envelope, config) do
    case local_call(fn ->
           ConfigApplyStore.preflight(envelope, config.config_apply_store)
         end) do
      {:admit, :new} = admitted -> admitted
      {:resume, checkpoint} = resume when checkpoint in [:staged, :before_validate] -> resume
      {:replay, snapshot} -> validate_replay_snapshot(snapshot, envelope, config)
      {:error, %Error{}} = error -> error
      _malformed -> internal()
    end
  end

  defp transition(event, attrs, config) do
    case local_call(fn ->
           ConfigApplyStore.transition(event, attrs, config.config_apply_store)
         end) do
      {:ok, snapshot} -> validate_transition_snapshot(snapshot, event, attrs, config)
      {:error, %Error{}} = error -> error
      _malformed -> internal()
    end
  end

  defp result(status, config) do
    case local_call(fn ->
           ConfigApplyStore.pending_publications(config.config_apply_store)
         end) do
      {:ok, publications} ->
        case validate_publications(publications, config.server_id) do
          {:ok, publications} ->
            {:ok, %{status: status, publications: publications}}

          {:error, %Error{}} = error ->
            error
        end

      {:error, %Error{}} = error ->
        error

      _malformed ->
        internal()
    end
  end

  defp recover_uncertain_side_effect(config) do
    case local_call(fn ->
           ConfigApplyStore.snapshot(config.config_apply_store)
         end) do
      {:ok, snapshot} ->
        case validate_init_snapshot(snapshot, config) do
          {:ok, %{attempt: %{status: :applying, checkpoint: checkpoint, version: version}}}
          when checkpoint in @side_effect_checkpoints ->
            recover_uncertain_transition(version, config)

          {:ok, _snapshot} ->
            :ok

          {:error, %Error{}} ->
            {:error, :state}
        end

      _invalid_or_unavailable ->
        {:error, :state}
    end
  end

  defp recover_uncertain_transition(version, config) do
    case transition(:uncertain_after_side_effect, %{version: version}, config) do
      {:ok, %{runtime_status: :unknown, attempt: %{checkpoint: :unknown}}} -> :ok
      _not_durable -> {:error, :persistence}
    end
  end

  defp validate_init_snapshot(snapshot, config) do
    validate_snapshot(snapshot, config, fn
      %{attempt: nil, runtime_status: :unconfigured, known_good: nil} ->
        true

      %{attempt: %{version: version, status: :delivered, checkpoint: checkpoint}} = snapshot ->
        version?(version) and checkpoint in [:staged, :before_validate] and
          runtime?(snapshot, :stable)

      %{attempt: %{version: version, status: :applying, checkpoint: checkpoint}} = snapshot ->
        version?(version) and init_applying_state?(checkpoint, snapshot)

      %{attempt: %{version: version, status: :applied, checkpoint: :complete}} = snapshot ->
        version?(version) and runtime?(snapshot, :known)

      %{attempt: %{version: version, status: :failed, checkpoint: :complete}} = snapshot ->
        version?(version) and runtime?(snapshot, :terminal)

      _invalid ->
        false
    end)
  end

  defp init_applying_state?(checkpoint, snapshot) do
    case @init_applying_runtime[checkpoint] do
      nil -> false
      runtime -> runtime?(snapshot, runtime)
    end
  end

  defp validate_replay_snapshot(snapshot, envelope, config) do
    case validate_snapshot(snapshot, config, fn snapshot ->
           replay_snapshot?(snapshot, envelope, config)
         end) do
      {:ok, snapshot} -> {:replay, snapshot}
      {:error, %Error{}} = error -> error
    end
  end

  defp replay_snapshot?(
         %{attempt: attempt} = snapshot,
         %Envelope{} = envelope,
         config
       )
       when is_map(attempt) do
    same_candidate =
      attempt.version == envelope.config_version and
        attempt.digest == envelope.payload_digest and
        attempt.operation == envelope.operation and
        attempt.profile == config.profile and
        attempt.expected_revision == envelope.expected_revision

    replayable =
      case {attempt.status, attempt.checkpoint} do
        {:applying, :unknown} -> runtime?(snapshot, :unknown)
        {:applied, :complete} -> runtime?(snapshot, :known)
        {:failed, :complete} -> runtime?(snapshot, :terminal)
        _other -> false
      end

    same_candidate and replayable
  end

  defp replay_snapshot?(_snapshot, _envelope, _config), do: false

  defp validate_transition_snapshot(snapshot, event, attrs, config) do
    validate_snapshot(snapshot, config, fn snapshot ->
      with {:ok, {version, status, checkpoint, runtime}} <- transition_state(event, attrs),
           true <- attempt_at?(snapshot, version, status, checkpoint),
           true <- runtime?(snapshot, runtime) do
        transition_fields?(event, attrs, snapshot)
      else
        _invalid -> false
      end
    end)
  end

  defp transition_state(event, attrs) do
    with {status, checkpoint, runtime} <- @transition_contracts[event],
         {:ok, version} <- transition_version(event, attrs) do
      {:ok, {version, status, checkpoint, runtime}}
    else
      _invalid -> :error
    end
  end

  defp transition_version(:delivered, %{candidate: %{"version" => version}}),
    do: {:ok, version}

  defp transition_version(:delivered, _attrs), do: :error
  defp transition_version(_event, %{version: version}), do: {:ok, version}
  defp transition_version(_event, _attrs), do: :error

  defp transition_fields?(
         :before_install,
         _attrs,
         %{known_good: known_good, attempt: %{previous: previous}}
       ),
       do: previous == known_good and known_good_or_nil?(previous)

  defp transition_fields?(
         :before_activate,
         %{installed_revision: revision},
         %{attempt: %{installed_revision: revision}}
       ),
       do: true

  defp transition_fields?(
         :applied,
         %{version: version},
         %{
           runtime_status: :known,
           known_good: known_good,
           attempt: %{digest: digest, installed_revision: revision}
         }
       ),
       do:
         known_good?(known_good) and
           known_good == %{version: version, digest: digest, revision: revision}

  defp transition_fields?(event, _attrs, _snapshot)
       when event in [:before_install, :before_activate, :applied],
       do: false

  defp transition_fields?(event, _attrs, _snapshot),
    do: Map.has_key?(@transition_contracts, event)

  defp attempt_at?(
         %{attempt: %{version: version, status: status, checkpoint: checkpoint}},
         version,
         status,
         checkpoint
       ),
       do: true

  defp attempt_at?(_snapshot, _version, _status, _checkpoint), do: false

  defp validate_snapshot(snapshot, config, predicate) do
    if target_snapshot?(snapshot, config.server_id) and predicate.(snapshot),
      do: {:ok, snapshot},
      else: internal()
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp target_snapshot?(
         %{target_type: :server, target_id: server_id, attempt: _attempt},
         server_id
       ),
       do: true

  defp target_snapshot?(_snapshot, _server_id), do: false

  defp runtime?(%{runtime_status: :unconfigured, known_good: nil}, runtime)
       when runtime in [:stable, :terminal],
       do: true

  defp runtime?(%{runtime_status: :known, known_good: known_good}, runtime)
       when runtime in [:stable, :known, :terminal],
       do: known_good?(known_good)

  defp runtime?(%{runtime_status: :unknown, known_good: known_good}, runtime)
       when runtime in [:unknown, :terminal],
       do: known_good_or_nil?(known_good)

  defp runtime?(_snapshot, _expected), do: false

  defp known_good_or_nil?(nil), do: true
  defp known_good_or_nil?(known_good), do: known_good?(known_good)

  defp known_good?(%{version: version, digest: digest, revision: revision}),
    do: version?(version) and valid_digest?(digest) and valid_digest?(revision)

  defp known_good?(_known_good), do: false

  defp validate_publications(publications, server_id) do
    if valid_publication_list?(publications, server_id),
      do: {:ok, publications},
      else: internal()
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp valid_publication_list?(publications, server_id)
       when is_list(publications) and length(publications) <= @max_publications do
    Enum.all?(publications, &valid_publication?(&1, server_id)) and
      contiguous_sequences?(Enum.map(publications, & &1.sequence))
  end

  defp valid_publication_list?(_publications, _server_id), do: false

  defp valid_publication?(publication, server_id) when is_map(publication) do
    with true <- exact_keys?(publication, @publication_keys),
         true <- positive_integer?(publication.sequence),
         encoded when is_binary(encoded) <- publication.encoded_message,
         %ConfigState{target_type: :server, target_id: ^server_id} = message <-
           publication.message,
         {:ok, ^message} <- Message.decode(encoded),
         {:ok, ^encoded} <- Message.encode(message) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_publication?(_publication, _server_id), do: false

  defp contiguous_sequences?([]), do: true

  defp contiguous_sequences?([first | rest]) when is_integer(first) and first > 0,
    do: contiguous_sequences?(rest, first)

  defp contiguous_sequences?(_sequences), do: false
  defp contiguous_sequences?([], _previous), do: true

  defp contiguous_sequences?([sequence | rest], previous)
       when is_integer(sequence) and sequence == previous + 1,
       do: contiguous_sequences?(rest, sequence)

  defp contiguous_sequences?(_sequences, _previous), do: false

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp version?(value),
    do: is_integer(value) and value > 0 and value <= @max_version

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_digest?(value), do: match?({:ok, ^value}, Digest.validate(value))

  defp adapter_available?(adapter) do
    Code.ensure_loaded?(adapter) and
      Enum.all?(@adapter_callbacks, fn {callback, arity} ->
        function_exported?(adapter, callback, arity)
      end)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp callback(adapter, callback, args) do
    Kernel.apply(adapter, callback, args)
  rescue
    _exception -> :adapter_failure
  catch
    _kind, _reason -> :adapter_failure
  end

  defp local_call(callback) do
    case callback.() do
      {:error, %Error{} = error} -> {:error, sanitize_error(error)}
      result -> result
    end
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, name} <- process_name(Keyword.get(opts, :name, __MODULE__)),
         {:ok, server_id} <- server_id(Keyword.get(opts, :server_id)),
         {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, config_store} <- server_ref(Keyword.get(opts, :config_store)),
         {:ok, config_apply_store} <- server_ref(Keyword.get(opts, :config_apply_store)),
         {:ok, runtime_adapter} <-
           runtime_adapter(Keyword.get(opts, :runtime_adapter, @default_runtime_adapter)) do
      {:ok,
       %{
         server_id: server_id,
         profile: profile,
         config_store: config_store,
         config_apply_store: config_apply_store,
         runtime_adapter: runtime_adapter
       }, name}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp process_name(nil), do: {:ok, nil}
  defp process_name(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp process_name({:global, _term} = value), do: {:ok, value}

  defp process_name({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp process_name(_value), do: :error

  defp server_ref(value) do
    case GenServer.whereis(value) do
      pid when is_pid(pid) -> {:ok, value}
      _missing -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
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
  defp profile(value), do: nonempty_id(value)

  defp nonempty_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp runtime_adapter(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp runtime_adapter(_value), do: :error

  defp claim_ownership(key) do
    case :global.register_name(key, self()) do
      :yes -> :ok
      :no -> {:error, :already_started}
    end
  rescue
    _exception -> {:error, :registration}
  catch
    _kind, _reason -> {:error, :registration}
  end

  defp release_ownership(key) do
    if :global.whereis_name(key) == self(), do: :global.unregister_name(key)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp sanitize_error(%Error{code: code}) do
    case Map.fetch(@error_messages, code) do
      {:ok, message} -> Error.new(code, message, %{})
      :error -> internal_error()
    end
  end

  defp internal, do: {:error, internal_error()}
  defp internal_error, do: Error.new(:internal, "internal error", %{})
end
