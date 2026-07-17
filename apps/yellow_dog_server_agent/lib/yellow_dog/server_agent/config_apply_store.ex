defmodule YellowDog.ServerAgent.ConfigApplyStore do
  @moduledoc """
  Durable runtime config-apply evidence and ConfigState publication replay.
  """

  use GenServer

  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Storage
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Operation

  @schema_version 1
  @max_version 9_223_372_036_854_775_807
  @inconsistent_persistence :config_apply_inconsistent_persistence
  @top_keys ~w(
    attempt known_good next_publication_sequence observed_at outbox
    published_through runtime_status schema_version target_id target_type
  )
  @known_good_keys ~w(digest revision version)
  @attempt_keys ~w(
    checkpoint digest expected_revision failure installed_revision operation
    previous profile rollback status version
  )
  @failure_keys ~w(phase reason)
  @rollback_keys ~w(
    reason restored_revision restored_version status succeeded trigger_reason
  )
  @outbox_keys ~w(encoded_message sequence)
  @candidate_keys ~w(
    digest expected_revision operation payload profile published_at
    schema_version target_id target_type version
  )
  @side_effect_checkpoints [
    :before_install,
    :before_activate,
    :before_restore,
    :before_reactivate
  ]
  @event_attrs %{
    delivered: [:candidate],
    before_validate: [:version],
    validation_failed: [:reason, :version],
    before_install: [:version],
    before_activate: [:installed_revision, :version],
    apply_failed: [:reason, :version],
    before_restore: [:trigger_reason, :version],
    before_reactivate: [:version],
    rollback_succeeded: [:version],
    rollback_failed: [:reason, :version],
    applied: [:version],
    uncertain_after_side_effect: [:version]
  }
  @runtime_statuses [:unconfigured, :known, :unknown]
  @attempt_statuses [:delivered, :applying, :applied, :failed]
  @checkpoints [
    :staged,
    :before_validate,
    :before_install,
    :before_activate,
    :before_restore,
    :before_reactivate,
    :complete,
    :unknown
  ]
  @failure_phases [:validation, :apply, :rollback]
  @rollback_statuses [:before_restore, :before_reactivate, :succeeded, :failed]

  @type server :: GenServer.server()
  @type publication :: %{
          sequence: pos_integer(),
          encoded_message: String.t(),
          message: ConfigState.t()
        }
  @type snapshot :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- build_config(opts) do
      case Keyword.get(opts, :name, __MODULE__) do
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

  @spec snapshot(server()) :: {:ok, snapshot()} | {:error, Error.t()}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec preflight(Envelope.t(), server()) ::
          {:admit, :new}
          | {:resume, :staged | :before_validate}
          | {:replay, snapshot()}
          | {:error, Error.t()}
  def preflight(envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:preflight, envelope})

  @spec transition(atom(), map(), server()) :: {:ok, snapshot()} | {:error, Error.t()}
  def transition(event, attrs, server \\ __MODULE__),
    do: GenServer.call(server, {:transition, event, attrs})

  @spec pending_publications(server()) :: {:ok, [publication()]} | {:error, Error.t()}
  def pending_publications(server \\ __MODULE__),
    do: GenServer.call(server, :pending_publications)

  @spec acknowledge_publication(integer(), server()) ::
          {:ok, snapshot()} | {:error, Error.t()}
  def acknowledge_publication(sequence, server \\ __MODULE__),
    do: GenServer.call(server, {:acknowledge_publication, sequence})

  @impl true
  def init(config) do
    with :ok <- ensure_owned_path(config),
         {:ok, snapshot, persisted?} <- load_snapshot(config),
         :ok <- cross_check_staging(snapshot, config),
         {:ok, snapshot, persisted?} <- recover_side_effect(snapshot, persisted?, config) do
      {:ok, %{config: config, snapshot: snapshot, persisted?: persisted?}}
    else
      {:error, :path} -> {:stop, {:config_apply_recovery_failed, :path}}
      {:error, :staging} -> {:stop, {:config_apply_recovery_failed, :staging}}
      {:error, :corrupt} -> {:stop, {:config_apply_recovery_failed, :corrupt}}
      {:error, %Error{}} -> {:stop, {:config_apply_recovery_failed, :persistence}}
      {:stop, reason} -> {:stop, reason}
      _other -> {:stop, {:config_apply_recovery_failed, :corrupt}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    guarded_reply(state, :snapshot, fn -> {:reply, {:ok, state.snapshot}, state} end)
  end

  def handle_call({:preflight, envelope}, _from, state) do
    guarded_reply(state, :preflight, fn ->
      reply =
        with {:ok, candidate} <- validate_envelope(envelope, state.config) do
          preflight_candidate(candidate, state.snapshot)
        end

      {:reply, reply, state}
    end)
  end

  def handle_call({:transition, event, attrs}, _from, state) do
    guarded_reply(state, event, fn ->
      case transition_snapshot(event, attrs, state.snapshot, state.config) do
        {:idempotent, snapshot} ->
          {:reply, {:ok, snapshot}, state}

        {:ok, intended} ->
          persist_call(event, intended, state)

        {:error, %Error{} = error} ->
          {:reply, {:error, error}, state}
      end
    end)
  end

  def handle_call(:pending_publications, _from, state) do
    guarded_reply(state, :pending_publications, fn ->
      {:reply, {:ok, state.snapshot.outbox}, state}
    end)
  end

  def handle_call({:acknowledge_publication, sequence}, _from, state) do
    guarded_reply(state, :acknowledge_publication, fn ->
      case acknowledge(sequence, state.snapshot) do
        {:idempotent, snapshot} ->
          {:reply, {:ok, snapshot}, state}

        {:ok, intended} ->
          persist_call(:acknowledge_publication, intended, state)

        {:error, %Error{} = error} ->
          {:reply, {:error, error}, state}
      end
    end)
  end

  defp guarded_reply(state, phase, callback) do
    case ensure_operation_path(state) do
      :ok ->
        callback.()

      {:error, :path} ->
        reason = {@inconsistent_persistence, phase}
        {:stop, reason, internal(), state}
    end
  end

  defp persist_call(phase, intended, state) do
    case persist_snapshot(state.snapshot, intended, state.persisted?, phase, state.config) do
      {:ok, snapshot} ->
        {:reply, {:ok, snapshot}, %{state | snapshot: snapshot, persisted?: true}}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:stop, reason} ->
        {:stop, reason, internal(), state}
    end
  end

  defp transition_snapshot(event, attrs, snapshot, config) do
    with :ok <- exact_attrs(event, attrs) do
      do_transition(event, attrs, snapshot, config)
    end
  end

  defp do_transition(:delivered, %{candidate: candidate}, snapshot, config) do
    with {:ok, candidate_data} <- validate_candidate(candidate, config),
         :ok <- current_candidate(candidate, config),
         :ok <- expected_revision(candidate_data.expected_revision, snapshot.known_good) do
      cond do
        duplicate_delivered?(candidate_data, snapshot) ->
          {:idempotent, snapshot}

        replaceable?(snapshot) ->
          publish_update(config, :delivered, fn now ->
            %{snapshot | attempt: new_attempt(candidate_data), observed_at: now}
          end)

        true ->
          conflict()
      end
    end
  end

  defp do_transition(:before_validate, %{version: version}, snapshot, config) do
    cond do
      match_attempt?(snapshot, version, :delivered, :before_validate) ->
        {:idempotent, snapshot}

      match_attempt?(snapshot, version, :delivered, :staged) ->
        update_attempt(snapshot, config, fn attempt ->
          %{attempt | checkpoint: :before_validate}
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(
         :validation_failed,
         %{version: version, reason: reason},
         snapshot,
         config
       ) do
    with {:ok, reason} <- reason(reason) do
      cond do
        terminal_failure?(snapshot, version, :validation, reason, nil) ->
          {:idempotent, snapshot}

        match_attempt?(snapshot, version, :delivered, :before_validate) ->
          publish_update(config, :failed, fn now ->
            attempt = %{
              snapshot.attempt
              | status: :failed,
                checkpoint: :complete,
                failure: %{phase: :validation, reason: reason}
            }

            %{snapshot | attempt: attempt, observed_at: now}
          end)

        true ->
          conflict()
      end
    end
  end

  defp do_transition(:before_install, %{version: version}, snapshot, config) do
    cond do
      match_attempt?(snapshot, version, :applying, :before_install) ->
        {:idempotent, snapshot}

      match_attempt?(snapshot, version, :delivered, :before_validate) ->
        publish_update(config, :applying, fn now ->
          attempt = %{
            snapshot.attempt
            | status: :applying,
              checkpoint: :before_install,
              previous: snapshot.known_good
          }

          %{snapshot | attempt: attempt, observed_at: now}
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(
         :before_activate,
         %{version: version, installed_revision: revision},
         snapshot,
         config
       ) do
    with {:ok, revision} <- Digest.validate(revision) do
      cond do
        match_attempt?(snapshot, version, :applying, :before_activate) and
            snapshot.attempt.installed_revision == revision ->
          {:idempotent, snapshot}

        match_attempt?(snapshot, version, :applying, :before_install) ->
          update_attempt(snapshot, config, fn attempt ->
            %{attempt | checkpoint: :before_activate, installed_revision: revision}
          end)

        true ->
          conflict()
      end
    else
      _invalid -> invalid()
    end
  end

  defp do_transition(:apply_failed, %{version: version, reason: reason}, snapshot, config) do
    with {:ok, reason} <- reason(reason) do
      cond do
        terminal_failure?(snapshot, version, :apply, reason, nil) ->
          {:idempotent, snapshot}

        applying_checkpoint?(snapshot, version) and is_nil(snapshot.attempt.previous) ->
          publish_update(config, :failed, fn now ->
            attempt = %{
              snapshot.attempt
              | status: :failed,
                checkpoint: :complete,
                failure: %{phase: :apply, reason: reason}
            }

            %{
              snapshot
              | runtime_status: :unknown,
                attempt: attempt,
                observed_at: now
            }
          end)

        true ->
          conflict()
      end
    end
  end

  defp do_transition(
         :before_restore,
         %{version: version, trigger_reason: trigger_reason},
         snapshot,
         config
       ) do
    with {:ok, trigger_reason} <- reason(trigger_reason) do
      cond do
        match_attempt?(snapshot, version, :applying, :before_restore) and
            snapshot.attempt.failure == %{phase: :apply, reason: trigger_reason} ->
          {:idempotent, snapshot}

        applying_checkpoint?(snapshot, version) and not is_nil(snapshot.attempt.previous) ->
          update_attempt_and_runtime(snapshot, config, :unknown, fn attempt ->
            %{
              attempt
              | checkpoint: :before_restore,
                failure: %{phase: :apply, reason: trigger_reason},
                rollback: %{
                  trigger_reason: trigger_reason,
                  status: :before_restore,
                  succeeded: nil,
                  restored_version: nil,
                  restored_revision: nil,
                  reason: nil
                }
            }
          end)

        true ->
          conflict()
      end
    end
  end

  defp do_transition(:before_reactivate, %{version: version}, snapshot, config) do
    cond do
      match_attempt?(snapshot, version, :applying, :before_reactivate) ->
        {:idempotent, snapshot}

      match_attempt?(snapshot, version, :applying, :before_restore) ->
        update_attempt_and_runtime(snapshot, config, :unknown, fn attempt ->
          %{
            attempt
            | checkpoint: :before_reactivate,
              rollback: %{attempt.rollback | status: :before_reactivate}
          }
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(:rollback_succeeded, %{version: version}, snapshot, config) do
    cond do
      rollback_terminal?(snapshot, version, :succeeded, nil) ->
        {:idempotent, snapshot}

      match_attempt?(snapshot, version, :applying, :before_reactivate) ->
        publish_update(config, :failed, fn now ->
          rollback = %{
            snapshot.attempt.rollback
            | status: :succeeded,
              succeeded: true,
              restored_version: snapshot.attempt.previous.version,
              restored_revision: snapshot.attempt.previous.revision
          }

          attempt = %{
            snapshot.attempt
            | status: :failed,
              checkpoint: :complete,
              rollback: rollback
          }

          %{snapshot | runtime_status: :known, attempt: attempt, observed_at: now}
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(
         :rollback_failed,
         %{version: version, reason: reason},
         snapshot,
         config
       ) do
    with {:ok, reason} <- reason(reason) do
      cond do
        rollback_terminal?(snapshot, version, :failed, reason) ->
          {:idempotent, snapshot}

        rollback_checkpoint?(snapshot, version) ->
          publish_update(config, :failed, fn now ->
            rollback = %{
              snapshot.attempt.rollback
              | status: :failed,
                succeeded: false,
                restored_version: nil,
                restored_revision: nil,
                reason: reason
            }

            attempt = %{
              snapshot.attempt
              | status: :failed,
                checkpoint: :complete,
                failure: %{phase: :rollback, reason: reason},
                rollback: rollback
            }

            %{snapshot | runtime_status: :unknown, attempt: attempt, observed_at: now}
          end)

        true ->
          conflict()
      end
    end
  end

  defp do_transition(:applied, %{version: version}, snapshot, config) do
    cond do
      applied_terminal?(snapshot, version) ->
        {:idempotent, snapshot}

      match_attempt?(snapshot, version, :applying, :before_activate) ->
        publish_update(config, :applied, fn now ->
          known_good = %{
            version: snapshot.attempt.version,
            digest: snapshot.attempt.digest,
            revision: snapshot.attempt.installed_revision
          }

          %{
            snapshot
            | known_good: known_good,
              runtime_status: :known,
              attempt: %{snapshot.attempt | status: :applied, checkpoint: :complete},
              observed_at: now
          }
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(
         :uncertain_after_side_effect,
         %{version: version},
         snapshot,
         config
       ) do
    cond do
      match_attempt?(snapshot, version, :applying, :unknown) ->
        {:idempotent, snapshot}

      applying_side_effect_checkpoint?(snapshot, version) ->
        update_attempt_and_runtime(snapshot, config, :unknown, fn attempt ->
          %{attempt | checkpoint: :unknown}
        end)

      true ->
        conflict()
    end
  end

  defp do_transition(_event, _attrs, _snapshot, _config), do: invalid()

  defp update_attempt(snapshot, config, updater) do
    with {:ok, now} <- now(config) do
      {:ok, %{snapshot | attempt: updater.(snapshot.attempt), observed_at: now}}
    end
  end

  defp update_attempt_and_runtime(snapshot, config, runtime_status, updater) do
    with {:ok, now} <- now(config) do
      {:ok,
       %{
         snapshot
         | runtime_status: runtime_status,
           attempt: updater.(snapshot.attempt),
           observed_at: now
       }}
    end
  end

  defp publish_update(config, message_state, updater) do
    with {:ok, now} <- now(config),
         intended <- updater.(now) do
      publish(intended, message_state, now)
    end
  end

  defp publish(snapshot, state, observed_at) do
    with true <- length(snapshot.outbox) < 3,
         message <- config_state(snapshot, state, observed_at),
         {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded) do
      entry = %{
        sequence: snapshot.next_publication_sequence,
        encoded_message: encoded,
        message: message
      }

      {:ok,
       %{
         snapshot
         | outbox: snapshot.outbox ++ [entry],
           next_publication_sequence: snapshot.next_publication_sequence + 1
       }}
    else
      _invalid -> internal()
    end
  end

  defp config_state(snapshot, state, observed_at) do
    attempt = snapshot.attempt
    {previous_version, previous_revision} = publication_previous(attempt, state)

    %ConfigState{
      target_type: :server,
      target_id: snapshot.target_id,
      operation: attempt.operation,
      state: state,
      version: attempt.version,
      digest: attempt.digest,
      applied_revision: if(state == :applied, do: attempt.installed_revision),
      previous_version: previous_version,
      previous_revision: previous_revision,
      failure: publication_failure(attempt, state),
      rollback: publication_rollback(attempt, state),
      observed_at: observed_at
    }
  end

  defp publication_previous(%{failure: %{phase: :validation}}, :failed), do: {nil, nil}
  defp publication_previous(%{previous: nil}, _state), do: {nil, nil}
  defp publication_previous(_attempt, :delivered), do: {nil, nil}

  defp publication_previous(%{previous: previous}, _state),
    do: {previous.version, previous.revision}

  defp publication_failure(%{failure: failure}, :failed), do: encode_failure(failure)
  defp publication_failure(_attempt, _state), do: nil

  defp publication_rollback(%{rollback: rollback}, :failed)
       when rollback.status in [:succeeded, :failed] do
    %{
      "succeeded" => rollback.succeeded,
      "restored_version" => rollback.restored_version,
      "restored_revision" => rollback.restored_revision,
      "reason" => rollback.reason
    }
  end

  defp publication_rollback(_attempt, _state), do: nil

  defp preflight_candidate(candidate, snapshot) do
    cond do
      not is_nil(snapshot.attempt) and same_candidate?(candidate, snapshot.attempt) ->
        same_candidate_preflight(snapshot)

      is_nil(snapshot.attempt) or replaceable?(snapshot) ->
        with :ok <- expected_revision(candidate.expected_revision, snapshot.known_good) do
          {:admit, :new}
        end

      true ->
        conflict()
    end
  end

  defp same_candidate_preflight(%{attempt: %{status: :delivered, checkpoint: checkpoint}})
       when checkpoint in [:staged, :before_validate],
       do: {:resume, checkpoint}

  defp same_candidate_preflight(%{attempt: %{checkpoint: :unknown}} = snapshot),
    do: {:replay, snapshot}

  defp same_candidate_preflight(%{attempt: %{status: status}} = snapshot)
       when status in [:applied, :failed],
       do: {:replay, snapshot}

  defp same_candidate_preflight(_snapshot), do: conflict()

  defp replaceable?(%{attempt: nil}), do: true

  defp replaceable?(%{
         runtime_status: runtime_status,
         attempt: %{status: status, checkpoint: :complete},
         outbox: []
       })
       when runtime_status in [:known, :unconfigured] and status in [:applied, :failed],
       do: true

  defp replaceable?(_snapshot), do: false

  defp acknowledge(sequence, snapshot)
       when is_integer(sequence) and sequence > 0 and sequence <= snapshot.published_through,
       do: {:idempotent, snapshot}

  defp acknowledge(
         sequence,
         %{outbox: [%{sequence: sequence} | rest]} = snapshot
       ) do
    {:ok, %{snapshot | published_through: sequence, outbox: rest}}
  end

  defp acknowledge(_sequence, _snapshot), do: conflict()

  defp recover_side_effect(
         %{attempt: %{status: :applying, checkpoint: checkpoint}} = snapshot,
         persisted?,
         config
       )
       when checkpoint in @side_effect_checkpoints do
    intended = %{
      snapshot
      | runtime_status: :unknown,
        attempt: %{snapshot.attempt | checkpoint: :unknown}
    }

    case persist_snapshot(snapshot, intended, persisted?, :startup_recovery, config) do
      {:ok, intended} -> {:ok, intended, true}
      {:error, %Error{} = error} -> {:error, error}
      {:stop, reason} -> {:stop, reason}
    end
  end

  defp recover_side_effect(snapshot, persisted?, _config),
    do: {:ok, snapshot, persisted?}

  defp persist_snapshot(prior, intended, persisted?, phase, config) do
    path = apply_state_path(config)
    intended_document = encode_snapshot(intended)
    prior_document = if persisted?, do: encode_snapshot(prior)

    with :ok <- ensure_write_path(config, persisted?) do
      case Storage.replace(path, intended_document, config.storage_opts) do
        {:ok, ^path} ->
          case regular_file_identity(path) do
            {:ok, _identity} -> {:ok, intended}
            _unsafe -> {:stop, {@inconsistent_persistence, phase}}
          end

        {:error, %Error{} = storage_error} ->
          reconcile_replace_error(
            prior_document,
            intended_document,
            intended,
            storage_error,
            phase,
            config
          )

        _invalid ->
          {:stop, {@inconsistent_persistence, phase}}
      end
    else
      _unsafe -> {:stop, {@inconsistent_persistence, phase}}
    end
  end

  defp reconcile_replace_error(
         prior_document,
         intended_document,
         intended,
         storage_error,
         phase,
         config
       ) do
    with {:ok, durable_document} <- strict_read(config),
         {:ok, _snapshot} <- decode_snapshot(durable_document, config) do
      cond do
        durable_document == intended_document ->
          {:ok, intended}

        not is_nil(prior_document) and durable_document == prior_document ->
          {:error, storage_error}

        true ->
          {:stop, {@inconsistent_persistence, phase}}
      end
    else
      _missing_corrupt_or_changed -> {:stop, {@inconsistent_persistence, phase}}
    end
  end

  defp load_snapshot(config) do
    case final_file_status(apply_state_path(config)) do
      :missing ->
        {:ok, initial_snapshot(config), false}

      {:regular, _identity} ->
        with {:ok, document} <- strict_read(config),
             {:ok, snapshot} <- decode_snapshot(document, config) do
          {:ok, snapshot, true}
        else
          _invalid -> {:error, :corrupt}
        end

      :unsafe ->
        {:error, :path}
    end
  end

  defp strict_read(config) do
    path = apply_state_path(config)

    with :ok <- ensure_owned_path(config),
         {:ok, identity} <- regular_file_identity(path),
         {:ok, document} <- Storage.read(path, config.storage_opts),
         {:ok, ^identity} <- regular_file_identity(path) do
      {:ok, document}
    else
      {:error, %Error{code: :not_found}} -> {:error, :missing}
      _unsafe_or_changed -> {:error, :corrupt}
    end
  end

  defp cross_check_staging(%{attempt: nil}, _config), do: :ok

  defp cross_check_staging(%{attempt: attempt}, config) do
    case config_store_current(config) do
      {:ok, candidate} ->
        with {:ok, candidate_data} <- validate_candidate(candidate, config),
             true <- same_candidate?(candidate_data, attempt) do
          :ok
        else
          _invalid -> {:error, :staging}
        end

      _error ->
        {:error, :staging}
    end
  end

  defp current_candidate(candidate, config) do
    case config_store_current(config) do
      {:ok, ^candidate} -> :ok
      _missing_mismatch_or_corrupt -> invalid()
    end
  end

  defp config_store_current(config) do
    ConfigStore.current(config.config_store)
  rescue
    _exception -> invalid()
  catch
    :exit, _reason -> invalid()
  end

  defp validate_envelope(%Envelope{} = envelope, config) do
    with {:ok, ^envelope} <- Operation.validate_envelope(envelope, :config),
         :server <- envelope.target_type,
         true <- envelope.target_id == config.server_id,
         {:ok, version} <- version(envelope.config_version),
         :ok <- Digest.verify(envelope.payload, envelope.payload_digest),
         {:ok, operation} <- config_operation(envelope.operation, envelope.payload),
         {:ok, expected_revision} <- optional_digest(envelope.expected_revision) do
      {:ok,
       %{
         target_id: config.server_id,
         profile: config.profile,
         version: version,
         digest: envelope.payload_digest,
         operation: operation,
         expected_revision: expected_revision
       }}
    else
      _invalid -> invalid()
    end
  end

  defp validate_envelope(_envelope, _config), do: invalid()

  defp validate_candidate(candidate, config) when is_map(candidate) do
    with true <- exact_keys?(candidate, @candidate_keys),
         @schema_version <- candidate["schema_version"],
         "server" <- candidate["target_type"],
         true <- candidate["target_id"] == config.server_id,
         {:ok, version} <- version(candidate["version"]),
         {:ok, operation} <- config_operation(candidate["operation"], candidate["payload"]),
         true <- candidate["profile"] == config.profile,
         :ok <- Digest.verify(candidate["payload"], candidate["digest"]),
         {:ok, expected_revision} <- optional_digest(candidate["expected_revision"]),
         {:ok, _published_at} <- decode_datetime(candidate["published_at"]) do
      {:ok,
       %{
         target_id: config.server_id,
         profile: config.profile,
         version: version,
         digest: candidate["digest"],
         operation: operation,
         expected_revision: expected_revision
       }}
    else
      _invalid -> invalid()
    end
  end

  defp validate_candidate(_candidate, _config), do: invalid()

  defp expected_revision(nil, nil), do: :ok

  defp expected_revision(revision, %{revision: revision}) when is_binary(revision),
    do: :ok

  defp expected_revision(_expected, _known_good), do: conflict()

  defp new_attempt(candidate) do
    %{
      version: candidate.version,
      digest: candidate.digest,
      operation: candidate.operation,
      profile: candidate.profile,
      expected_revision: candidate.expected_revision,
      status: :delivered,
      checkpoint: :staged,
      previous: nil,
      installed_revision: nil,
      failure: nil,
      rollback: nil
    }
  end

  defp duplicate_delivered?(candidate, %{attempt: attempt})
       when not is_nil(attempt) do
    same_candidate?(candidate, attempt) and attempt.status == :delivered and
      attempt.checkpoint == :staged and is_nil(attempt.previous) and
      is_nil(attempt.installed_revision) and is_nil(attempt.failure) and
      is_nil(attempt.rollback)
  end

  defp duplicate_delivered?(_candidate, _snapshot), do: false

  defp same_candidate?(candidate, attempt) do
    candidate.target_id == attempt_target_id(attempt, candidate.target_id) and
      candidate.profile == attempt.profile and candidate.version == attempt.version and
      candidate.digest == attempt.digest and candidate.operation == attempt.operation and
      candidate.expected_revision == attempt.expected_revision
  end

  defp attempt_target_id(_attempt, configured_id), do: configured_id

  defp match_attempt?(%{attempt: attempt}, version, status, checkpoint)
       when not is_nil(attempt),
       do:
         attempt.version == version and attempt.status == status and
           attempt.checkpoint == checkpoint

  defp match_attempt?(_snapshot, _version, _status, _checkpoint), do: false

  defp applying_checkpoint?(snapshot, version) do
    Enum.any?([:before_install, :before_activate], fn checkpoint ->
      match_attempt?(snapshot, version, :applying, checkpoint)
    end)
  end

  defp applying_side_effect_checkpoint?(snapshot, version) do
    Enum.any?(@side_effect_checkpoints, fn checkpoint ->
      match_attempt?(snapshot, version, :applying, checkpoint)
    end)
  end

  defp rollback_checkpoint?(snapshot, version) do
    Enum.any?([:before_restore, :before_reactivate], fn checkpoint ->
      match_attempt?(snapshot, version, :applying, checkpoint)
    end)
  end

  defp terminal_failure?(%{attempt: attempt}, version, phase, reason, rollback)
       when not is_nil(attempt) do
    attempt.version == version and attempt.status == :failed and attempt.checkpoint == :complete and
      attempt.failure == %{phase: phase, reason: reason} and attempt.rollback == rollback
  end

  defp terminal_failure?(_snapshot, _version, _phase, _reason, _rollback), do: false

  defp rollback_terminal?(%{attempt: attempt}, version, status, reason)
       when not is_nil(attempt) do
    attempt.version == version and attempt.status == :failed and attempt.checkpoint == :complete and
      not is_nil(attempt.rollback) and attempt.rollback.status == status and
      attempt.rollback.reason == reason
  end

  defp rollback_terminal?(_snapshot, _version, _status, _reason), do: false

  defp applied_terminal?(%{attempt: attempt}, version) when not is_nil(attempt),
    do:
      attempt.version == version and attempt.status == :applied and
        attempt.checkpoint == :complete

  defp applied_terminal?(_snapshot, _version), do: false

  defp decode_snapshot(document, config) when is_map(document) do
    with true <- exact_keys?(document, @top_keys),
         @schema_version <- document["schema_version"],
         "server" <- document["target_type"],
         true <- document["target_id"] == config.server_id,
         {:ok, known_good} <- decode_known_good(document["known_good"]),
         {:ok, runtime_status} <- decode_runtime_status(document["runtime_status"]),
         :ok <- coherent_runtime(runtime_status, known_good),
         {:ok, attempt} <- decode_attempt(document["attempt"], config),
         {:ok, observed_at} <- decode_optional_datetime(document["observed_at"]),
         {:ok, published_through} <- nonnegative_integer(document["published_through"]),
         {:ok, next_sequence} <- positive_integer(document["next_publication_sequence"]),
         {:ok, outbox} <- decode_outbox(document["outbox"], config.server_id),
         :ok <- coherent_sequences(published_through, next_sequence, outbox),
         snapshot = %{
           schema_version: @schema_version,
           target_type: :server,
           target_id: config.server_id,
           known_good: known_good,
           runtime_status: runtime_status,
           attempt: attempt,
           observed_at: observed_at,
           published_through: published_through,
           next_publication_sequence: next_sequence,
           outbox: outbox
         },
         :ok <- coherent_attempt(snapshot),
         :ok <- coherent_outbox(snapshot) do
      {:ok, snapshot}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_snapshot(_document, _config), do: {:error, :corrupt}

  defp decode_known_good(nil), do: {:ok, nil}

  defp decode_known_good(value) when is_map(value) do
    with true <- exact_keys?(value, @known_good_keys),
         {:ok, version} <- version(value["version"]),
         {:ok, digest} <- Digest.validate(value["digest"]),
         {:ok, revision} <- Digest.validate(value["revision"]) do
      {:ok, %{version: version, digest: digest, revision: revision}}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_known_good(_value), do: {:error, :corrupt}

  defp decode_attempt(nil, _config), do: {:ok, nil}

  defp decode_attempt(value, config) when is_map(value) do
    with true <- exact_keys?(value, @attempt_keys),
         {:ok, version} <- version(value["version"]),
         {:ok, digest} <- Digest.validate(value["digest"]),
         {:ok, operation} <- config_operation_name(value["operation"]),
         true <- value["profile"] == config.profile,
         {:ok, expected_revision} <- optional_digest(value["expected_revision"]),
         {:ok, status} <- decode_attempt_status(value["status"]),
         {:ok, checkpoint} <- decode_checkpoint(value["checkpoint"]),
         {:ok, previous} <- decode_known_good(value["previous"]),
         {:ok, installed_revision} <- optional_digest(value["installed_revision"]),
         {:ok, failure} <- decode_failure(value["failure"]),
         {:ok, rollback} <- decode_rollback(value["rollback"]) do
      {:ok,
       %{
         version: version,
         digest: digest,
         operation: operation,
         profile: config.profile,
         expected_revision: expected_revision,
         status: status,
         checkpoint: checkpoint,
         previous: previous,
         installed_revision: installed_revision,
         failure: failure,
         rollback: rollback
       }}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_attempt(_value, _config), do: {:error, :corrupt}

  defp decode_failure(nil), do: {:ok, nil}

  defp decode_failure(value) when is_map(value) do
    with true <- exact_keys?(value, @failure_keys),
         {:ok, phase} <- decode_failure_phase(value["phase"]),
         {:ok, reason} <- reason(value["reason"]) do
      {:ok, %{phase: phase, reason: reason}}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_failure(_value), do: {:error, :corrupt}

  defp decode_rollback(nil), do: {:ok, nil}

  defp decode_rollback(value) when is_map(value) do
    with true <- exact_keys?(value, @rollback_keys),
         {:ok, trigger_reason} <- reason(value["trigger_reason"]),
         {:ok, status} <- decode_rollback_status(value["status"]),
         {:ok, succeeded} <- optional_boolean(value["succeeded"]),
         {:ok, restored_version} <- optional_version(value["restored_version"]),
         {:ok, restored_revision} <- optional_digest(value["restored_revision"]),
         {:ok, rollback_reason} <- optional_reason(value["reason"]),
         :ok <-
           coherent_rollback_fields(
             status,
             succeeded,
             restored_version,
             restored_revision,
             rollback_reason
           ) do
      {:ok,
       %{
         trigger_reason: trigger_reason,
         status: status,
         succeeded: succeeded,
         restored_version: restored_version,
         restored_revision: restored_revision,
         reason: rollback_reason
       }}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_rollback(_value), do: {:error, :corrupt}

  defp decode_outbox(value, server_id) when is_list(value) and length(value) <= 3 do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, entries} ->
      case decode_outbox_entry(entry, server_id) do
        {:ok, decoded} -> {:cont, {:ok, entries ++ [decoded]}}
        _invalid -> {:halt, {:error, :corrupt}}
      end
    end)
  end

  defp decode_outbox(_value, _server_id), do: {:error, :corrupt}

  defp decode_outbox_entry(value, server_id) when is_map(value) do
    with true <- exact_keys?(value, @outbox_keys),
         {:ok, sequence} <- positive_integer(value["sequence"]),
         encoded when is_binary(encoded) <- value["encoded_message"],
         {:ok, %ConfigState{target_type: :server, target_id: ^server_id} = message} <-
           Message.decode(encoded),
         {:ok, ^encoded} <- Message.encode(message) do
      {:ok, %{sequence: sequence, encoded_message: encoded, message: message}}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_outbox_entry(_value, _server_id), do: {:error, :corrupt}

  defp coherent_runtime(:known, known_good) when not is_nil(known_good), do: :ok
  defp coherent_runtime(:unconfigured, nil), do: :ok
  defp coherent_runtime(:unknown, _known_good), do: :ok
  defp coherent_runtime(_status, _known_good), do: {:error, :corrupt}

  defp coherent_attempt(%{attempt: nil, runtime_status: :unconfigured, known_good: nil}), do: :ok

  defp coherent_attempt(%{attempt: nil}), do: {:error, :corrupt}

  defp coherent_attempt(%{attempt: attempt, observed_at: %DateTime{}} = snapshot) do
    with :ok <- coherent_candidate_revision(attempt, snapshot.known_good),
         :ok <- coherent_candidate_versions(attempt, snapshot.known_good),
         :ok <- coherent_attempt_state(attempt, snapshot) do
      :ok
    end
  end

  defp coherent_attempt(_snapshot), do: {:error, :corrupt}

  defp coherent_candidate_revision(
         %{status: :applied, previous: nil, expected_revision: nil},
         _known_good
       ),
       do: :ok

  defp coherent_candidate_revision(
         %{previous: %{revision: revision}, expected_revision: revision},
         _known_good
       ),
       do: :ok

  defp coherent_candidate_revision(
         %{previous: nil, expected_revision: nil},
         nil
       ),
       do: :ok

  defp coherent_candidate_revision(
         %{previous: nil, expected_revision: revision},
         %{revision: revision}
       ),
       do: :ok

  defp coherent_candidate_revision(_attempt, _known_good), do: {:error, :corrupt}

  defp coherent_candidate_versions(%{status: :applied, version: version}, %{version: version}),
    do: :ok

  defp coherent_candidate_versions(%{version: version, previous: nil}, nil)
       when is_integer(version),
       do: :ok

  defp coherent_candidate_versions(
         %{version: version, previous: nil},
         %{version: known_version}
       )
       when known_version < version,
       do: :ok

  defp coherent_candidate_versions(
         %{version: version, previous: %{version: previous_version}},
         _known_good
       )
       when previous_version < version,
       do: :ok

  defp coherent_candidate_versions(_attempt, _known_good), do: {:error, :corrupt}

  defp coherent_attempt_state(
         %{
           status: :delivered,
           checkpoint: checkpoint,
           previous: nil,
           installed_revision: nil,
           failure: nil,
           rollback: nil
         },
         _snapshot
       )
       when checkpoint in [:staged, :before_validate],
       do: :ok

  defp coherent_attempt_state(
         %{
           status: :applying,
           checkpoint: :before_install,
           installed_revision: nil,
           failure: nil,
           rollback: nil
         },
         snapshot
       ),
       do: previous_matches_known_good(snapshot)

  defp coherent_attempt_state(
         %{
           status: :applying,
           checkpoint: :before_activate,
           installed_revision: revision,
           failure: nil,
           rollback: nil
         },
         snapshot
       )
       when is_binary(revision),
       do: previous_matches_known_good(snapshot)

  defp coherent_attempt_state(
         %{
           status: :applying,
           checkpoint: checkpoint,
           previous: previous,
           failure: %{phase: :apply, reason: trigger},
           rollback: %{trigger_reason: trigger, status: checkpoint}
         },
         %{runtime_status: :unknown, known_good: known_good}
       )
       when checkpoint in [:before_restore, :before_reactivate] and not is_nil(previous) and
              previous == known_good,
       do: :ok

  defp coherent_attempt_state(
         %{status: :applying, checkpoint: :unknown} = attempt,
         %{runtime_status: :unknown} = snapshot
       ),
       do: coherent_unknown_attempt(attempt, snapshot)

  defp coherent_attempt_state(
         %{
           status: :applied,
           checkpoint: :complete,
           installed_revision: revision,
           failure: nil,
           rollback: nil
         } = attempt,
         %{runtime_status: :known, known_good: known_good}
       )
       when is_binary(revision) do
    if known_good == %{version: attempt.version, digest: attempt.digest, revision: revision},
      do: previous_matches_expected(attempt),
      else: {:error, :corrupt}
  end

  defp coherent_attempt_state(
         %{
           status: :failed,
           checkpoint: :complete,
           previous: nil,
           installed_revision: nil,
           failure: %{phase: :validation},
           rollback: nil
         },
         snapshot
       ),
       do: runtime_matches_known_good(snapshot)

  defp coherent_attempt_state(
         %{
           status: :failed,
           checkpoint: :complete,
           previous: nil,
           failure: %{phase: :apply},
           rollback: nil
         },
         %{runtime_status: :unknown, known_good: nil}
       ),
       do: :ok

  defp coherent_attempt_state(
         %{
           status: :failed,
           checkpoint: :complete,
           previous: previous,
           failure: %{phase: :apply, reason: trigger},
           rollback: %{
             trigger_reason: trigger,
             status: :succeeded,
             succeeded: true,
             restored_version: restored_version,
             restored_revision: restored_revision,
             reason: nil
           }
         },
         %{runtime_status: :known, known_good: previous}
       )
       when not is_nil(previous) do
    if restored_version == previous.version and restored_revision == previous.revision,
      do: :ok,
      else: {:error, :corrupt}
  end

  defp coherent_attempt_state(
         %{
           status: :failed,
           checkpoint: :complete,
           previous: previous,
           failure: %{phase: :rollback, reason: reason},
           rollback: %{
             status: :failed,
             succeeded: false,
             restored_version: nil,
             restored_revision: nil,
             reason: reason
           }
         },
         %{runtime_status: :unknown, known_good: previous}
       )
       when not is_nil(previous),
       do: :ok

  defp coherent_attempt_state(_attempt, _snapshot), do: {:error, :corrupt}

  defp coherent_unknown_attempt(
         %{
           previous: previous,
           installed_revision: installed,
           failure: failure,
           rollback: rollback
         },
         snapshot
       ) do
    cond do
      is_nil(failure) and is_nil(rollback) and is_nil(installed) ->
        previous_matches_known_good(snapshot)

      is_nil(failure) and is_nil(rollback) and is_binary(installed) ->
        previous_matches_known_good(snapshot)

      match?(
        %{phase: :apply},
        failure
      ) and not is_nil(previous) and previous == snapshot.known_good and
          match?(%{status: status} when status in [:before_restore, :before_reactivate], rollback) ->
        :ok

      true ->
        {:error, :corrupt}
    end
  end

  defp previous_matches_known_good(%{attempt: %{previous: previous}, known_good: known_good}) do
    if previous == known_good, do: :ok, else: {:error, :corrupt}
  end

  defp previous_matches_expected(%{previous: nil, expected_revision: nil}), do: :ok

  defp previous_matches_expected(%{previous: previous, expected_revision: revision})
       when not is_nil(previous) and previous.revision == revision,
       do: :ok

  defp previous_matches_expected(_attempt), do: {:error, :corrupt}

  defp runtime_matches_known_good(%{runtime_status: :known, known_good: known_good})
       when not is_nil(known_good),
       do: :ok

  defp runtime_matches_known_good(%{runtime_status: :unconfigured, known_good: nil}), do: :ok
  defp runtime_matches_known_good(_snapshot), do: {:error, :corrupt}

  defp coherent_outbox(%{attempt: nil, outbox: []}), do: :ok
  defp coherent_outbox(%{attempt: nil}), do: {:error, :corrupt}

  defp coherent_outbox(%{attempt: attempt, outbox: outbox, target_id: server_id}) do
    expected_states = expected_publication_states(attempt)
    actual_states = Enum.map(outbox, & &1.message.state)

    with true <- suffix?(expected_states, actual_states),
         true <- Enum.all?(outbox, &coherent_message?(&1.message, attempt, server_id)) do
      :ok
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp expected_publication_states(%{status: :delivered}), do: [:delivered]
  defp expected_publication_states(%{status: :applying}), do: [:delivered, :applying]
  defp expected_publication_states(%{status: :applied}), do: [:delivered, :applying, :applied]

  defp expected_publication_states(%{status: :failed, failure: %{phase: :validation}}),
    do: [:delivered, :failed]

  defp expected_publication_states(%{status: :failed}),
    do: [:delivered, :applying, :failed]

  defp suffix?(expected, actual) do
    length(actual) <= length(expected) and
      Enum.take(expected, -length(actual)) == actual
  end

  defp coherent_message?(message, attempt, server_id) do
    base =
      message.target_type == :server and message.target_id == server_id and
        message.operation == attempt.operation and message.version == attempt.version and
        message.digest == attempt.digest and valid_utc?(message.observed_at)

    base and message_fields_match?(message, attempt)
  end

  defp message_fields_match?(
         %ConfigState{
           state: :delivered,
           applied_revision: nil,
           previous_version: nil,
           previous_revision: nil,
           failure: nil,
           rollback: nil
         },
         _attempt
       ),
       do: true

  defp message_fields_match?(
         %ConfigState{
           state: :applying,
           applied_revision: nil,
           failure: nil,
           rollback: nil
         } = message,
         attempt
       ),
       do: previous_fields?(message, attempt.previous)

  defp message_fields_match?(
         %ConfigState{
           state: :applied,
           applied_revision: revision,
           failure: nil,
           rollback: nil
         } = message,
         attempt
       ),
       do: revision == attempt.installed_revision and previous_fields?(message, attempt.previous)

  defp message_fields_match?(%ConfigState{state: :failed} = message, attempt) do
    message.applied_revision == nil and message.failure == encode_failure(attempt.failure) and
      message.rollback == publication_rollback(attempt, :failed) and
      failed_previous_fields?(message, attempt)
  end

  defp message_fields_match?(_message, _attempt), do: false

  defp failed_previous_fields?(message, %{failure: %{phase: :validation}}),
    do: previous_fields?(message, nil)

  defp failed_previous_fields?(message, attempt),
    do: previous_fields?(message, attempt.previous)

  defp previous_fields?(message, nil),
    do: is_nil(message.previous_version) and is_nil(message.previous_revision)

  defp previous_fields?(message, previous),
    do:
      message.previous_version == previous.version and
        message.previous_revision == previous.revision

  defp coherent_sequences(published, next_sequence, outbox) do
    expected_sequences =
      case outbox do
        [] -> []
        _entries -> Enum.to_list((published + 1)..(published + length(outbox)))
      end

    if Enum.map(outbox, & &1.sequence) == expected_sequences and
         next_sequence == published + length(outbox) + 1,
       do: :ok,
       else: {:error, :corrupt}
  end

  defp coherent_rollback_fields(status, nil, nil, nil, nil)
       when status in [:before_restore, :before_reactivate],
       do: :ok

  defp coherent_rollback_fields(:succeeded, true, restored_version, restored_revision, nil)
       when is_integer(restored_version) and is_binary(restored_revision),
       do: :ok

  defp coherent_rollback_fields(:failed, false, nil, nil, reason) when is_binary(reason),
    do: :ok

  defp coherent_rollback_fields(_status, _succeeded, _version, _revision, _reason),
    do: {:error, :corrupt}

  defp encode_snapshot(snapshot) do
    %{
      "schema_version" => @schema_version,
      "target_type" => "server",
      "target_id" => snapshot.target_id,
      "known_good" => encode_known_good(snapshot.known_good),
      "runtime_status" => Atom.to_string(snapshot.runtime_status),
      "attempt" => encode_attempt(snapshot.attempt),
      "observed_at" => encode_datetime(snapshot.observed_at),
      "published_through" => snapshot.published_through,
      "next_publication_sequence" => snapshot.next_publication_sequence,
      "outbox" => Enum.map(snapshot.outbox, &encode_outbox_entry/1)
    }
  end

  defp encode_known_good(nil), do: nil

  defp encode_known_good(value) do
    %{
      "version" => value.version,
      "digest" => value.digest,
      "revision" => value.revision
    }
  end

  defp encode_attempt(nil), do: nil

  defp encode_attempt(value) do
    %{
      "version" => value.version,
      "digest" => value.digest,
      "operation" => value.operation,
      "profile" => value.profile,
      "expected_revision" => value.expected_revision,
      "status" => Atom.to_string(value.status),
      "checkpoint" => Atom.to_string(value.checkpoint),
      "previous" => encode_known_good(value.previous),
      "installed_revision" => value.installed_revision,
      "failure" => encode_failure(value.failure),
      "rollback" => encode_rollback(value.rollback)
    }
  end

  defp encode_failure(nil), do: nil

  defp encode_failure(value),
    do: %{"phase" => Atom.to_string(value.phase), "reason" => value.reason}

  defp encode_rollback(nil), do: nil

  defp encode_rollback(value) do
    %{
      "trigger_reason" => value.trigger_reason,
      "status" => Atom.to_string(value.status),
      "succeeded" => value.succeeded,
      "restored_version" => value.restored_version,
      "restored_revision" => value.restored_revision,
      "reason" => value.reason
    }
  end

  defp encode_outbox_entry(value),
    do: %{"sequence" => value.sequence, "encoded_message" => value.encoded_message}

  defp initial_snapshot(config) do
    %{
      schema_version: @schema_version,
      target_type: :server,
      target_id: config.server_id,
      known_good: nil,
      runtime_status: :unconfigured,
      attempt: nil,
      observed_at: nil,
      published_through: 0,
      next_publication_sequence: 1,
      outbox: []
    }
  end

  defp build_config(opts) do
    allowed = [
      :name,
      :data_dir,
      :server_id,
      :profile,
      :config_store,
      :clock,
      :max_bytes,
      :storage_opts
    ]

    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
         {:ok, data_dir} <- absolute_data_dir(Keyword.get(opts, :data_dir)),
         {:ok, server_id} <- server_id(Keyword.get(opts, :server_id)),
         {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, config_store} <-
           config_store(Keyword.get(opts, :config_store, ConfigStore)),
         clock when is_function(clock, 0) <- Keyword.get(opts, :clock, &DateTime.utc_now/0),
         {:ok, storage_opts} <- storage_options(opts) do
      {:ok,
       %{
         data_dir: data_dir,
         server_id: server_id,
         profile: profile,
         config_store: config_store,
         clock: clock,
         storage_opts: storage_opts
       }}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp storage_options(opts) do
    storage_opts = Keyword.get(opts, :storage_opts, [])

    with true <- Keyword.keyword?(storage_opts),
         {:ok, storage_opts} <- maybe_put_max_bytes(storage_opts, Keyword.fetch(opts, :max_bytes)) do
      {:ok, storage_opts}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp maybe_put_max_bytes(storage_opts, :error), do: {:ok, storage_opts}

  defp maybe_put_max_bytes(storage_opts, {:ok, max_bytes})
       when is_integer(max_bytes) and max_bytes > 0,
       do: {:ok, Keyword.put(storage_opts, :max_bytes, max_bytes)}

  defp maybe_put_max_bytes(_storage_opts, _max_bytes), do: {:error, :invalid}

  defp config_store(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> {:ok, server}
      _missing -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)

    if Path.type(value) == :absolute and expanded == value,
      do: {:ok, value},
      else: {:error, :invalid}
  end

  defp absolute_data_dir(_value), do: {:error, :invalid}

  defp nonempty_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> {:error, :invalid}
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
      _invalid -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  end

  defp profile(value) when is_atom(value), do: profile(Atom.to_string(value))
  defp profile(value), do: nonempty_id(value)

  defp config_operation(name, payload) do
    with {:ok, %Operation{target_type: :server, kind: :config} = operation} <-
           Operation.lookup(name),
         {:ok, _payload} <- Operation.validate_payload(operation, payload) do
      {:ok, name}
    else
      _invalid -> invalid()
    end
  end

  defp config_operation_name(name) do
    with {:ok, %Operation{target_type: :server, kind: :config}} <- Operation.lookup(name) do
      {:ok, name}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp version(value) when is_integer(value) and value >= 1 and value <= @max_version,
    do: {:ok, value}

  defp version(_value), do: {:error, :invalid}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid}
  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative_integer(_value), do: {:error, :invalid}
  defp optional_version(nil), do: {:ok, nil}
  defp optional_version(value), do: version(value)
  defp optional_digest(nil), do: {:ok, nil}
  defp optional_digest(value), do: Digest.validate(value)
  defp optional_boolean(nil), do: {:ok, nil}
  defp optional_boolean(value) when is_boolean(value), do: {:ok, value}
  defp optional_boolean(_value), do: {:error, :invalid}

  defp reason(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp optional_reason(nil), do: {:ok, nil}
  defp optional_reason(value), do: reason(value)

  defp now(config) do
    case config.clock.() do
      %DateTime{utc_offset: 0, std_offset: 0} = value -> {:ok, value}
      _invalid -> internal()
    end
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp decode_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z"),
         true <- DateTime.to_iso8601(datetime) == value do
      {:ok, datetime}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp decode_datetime(_value), do: {:error, :invalid}
  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: DateTime.to_iso8601(value)
  defp valid_utc?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp valid_utc?(_value), do: false

  defp decode_runtime_status(value), do: decode_enum(value, @runtime_statuses)
  defp decode_attempt_status(value), do: decode_enum(value, @attempt_statuses)
  defp decode_checkpoint(value), do: decode_enum(value, @checkpoints)
  defp decode_failure_phase(value), do: decode_enum(value, @failure_phases)
  defp decode_rollback_status(value), do: decode_enum(value, @rollback_statuses)

  defp decode_enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid}
      decoded -> {:ok, decoded}
    end
  end

  defp decode_enum(_value, _allowed), do: {:error, :invalid}

  defp exact_attrs(event, attrs) do
    case Map.fetch(@event_attrs, event) do
      {:ok, keys} -> exact_atom_keys(attrs, keys)
      :error -> invalid()
    end
  end

  defp exact_atom_keys(attrs, keys) when is_map(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(keys), do: :ok, else: invalid()
  end

  defp exact_atom_keys(_attrs, _keys), do: invalid()

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp ensure_operation_path(%{config: config, persisted?: persisted?}),
    do: ensure_write_path(config, persisted?)

  defp ensure_write_path(config, false) do
    with :ok <- ensure_owned_path(config) do
      case File.lstat(apply_state_path(config)) do
        {:error, :enoent} -> :ok
        _existing_or_error -> {:error, :path}
      end
    end
  end

  defp ensure_write_path(config, true) do
    with :ok <- ensure_owned_path(config),
         {:ok, _identity} <- regular_file_identity(apply_state_path(config)) do
      :ok
    else
      _unsafe -> {:error, :path}
    end
  end

  defp ensure_owned_path(config) do
    [config.data_dir, server_directory(config)]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_owned_directory(path) do
        :ok -> {:cont, :ok}
        _unsafe -> {:halt, {:error, :path}}
      end
    end)
  end

  defp ensure_owned_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> validate_directory(path)
          {:error, :eexist} -> validate_directory(path)
          _error -> {:error, :path}
        end

      _unsafe ->
        {:error, :path}
    end
  rescue
    _exception -> {:error, :path}
  catch
    _kind, _reason -> {:error, :path}
  end

  defp validate_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _unsafe -> {:error, :path}
    end
  end

  defp final_file_status(path) do
    case regular_file_identity(path) do
      {:ok, identity} ->
        {:regular, identity}

      {:error, :missing} ->
        :missing

      {:error, :unsafe} ->
        :unsafe
    end
  end

  defp regular_file_identity(path) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: major_device,
         minor_device: minor_device,
         inode: inode
       }} ->
        {:ok, {:regular, major_device, minor_device, inode}}

      {:error, :enoent} ->
        {:error, :missing}

      _unsafe ->
        {:error, :unsafe}
    end
  rescue
    _exception -> {:error, :unsafe}
  catch
    _kind, _reason -> {:error, :unsafe}
  end

  defp server_directory(config), do: Path.join(config.data_dir, "server")
  defp apply_state_path(config), do: Path.join(server_directory(config), "apply_state.json")

  defp invalid,
    do: {:error, Error.new(:invalid, "invalid config apply state", %{})}

  defp conflict,
    do: {:error, Error.new(:conflict, "config apply state conflicts", %{})}

  defp internal,
    do: {:error, Error.new(:internal, "config apply persistence failed", %{})}
end
