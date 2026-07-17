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

  @default_runtime_adapter :"Elixir.YellowDog.Server.Control"
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
    case recover_uncertain_side_effect(config) do
      :ok -> {:ok, config}
      {:error, phase} -> {:stop, {:config_applier_recovery_failed, phase}}
    end
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
      {:replay, snapshot} when is_map(snapshot) -> {:replay, snapshot}
      {:error, %Error{}} = error -> error
      _malformed -> internal()
    end
  end

  defp transition(event, attrs, config) do
    case local_call(fn ->
           ConfigApplyStore.transition(event, attrs, config.config_apply_store)
         end) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      {:error, %Error{}} = error -> error
      _malformed -> internal()
    end
  end

  defp result(status, config) do
    case local_call(fn ->
           ConfigApplyStore.pending_publications(config.config_apply_store)
         end) do
      {:ok, publications} when is_list(publications) ->
        {:ok, %{status: status, publications: publications}}

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
      {:ok, %{attempt: %{status: :applying, checkpoint: checkpoint, version: version}}}
      when checkpoint in @side_effect_checkpoints ->
        recover_uncertain_transition(version, config)

      {:ok, %{attempt: nil}} ->
        :ok

      {:ok, %{attempt: %{status: :delivered, checkpoint: checkpoint}}}
      when checkpoint in [:staged, :before_validate] ->
        :ok

      {:ok, %{attempt: %{status: :applying, checkpoint: :unknown}}} ->
        :ok

      {:ok, %{attempt: %{status: status, checkpoint: :complete}}}
      when status in [:applied, :failed] ->
        :ok

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

  defp sanitize_error(%Error{code: code}) do
    case Map.fetch(@error_messages, code) do
      {:ok, message} -> Error.new(code, message, %{})
      :error -> internal_error()
    end
  end

  defp internal, do: {:error, internal_error()}
  defp internal_error, do: Error.new(:internal, "internal error", %{})
end
