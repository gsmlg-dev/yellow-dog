defmodule YellowDog.NetmanAgent.ConfigApplier do
  @moduledoc """
  Serialized durable Netman configuration application and rollback sequencing.
  """

  use GenServer

  import Kernel, except: [apply: 2]

  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.NetmanAgent.RollbackTimer
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.ConfigState

  @max_publications 3
  @max_version 9_223_372_036_854_775_807
  @default_adapter_timeout 30_000
  @max_adapter_timeout 300_000
  @allowed_options [
    :name,
    :netman_id,
    :config_store,
    :config_apply_store,
    :rollback_timer,
    :runtime_adapter,
    :adapter_timeout
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
    provisional: {:applying, :provisional, :unknown},
    apply_failed: {:failed, :complete, :unconfigured},
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
    provisional: :unknown,
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
          status: :applied | :failed | :provisional | :replay,
          publications: [publication()]
        }
  @type state :: %{
          netman_id: String.t(),
          config_store: server(),
          config_apply_store: server(),
          rollback_timer: server() | nil,
          runtime_adapter: module(),
          adapter_timeout: pos_integer()
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

  @spec confirm_provisional(pos_integer(), server()) ::
          {:ok, result()} | {:error, Error.t()}
  def confirm_provisional(version, server \\ __MODULE__),
    do: GenServer.call(server, {:confirm_provisional, version}, :infinity)

  @spec rollback_provisional(pos_integer(), String.t(), server()) ::
          {:ok, result()} | {:error, Error.t()}
  def rollback_provisional(version, reason, server \\ __MODULE__),
    do: GenServer.call(server, {:rollback_provisional, version, reason}, :infinity)

  @doc "Returns whether a validated profile-set replacement can change management reachability."
  @spec connectivity_change?(map(), map()) :: boolean()
  def connectivity_change?(%{"profiles" => candidate}, %{"profiles" => previous})
      when is_list(candidate) and is_list(previous) do
    connectivity_projection(candidate) != connectivity_projection(previous)
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
  end

  def connectivity_change?(_candidate, _previous), do: true

  @impl true
  def init(config) do
    ownership_key = {__MODULE__, :netman_id, config.netman_id}

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

  def handle_call({:confirm_provisional, version}, _from, state) do
    {:reply, confirm_provisional_version(version, state), state}
  end

  def handle_call({:rollback_provisional, version, reason}, _from, state) do
    case rollback_provisional_version(version, reason, state) do
      {:fail_stop, failure, reply} -> {:stop, failure, reply, state}
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

      callback(config, :validate_config, [envelope.payload]) == :ok ->
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
      operation: envelope.operation
    ]

    case callback(config, :install_config, [envelope.payload, opts]) do
      {:ok, revision} ->
        case Digest.validate(revision) do
          {:ok, revision} ->
            case provisional_change?(envelope, previous, config) do
              {:ok, provisional?} ->
                before_activate(envelope, revision, previous, provisional?, config)

              {:error, _reason} ->
                recover_candidate(
                  envelope.config_version,
                  previous,
                  "previous config unavailable",
                  config
                )
            end

          {:error, %Error{}} ->
            recover_candidate(envelope.config_version, previous, "config install failed", config)
        end

      _error_or_malformed ->
        recover_candidate(envelope.config_version, previous, "config install failed", config)
    end
  end

  defp before_activate(envelope, revision, previous, provisional?, config) do
    attrs = %{version: envelope.config_version, installed_revision: revision}

    case transition_after_side_effect(:before_activate, attrs, envelope.config_version, config) do
      {:ok, _snapshot} ->
        prepare_activation(envelope, revision, previous, provisional?, config)

      error_or_stop ->
        error_or_stop
    end
  end

  defp prepare_activation(envelope, revision, previous, true, config) do
    case arm_rollback(envelope.config_version, previous, config) do
      :ok ->
        activate_candidate(envelope.config_version, revision, previous, :provisional, config)

      :error ->
        recover_candidate(
          envelope.config_version,
          previous,
          "rollback deadline persistence failed",
          config
        )
    end
  end

  defp prepare_activation(envelope, revision, previous, false, config),
    do: activate_candidate(envelope.config_version, revision, previous, :applied, config)

  defp activate_candidate(version, revision, previous, terminal_status, config) do
    case callback(config, :activate_config, [revision]) do
      :ok ->
        event = if terminal_status == :provisional, do: :provisional, else: :applied

        case transition_after_side_effect(
               event,
               %{version: version},
               version,
               config
             ) do
          {:ok, _snapshot} -> result(terminal_status, config)
          error_or_stop -> error_or_stop
        end

      _error_or_malformed ->
        recover_candidate(version, previous, "config activation failed", config)
    end
  end

  defp recover_candidate(version, nil, reason, config) do
    case restore_unconfigured_candidate(version, config) do
      :ok ->
        case transition_after_side_effect(
               :apply_failed,
               %{version: version, reason: reason},
               version,
               config
             ) do
          {:ok, _snapshot} -> failed_result(version, config)
          error_or_stop -> error_or_stop
        end

      :error ->
        latch_unknown(version, config)
    end
  end

  defp recover_candidate(version, previous, reason, config) do
    attrs = %{version: version, trigger_reason: reason}

    case transition_after_side_effect(
           :before_restore,
           attrs,
           version,
           config
         ) do
      {:ok, _snapshot} -> restore_previous(version, previous, config)
      error_or_stop -> error_or_stop
    end
  end

  defp restore_previous(version, previous, config) do
    with {:ok, restore_target} <- restore_target(version, previous, config),
         :ok <- callback(config, :restore_config, [restore_target]) do
      before_reactivate(version, previous, config)
    else
      _error_or_malformed -> rollback_failed(version, "config restore failed", config)
    end
  end

  defp restore_target(version, previous, config) do
    case local_call(fn -> ConfigApplyStore.snapshot(config.config_apply_store) end) do
      {:ok,
       %{
         attempt: %{
           version: ^version,
           installed_revision: installed_revision
         }
       }}
      when is_binary(installed_revision) ->
        {:ok, {:candidate, installed_revision}}

      {:ok, %{attempt: %{version: ^version, installed_revision: nil}}} ->
        case restore_checkpoint_target(version, config) do
          {:ok, :none} -> {:ok, previous.revision}
          {:ok, restore_target} -> {:ok, restore_target}
          :error -> :error
        end

      _unavailable_or_incoherent ->
        :error
    end
  end

  defp restore_unconfigured_candidate(version, config) do
    case restore_checkpoint_target(version, config) do
      {:ok, :none} -> :ok
      {:ok, restore_target} -> callback(config, :restore_config, [restore_target])
      :error -> :error
    end
  end

  defp restore_checkpoint_target(version, config) when is_integer(version) do
    with {:ok, %{attempt: %{version: ^version} = attempt}} <-
           local_call(fn -> ConfigApplyStore.snapshot(config.config_apply_store) end) do
      restore_checkpoint_target(attempt, config)
    else
      _unavailable_or_incoherent -> :error
    end
  end

  defp restore_checkpoint_target(%{installed_revision: revision}, _config)
       when is_binary(revision),
       do: {:ok, {:candidate, revision}}

  defp restore_checkpoint_target(%{installed_revision: nil, digest: digest}, config) do
    case local_call(fn ->
           ConfigStore.fetch_restore_checkpoint(digest, config.config_store)
         end) do
      {:ok, _checkpoint} -> {:ok, {:candidate, digest}}
      {:error, %Error{code: :not_found}} -> {:ok, :none}
      _unavailable_or_incoherent -> :error
    end
  end

  defp before_reactivate(version, previous, config) do
    case transition_after_side_effect(
           :before_reactivate,
           %{version: version},
           version,
           config
         ) do
      {:ok, _snapshot} -> reactivate_previous(version, previous, config)
      error_or_stop -> error_or_stop
    end
  end

  defp reactivate_previous(version, previous, config) do
    case callback(config, :activate_config, [previous.revision]) do
      :ok ->
        case transition_after_side_effect(
               :rollback_succeeded,
               %{version: version},
               version,
               config
             ) do
          {:ok, _snapshot} -> failed_result(version, config)
          error_or_stop -> error_or_stop
        end

      _error_or_malformed ->
        rollback_failed(version, "config reactivation failed", config)
    end
  end

  defp rollback_failed(version, reason, config) do
    attrs = %{version: version, reason: reason}

    case transition_after_side_effect(
           :rollback_failed,
           attrs,
           version,
           config
         ) do
      {:ok, _snapshot} -> failed_result(version, config)
      error_or_stop -> error_or_stop
    end
  end

  defp failed_result(version, config) do
    abort_rollback(version, config)
    result(:failed, config)
  end

  defp provisional_change?(_envelope, nil, _config), do: {:ok, false}

  defp provisional_change?(%Envelope{operation: operation}, _previous, _config)
       when operation != "netman.profiles.replace",
       do: {:ok, false}

  defp provisional_change?(envelope, previous, config) do
    case local_call(fn ->
           ConfigStore.fetch(previous.version, previous.digest, config.config_store)
         end) do
      {:ok,
       %{
         "version" => version,
         "digest" => digest,
         "payload" => previous_payload
       }}
      when version == previous.version and digest == previous.digest and is_map(previous_payload) ->
        {:ok, connectivity_change?(envelope.payload, previous_payload)}

      _missing_or_malformed ->
        {:error, :previous_config}
    end
  end

  defp arm_rollback(version, %{revision: previous_revision}, %{rollback_timer: timer})
       when not is_nil(timer) do
    case local_call(fn -> RollbackTimer.arm(version, previous_revision, timer) end) do
      {:ok,
       %{
         status: :armed,
         version: ^version,
         previous_revision: ^previous_revision
       }} ->
        :ok

      _error_or_malformed ->
        :error
    end
  end

  defp arm_rollback(_version, _previous, _config), do: :error

  defp abort_rollback(version, %{rollback_timer: timer}) when not is_nil(timer) do
    RollbackTimer.abort(version, timer)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp abort_rollback(_version, _config), do: :ok

  defp confirm_provisional_version(version, config) do
    with true <- version?(version),
         {:ok, snapshot} <-
           local_call(fn -> ConfigApplyStore.snapshot(config.config_apply_store) end) do
      cond do
        applied_version?(snapshot, version) ->
          result(:replay, config)

        provisional_version?(snapshot, version) ->
          case transition(:applied, %{version: version}, config) do
            {:ok, _snapshot} -> result(:applied, config)
            {:error, %Error{}} = error -> error
          end

        true ->
          conflict()
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp rollback_provisional_version(version, reason, config) do
    with true <- version?(version),
         {:ok, reason} <- Bounds.message(reason),
         true <- reason != "",
         {:ok, snapshot} <-
           local_call(fn -> ConfigApplyStore.snapshot(config.config_apply_store) end) do
      cond do
        failed_version?(snapshot, version) ->
          result(:replay, config)

        rollback_candidate?(snapshot, version) ->
          recover_candidate(version, snapshot.attempt.previous, reason, config)

        true ->
          conflict()
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp applied_version?(%{attempt: %{version: version, status: :applied}}, version), do: true
  defp applied_version?(_snapshot, _version), do: false

  defp failed_version?(%{attempt: %{version: version, status: :failed}}, version), do: true
  defp failed_version?(_snapshot, _version), do: false

  defp provisional_version?(
         %{
           runtime_status: :unknown,
           attempt: %{version: version, status: :applying, checkpoint: :provisional}
         },
         version
       ),
       do: true

  defp provisional_version?(_snapshot, _version), do: false

  defp rollback_candidate?(
         %{
           attempt: %{
             version: version,
             status: :applying,
             checkpoint: checkpoint,
             previous: previous
           }
         },
         version
       )
       when checkpoint in [
              :before_activate,
              :provisional,
              :unknown,
              :before_restore,
              :before_reactivate
            ] and
              not is_nil(previous),
       do: true

  defp rollback_candidate?(_snapshot, _version), do: false

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
        case validate_publications(publications, config.netman_id) do
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
          {:ok, snapshot} ->
            recover_boot_snapshot(snapshot, config)

          {:error, %Error{}} ->
            {:error, :state}
        end

      _invalid_or_unavailable ->
        {:error, :state}
    end
  end

  defp recover_boot_snapshot(
         %{
           attempt: %{
             status: :applying,
             version: version,
             previous: previous,
             rollback: %{status: :before_restore}
           }
         },
         config
       )
       when not is_nil(previous),
       do: finish_boot_recovery(restore_previous(version, previous, config))

  defp recover_boot_snapshot(
         %{
           attempt: %{
             status: :applying,
             version: version,
             previous: previous,
             rollback: %{status: :before_reactivate}
           }
         },
         config
       )
       when not is_nil(previous),
       do: finish_boot_recovery(reactivate_previous(version, previous, config))

  defp recover_boot_snapshot(
         %{attempt: %{status: :applying, checkpoint: checkpoint} = attempt},
         config
       )
       when checkpoint in @side_effect_checkpoints or checkpoint == :unknown do
    reason = boot_recovery_reason(attempt)
    finish_boot_recovery(recover_candidate(attempt.version, attempt.previous, reason, config))
  end

  defp recover_boot_snapshot(_snapshot, _config), do: :ok

  defp finish_boot_recovery({:ok, %{status: :failed}}), do: :ok
  defp finish_boot_recovery(_failed_or_incoherent), do: {:error, :rollback}

  defp boot_recovery_reason(%{checkpoint: :before_install}),
    do: "runtime restarted during config install"

  defp boot_recovery_reason(%{checkpoint: :unknown, installed_revision: nil}),
    do: "runtime restarted during config install"

  defp boot_recovery_reason(_attempt),
    do: "runtime restarted during config activation"

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
         _config
       )
       when is_map(attempt) do
    same_candidate =
      attempt.version == envelope.config_version and
        attempt.digest == envelope.payload_digest and
        attempt.operation == envelope.operation and
        attempt.expected_revision == envelope.expected_revision

    replayable =
      case {attempt.status, attempt.checkpoint} do
        {:applying, :unknown} -> runtime?(snapshot, :unknown)
        {:applying, :provisional} -> runtime?(snapshot, :unknown)
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
    if target_snapshot?(snapshot, config.netman_id) and predicate.(snapshot),
      do: {:ok, snapshot},
      else: internal()
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp target_snapshot?(
         %{target_type: :netman, target_id: netman_id, attempt: _attempt},
         netman_id
       ),
       do: true

  defp target_snapshot?(_snapshot, _netman_id), do: false

  defp runtime?(%{runtime_status: :unconfigured, known_good: nil}, runtime)
       when runtime in [:stable, :terminal, :unconfigured],
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

  defp connectivity_projection(profiles) do
    profiles
    |> Enum.map(fn profile ->
      {
        Map.fetch!(profile, "profile_id"),
        Map.get(profile, "interface"),
        Map.get(profile, "autoconnect_priority"),
        ip_connectivity_projection(Map.fetch!(profile, "ipv4")),
        ip_connectivity_projection(Map.fetch!(profile, "ipv6"))
      }
    end)
    |> Enum.sort()
  end

  # The profile protocol currently represents routes with each family's gateway.
  # Method covers DHCP/static mode; the remaining fields cover addresses and DNS.
  defp ip_connectivity_projection(config) do
    {
      Map.get(config, "method"),
      Map.get(config, "address"),
      Map.get(config, "gateway"),
      Map.get(config, "dns"),
      Map.get(config, "dns_search")
    }
  end

  defp validate_publications(publications, netman_id) do
    if valid_publication_list?(publications, netman_id),
      do: {:ok, publications},
      else: internal()
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp valid_publication_list?(publications, netman_id)
       when is_list(publications) and length(publications) <= @max_publications do
    Enum.all?(publications, &valid_publication?(&1, netman_id)) and
      contiguous_sequences?(Enum.map(publications, & &1.sequence))
  end

  defp valid_publication_list?(_publications, _netman_id), do: false

  defp valid_publication?(publication, netman_id) when is_map(publication) do
    with true <- exact_keys?(publication, @publication_keys),
         true <- positive_integer?(publication.sequence),
         encoded when is_binary(encoded) <- publication.encoded_message,
         %ConfigState{target_type: :netman, target_id: ^netman_id} = message <-
           publication.message,
         {:ok, ^message} <- Message.decode(encoded),
         {:ok, ^encoded} <- Message.encode(message) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_publication?(_publication, _netman_id), do: false

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

  defp callback(config, callback, args) do
    owner = self()
    tag = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        send(owner, {tag, adapter_callback(config.runtime_adapter, callback, args)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        :adapter_failure
    after
      config.adapter_timeout ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        end

        :adapter_timeout
    end
  end

  defp adapter_callback(adapter, callback, args) do
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
         {:ok, netman_id} <- netman_id(Keyword.get(opts, :netman_id)),
         {:ok, config_store} <- server_ref(Keyword.get(opts, :config_store)),
         {:ok, config_apply_store} <- server_ref(Keyword.get(opts, :config_apply_store)),
         {:ok, rollback_timer} <- optional_server_ref(Keyword.get(opts, :rollback_timer)),
         {:ok, runtime_adapter} <-
           runtime_adapter(Keyword.get(opts, :runtime_adapter)),
         {:ok, adapter_timeout} <-
           adapter_timeout(Keyword.get(opts, :adapter_timeout, @default_adapter_timeout)) do
      {:ok,
       %{
         netman_id: netman_id,
         config_store: config_store,
         config_apply_store: config_apply_store,
         rollback_timer: rollback_timer,
         runtime_adapter: runtime_adapter,
         adapter_timeout: adapter_timeout
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

  defp optional_server_ref(nil), do: {:ok, nil}
  defp optional_server_ref(value), do: server_ref(value)

  defp netman_id(value) do
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

  defp adapter_timeout(value)
       when is_integer(value) and value > 0 and value <= @max_adapter_timeout,
       do: {:ok, value}

  defp adapter_timeout(_value), do: :error

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
  defp invalid, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp conflict, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp internal_error, do: Error.new(:internal, "internal error", %{})
end
