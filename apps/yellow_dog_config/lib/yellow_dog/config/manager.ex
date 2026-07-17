defmodule YellowDog.Config.Manager do
  @moduledoc """
  Serialized durable owner for service-scoped configuration changes.

  The Manager owns full-file validation, immutable local history, atomic
  installation, Config Agent replacement, activation, and compensation.
  """

  use GenServer

  alias YellowDog.Config
  alias YellowDog.Config.Manager.Storage
  alias YellowDog.Config.Schema
  alias YellowDog.Config.TomlHelpers
  alias YellowDog.Config.Writer

  @max_reason_bytes 160
  @max_validation_errors 100
  @service_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @setting_pattern ~r/\A[a-z][a-z0-9_]{0,127}\z/
  @sensitive_fragments ~w(
    authorization certificate credential file key material password path
    private secret socket token
  )

  @type result(value) :: {:ok, value} | {:error, atom()} | {:error, {atom(), value}}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec effective(String.t() | atom(), keyword()) :: result(map())
  def effective(service, opts \\ []), do: call(opts, {:read, :effective, service})

  @spec source(String.t() | atom(), keyword()) :: result(map())
  def source(service, opts \\ []), do: call(opts, {:read, :source, service})

  @spec revision(String.t() | atom(), keyword()) :: result(map())
  def revision(service, opts \\ []), do: call(opts, {:read, :revision, service})

  @spec validation(String.t() | atom(), keyword()) :: result(map())
  def validation(service, opts \\ []), do: call(opts, {:validation, service})

  @spec update(String.t() | atom(), [map()], keyword()) :: result(map())
  def update(service, entries, opts \\ []),
    do: call(opts, {:update, service, entries, Keyword.get(opts, :expected_revision)})

  @spec apply(String.t() | atom(), keyword()) :: result(map())
  def apply(service, opts \\ []),
    do: call(opts, {:apply, service, Keyword.get(opts, :expected_revision)})

  @spec rollback(String.t() | atom(), String.t(), keyword()) :: result(map())
  def rollback(service, target_revision, opts \\ []),
    do: call(opts, {:rollback, service, target_revision, Keyword.get(opts, :expected_revision)})

  @spec reload(String.t() | atom(), keyword()) :: {:error, :unsupported}
  def reload(_service, _opts \\ []), do: {:error, :unsupported}

  @impl true
  def init(opts) do
    configured = Application.get_env(:yellow_dog_config, __MODULE__, [])

    path =
      opts
      |> Keyword.get(:config_path, Keyword.get(configured, :config_path))
      |> case do
        nil -> Application.get_env(:yellow_dog, :config_file_path)
        configured_path -> configured_path
      end

    state = %{
      path: canonical_path(path),
      history_dir: history_dir(path, opts, configured),
      config_agent: Keyword.get(opts, :config_agent, Config),
      activation_owners:
        Keyword.get(
          opts,
          :activation_owners,
          Keyword.get(configured, :activation_owners, %{})
        ),
      file_ops: Keyword.get(opts, :file_ops, Keyword.get(configured, :file_ops, Storage.FileOps))
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:validation, service}, _from, state) do
    reply =
      with {:ok, service} <- normalize_service(service) do
        validation_document(service, state)
      end

    {:reply, reply, state}
  end

  def handle_call({:read, kind, service}, _from, state) do
    reply =
      with {:ok, service} <- normalize_service(service),
           {:ok, target} <- load_target(state) do
        read_document(kind, service, target, state)
      else
        {:error, {:schema_invalid, _errors}} -> {:error, :invalid_config}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:update, service, entries, expected_revision}, _from, state) do
    reply =
      with {:ok, service} <- normalize_service(service),
           {:ok, owner} <- activation_owner(state, service),
           {:ok, updates} <- decode_entries(entries) do
        path_transaction(state, fn ->
          with {:ok, target} <- load_mutation_target(state),
               {:ok, prior_agent} <- agent_get(state.config_agent),
               {:ok, previous} <- ensure_baseline(service, target, state),
               :ok <- check_expected(service, target, expected_revision),
               candidate <- update_service(target.merged, service, updates) do
            mutate(service, "update", candidate, target, prior_agent, previous, owner, state)
          end
        end)
      end

    {:reply, reply, state}
  end

  def handle_call({:apply, service, expected_revision}, _from, state) do
    reply =
      with {:ok, service} <- normalize_service(service),
           {:ok, owner} <- activation_owner(state, service) do
        path_transaction(state, fn ->
          with {:ok, target} <- load_mutation_target(state),
               {:ok, prior_agent} <- agent_get(state.config_agent),
               {:ok, previous} <- ensure_baseline(service, target, state),
               :ok <- check_expected(service, target, expected_revision) do
            apply_current(service, target, prior_agent, previous, owner, state)
          end
        end)
      end

    {:reply, reply, state}
  end

  def handle_call({:rollback, service, target_revision, expected_revision}, _from, state) do
    reply =
      with {:ok, service} <- normalize_service(service),
           {:ok, owner} <- activation_owner(state, service) do
        path_transaction(state, fn ->
          with {:ok, target} <- load_mutation_target(state),
               {:ok, prior_agent} <- agent_get(state.config_agent),
               {:ok, previous} <- ensure_baseline(service, target, state),
               :ok <- check_expected(service, target, expected_revision),
               {:ok, rollback_record} <- find_revision(service, target_revision, state),
               {:ok, rollback_config} <- decode_snapshot(rollback_record.snapshot),
               service_config when is_map(service_config) <-
                 Map.get(rollback_config, service),
               candidate <- Map.put(target.merged, service, service_config) do
            mutate(service, "rollback", candidate, target, prior_agent, previous, owner, state)
          else
            nil -> {:error, :stale_revision}
            {:error, :not_found} -> {:error, :stale_revision}
            {:error, _reason} = error -> error
          end
        end)
      else
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  defp call(opts, message) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp mutate(service, operation, candidate, target, prior_agent, previous, owner, state) do
    with {:ok, candidate_bytes} <- Writer.encode_config(candidate, validate: false),
         {:ok, record} <-
           create_record(service, operation, candidate, candidate_bytes, previous, state) do
      case Schema.validate(candidate) do
        :ok ->
          install_and_activate(
            service,
            candidate_bytes,
            target,
            prior_agent,
            record,
            previous,
            owner,
            state
          )

        {:error, errors} ->
          failed =
            failed_state(
              record,
              nil,
              "validation",
              validation_reason(errors),
              nil
            )

          persist_and_return(record, failed, state)
      end
    else
      {:error, {:validation_failed, _errors}} -> {:error, :invalid_config}
      {:error, _reason} -> {:error, :storage_failed}
    end
  end

  defp install_and_activate(
         service,
         candidate_bytes,
         target,
         prior_agent,
         record,
         previous,
         owner,
         state
       ) do
    with :ok <- append_state(record, delivered_state(record, previous), state),
         :ok <- Storage.replace(state.path, candidate_bytes, state.file_ops),
         {:ok, installed} <- load_target(state),
         true <- installed.raw == candidate_bytes,
         :ok <- agent_replace(state.config_agent, installed.merged),
         :ok <- append_state(record, applying_state(record, previous), state),
         :ok <- activate(owner, service, service_config(installed.merged, service)),
         applied = applied_state(record, previous),
         :ok <- append_state(record, applied, state) do
      {:ok, applied}
    else
      false ->
        compensate(
          service,
          target,
          prior_agent,
          record,
          previous,
          owner,
          "installed config validation failed",
          state
        )

      {:error, :invalid_config} ->
        compensate(
          service,
          target,
          prior_agent,
          record,
          previous,
          owner,
          "installed config validation failed",
          state
        )

      {:error, reason} ->
        compensate(
          service,
          target,
          prior_agent,
          record,
          previous,
          owner,
          mutation_failure_reason(reason),
          state
        )
    end
  end

  defp apply_current(service, target, prior_agent, previous, owner, state) do
    case create_record(service, "apply", target.merged, target.raw, previous, state) do
      {:ok, record} ->
        with :ok <- agent_replace(state.config_agent, target.merged),
             :ok <- append_state(record, applying_state(record, previous), state),
             :ok <- activate(owner, service, service_config(target.merged, service)),
             applied = applied_state(record, previous),
             :ok <- append_state(record, applied, state) do
          {:ok, applied}
        else
          {:error, reason} ->
            compensate(
              service,
              target,
              prior_agent,
              record,
              previous,
              owner,
              mutation_failure_reason(reason),
              state
            )
        end

      {:error, _reason} ->
        {:error, :storage_failed}
    end
  end

  defp compensate(
         service,
         target,
         prior_agent,
         record,
         previous,
         owner,
         failure_reason,
         state
       ) do
    results = [
      restore_bytes(target.raw, state),
      agent_replace(state.config_agent, prior_agent),
      activate(owner, service, service_config(prior_agent, service))
    ]

    if Enum.all?(results, &(&1 == :ok)) do
      rollback = %{
        "succeeded" => true,
        "restored_version" => previous.version,
        "restored_revision" => previous.digest,
        "reason" => nil
      }

      failed = failed_state(record, previous, "apply", failure_reason, rollback)
      persist_and_return(record, failed, state)
    else
      rollback = %{
        "succeeded" => false,
        "restored_version" => nil,
        "restored_revision" => nil,
        "reason" => rollback_failure_reason(results)
      }

      failed = failed_state(record, previous, "rollback", "rollback failed", rollback)

      case append_state(record, failed, state) do
        :ok -> {:error, {:rollback_failed, failed}}
        {:error, _reason} -> {:error, :rollback_failed}
      end
    end
  end

  defp restore_bytes(bytes, state) do
    with :ok <- Storage.replace(state.path, bytes, state.file_ops),
         {:ok, restored} <- Storage.read(state.path, state.file_ops),
         true <- restored == bytes do
      :ok
    else
      _failure -> {:error, :byte_restore_failed}
    end
  end

  defp validation_document(service, state) do
    case load_target(state) do
      {:ok, _target} ->
        {:ok, %{"service" => service, "valid" => true, "errors" => []}}

      {:error, {:schema_invalid, errors}} ->
        {:ok,
         %{
           "service" => service,
           "valid" => false,
           "errors" => validation_errors(errors)
         }}

      {:error, :invalid_config} ->
        {:ok,
         %{
           "service" => service,
           "valid" => false,
           "errors" => [%{"field" => "config", "message" => "invalid TOML"}]
         }}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp read_document(:effective, service, target, _state) do
    entries =
      target.merged
      |> Map.get(service, %{})
      |> encode_entries()

    {:ok, %{"service" => service, "entries" => entries}}
  end

  defp read_document(:revision, service, target, _state) do
    {:ok, %{"service" => service, "revision" => digest(Map.get(target.merged, service, %{}))}}
  end

  defp read_document(:source, service, target, state) do
    source =
      cond do
        managed_revision?(service, digest(Map.get(target.merged, service, %{})), state) ->
          "managed"

        Map.has_key?(target.parsed, service) ->
          "local"

        true ->
          "default"
      end

    {:ok, %{"service" => service, "source" => source}}
  end

  defp load_target(%{path: nil}), do: {:error, :unsupported}

  defp load_target(state) do
    with {:ok, raw} <- Storage.read(state.path, state.file_ops),
         {:ok, parsed} <- TomlHelpers.parse_toml(raw),
         merged = Schema.merge_defaults(parsed),
         :ok <- validate_schema(merged) do
      {:ok, %{raw: raw, parsed: parsed, merged: merged}}
    else
      {:error, {:toml_parse_error, _reason}} -> {:error, :invalid_config}
      {:error, :enoent} -> {:error, :invalid_config}
      {:error, _reason} = error -> error
    end
  end

  defp validate_schema(config) do
    case Schema.validate(config) do
      :ok -> :ok
      {:error, errors} -> {:error, {:schema_invalid, errors}}
    end
  end

  defp load_mutation_target(state) do
    case load_target(state) do
      {:error, {:schema_invalid, _errors}} -> {:error, :invalid_config}
      result -> result
    end
  end

  defp ensure_baseline(service, target, state) do
    case records(service, state) do
      {:ok, []} ->
        record = %{
          service: service,
          version: 1,
          digest: digest(Map.get(target.merged, service, %{})),
          operation: "baseline",
          previous_version: nil,
          previous_revision: nil,
          snapshot: target.raw
        }

        with :ok <- write_record(record, state),
             baseline = applied_state(record, nil),
             :ok <- append_state(record, baseline, state) do
          {:ok, history_position(record, record)}
        end

      {:ok, records} ->
        latest = List.last(records)

        case records |> Enum.reverse() |> Enum.find(&record_applied?(&1, state)) do
          nil -> {:error, :invalid_history}
          applied -> {:ok, history_position(latest, applied)}
        end

      {:error, _reason} ->
        {:error, :storage_failed}
    end
  end

  defp create_record(service, operation, candidate, snapshot, previous, state) do
    record = %{
      service: service,
      version: previous.next_version,
      digest: digest(Map.get(candidate, service, %{})),
      operation: operation,
      previous_version: previous.version,
      previous_revision: previous.digest,
      snapshot: snapshot
    }

    with :ok <- write_record(record, state), do: {:ok, record}
  end

  defp write_record(record, state) do
    Storage.write_term(record_path(record, state), record, state.file_ops)
  end

  defp records(service, state) do
    directory = service_history_dir(service, state)

    case Storage.list(directory, state.file_ops) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.match?(&1, ~r/\Av[1-9][0-9]*\.term\z/))
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, records} ->
          path = Path.join(directory, name)

          case Storage.read_term(path, state.file_ops) do
            {:ok, record} ->
              if valid_record?(record, service) and
                   name == "v#{record.version}.term" do
                {:cont, {:ok, [record | records]}}
              else
                {:halt, {:error, :invalid_history}}
              end

            {:error, _reason} ->
              {:halt, {:error, :invalid_history}}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.sort_by(records, & &1.version)}
          error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, _reason} ->
        {:error, :history_unavailable}
    end
  end

  defp find_revision(service, revision, state) when is_binary(revision) do
    with {:ok, records} <- records(service, state) do
      case Enum.find(records, &(&1.digest == revision and record_applied?(&1, state))) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end
  end

  defp find_revision(_service, _revision, _state), do: {:error, :not_found}

  defp managed_revision?(service, revision, state) do
    with {:ok, records} <- records(service, state) do
      Enum.any?(records, fn record ->
        record.operation in ["update", "rollback"] and record.digest == revision and
          record_applied?(record, state)
      end)
    else
      _error -> false
    end
  end

  defp record_applied?(record, state) do
    case latest_state(record, state) do
      {:ok, %{"state" => "applied"}} -> true
      _other -> false
    end
  end

  defp latest_state(record, state) do
    prefix = "v#{record.version}-e"

    with {:ok, names} <- Storage.list(service_history_dir(record.service, state), state.file_ops) do
      names
      |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".term")))
      |> Enum.sort()
      |> List.last()
      |> case do
        nil ->
          {:error, :not_found}

        name ->
          state_path = Path.join(service_history_dir(record.service, state), name)
          Storage.read_term(state_path, state.file_ops)
      end
    end
  end

  defp append_state(record, lifecycle, state) do
    sequence = next_state_sequence(record, state)
    path = lifecycle_path(record, sequence, state)
    Storage.write_term(path, lifecycle, state.file_ops)
  end

  defp next_state_sequence(record, state) do
    prefix = "v#{record.version}-e"

    case Storage.list(service_history_dir(record.service, state), state.file_ops) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".term")))
        |> length()
        |> Kernel.+(1)

      {:error, _reason} ->
        1
    end
  end

  defp persist_and_return(record, lifecycle, state) do
    case append_state(record, lifecycle, state) do
      :ok -> {:ok, lifecycle}
      {:error, _reason} -> {:error, :storage_failed}
    end
  end

  defp delivered_state(record, previous),
    do: state_document(record, previous, "delivered", nil, nil, nil)

  defp applying_state(record, previous),
    do: state_document(record, previous, "applying", nil, nil, nil)

  defp applied_state(record, previous),
    do: state_document(record, previous, "applied", record.digest, nil, nil)

  defp failed_state(record, previous, phase, reason, rollback),
    do:
      state_document(
        record,
        previous,
        "failed",
        nil,
        %{"phase" => phase, "reason" => bounded(reason)},
        rollback
      )

  defp state_document(record, previous, state, applied_revision, failure, rollback) do
    %{
      "state" => state,
      "version" => record.version,
      "digest" => record.digest,
      "applied_revision" => applied_revision,
      "previous_version" => previous && previous.version,
      "previous_revision" => previous && previous.digest,
      "failure" => failure,
      "rollback" => rollback
    }
  end

  defp check_expected(_service, _target, nil), do: :ok

  defp check_expected(service, target, expected_revision) do
    current = digest(Map.get(target.merged, service, %{}))
    if expected_revision == current, do: :ok, else: {:error, :stale_revision}
  end

  defp update_service(config, service, updates) do
    service_config = Map.get(config, service, %{})
    Map.put(config, service, apply_updates(service_config, updates))
  end

  defp apply_updates(config, updates) do
    Enum.reduce(updates, config, fn
      {key, :delete}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp decode_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{"key" => key, "value" => value}, {:ok, updates} ->
        with true <- safe_setting_key?(key),
             {:ok, decoded} <- decode_value(value) do
          {:cont, {:ok, Map.put(updates, key, decoded)}}
        else
          _invalid -> {:halt, {:error, :invalid_entries}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_entries}}
    end)
  end

  defp decode_entries(_entries), do: {:error, :invalid_entries}

  defp decode_value(%{"type" => "string", "value" => value}) when is_binary(value) do
    if unsafe_string?(value), do: {:error, :invalid_value}, else: {:ok, value}
  end

  defp decode_value(%{"type" => "integer", "value" => value}) when is_integer(value),
    do: {:ok, value}

  defp decode_value(%{"type" => "boolean", "value" => value}) when is_boolean(value),
    do: {:ok, value}

  defp decode_value(%{"type" => "null", "value" => nil}), do: {:ok, :delete}

  defp decode_value(%{"type" => "list", "items" => items}) when is_list(items) do
    if Enum.all?(items, &setting_scalar?/1) and not Enum.any?(items, &unsafe_scalar?/1) do
      {:ok, items}
    else
      {:error, :invalid_value}
    end
  end

  defp decode_value(%{"type" => "object", "entries" => entries}) when is_list(entries),
    do: decode_object_entries(entries)

  defp decode_value(_value), do: {:error, :invalid_value}

  defp decode_object_entries(entries) do
    with {:ok, values} <- decode_entries(entries) do
      {:ok,
       values
       |> Enum.reject(fn {_key, value} -> value == :delete end)
       |> Map.new()}
    end
  end

  defp setting_scalar?(value),
    do: is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value)

  defp encode_entries(config) when is_map(config) do
    config
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      encoded = if sensitive_key?(key), do: redacted_value(value), else: encode_value(value)
      %{"key" => key, "value" => encoded}
    end)
  end

  defp encode_value(value) when is_binary(value) do
    if unsafe_string?(value),
      do: redacted_value(value),
      else: %{"type" => "string", "value" => value}
  end

  defp encode_value(value) when is_integer(value), do: %{"type" => "integer", "value" => value}
  defp encode_value(value) when is_boolean(value), do: %{"type" => "boolean", "value" => value}
  defp encode_value(nil), do: %{"type" => "null", "value" => nil}

  defp encode_value(value) when is_list(value) do
    if Enum.all?(value, &setting_scalar?/1) and not Enum.any?(value, &unsafe_scalar?/1) do
      %{"type" => "list", "items" => value}
    else
      redacted_value(value)
    end
  end

  defp encode_value(value) when is_map(value),
    do: %{"type" => "object", "entries" => encode_entries(value)}

  defp encode_value(value), do: %{"type" => "string", "value" => bounded(inspect(value))}

  defp redacted_value(_value), do: %{"type" => "string", "value" => "[REDACTED]"}

  defp activation_owner(state, service) do
    owner =
      Map.get(state.activation_owners, service) ||
        Map.get(state.activation_owners, existing_atom(service))

    case owner do
      nil -> {:error, :unsupported}
      owner -> {:ok, owner}
    end
  end

  defp activate({module, context}, service, config) do
    safe_owner_call(module, :activate, [service, config, context])
  end

  defp activate(module, service, config) when is_atom(module) do
    safe_owner_call(module, :activate, [service, config])
  end

  defp safe_owner_call(module, function, arguments) do
    case apply(module, function, arguments) do
      :ok -> :ok
      {:error, _reason} -> {:error, :activation_failed}
      _other -> {:error, :activation_failed}
    end
  rescue
    _exception -> {:error, :activation_failed}
  catch
    _kind, _reason -> {:error, :activation_failed}
  end

  defp agent_get(agent) do
    {:ok, Agent.get(agent, & &1)}
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp agent_replace(agent, config) do
    Agent.update(agent, fn _state -> config end)
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp decode_snapshot(snapshot) do
    with {:ok, parsed} <- TomlHelpers.parse_toml(snapshot),
         merged = Schema.merge_defaults(parsed),
         :ok <- Schema.validate(merged) do
      {:ok, merged}
    else
      _failure -> {:error, :invalid_history}
    end
  end

  defp valid_record?(
         %{
           service: service,
           version: version,
           digest: digest,
           operation: operation,
           previous_version: previous_version,
           previous_revision: previous_revision,
           snapshot: snapshot
         },
         expected_service
       ) do
    service == expected_service and is_integer(version) and version > 0 and digest?(digest) and
      operation in ["baseline", "update", "apply", "rollback"] and is_binary(snapshot) and
      valid_previous?(operation, version, previous_version, previous_revision) and
      snapshot_digest(snapshot, service) == {:ok, digest}
  end

  defp valid_record?(_record, _service), do: false

  defp normalize_service(service) when is_atom(service),
    do: normalize_service(Atom.to_string(service))

  defp normalize_service(service) when is_binary(service) do
    if String.match?(service, @service_pattern),
      do: {:ok, service},
      else: {:error, :invalid_service}
  end

  defp normalize_service(_service), do: {:error, :invalid_service}

  defp safe_setting_key?(key) when is_binary(key) do
    String.match?(key, @setting_pattern) and not sensitive_key?(key)
  end

  defp safe_setting_key?(_key), do: false

  defp sensitive_key?(key) do
    normalized = String.downcase(to_string(key))
    Enum.any?(@sensitive_fragments, &String.contains?(normalized, &1))
  end

  defp service_config(config, service) do
    Map.get(config, service, Map.get(config, existing_atom(service), %{}))
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp unsafe_scalar?(value) when is_binary(value), do: unsafe_string?(value)
  defp unsafe_scalar?(_value), do: false

  defp unsafe_string?(value) do
    Regex.match?(~r/\p{C}/u, value) or
      String.contains?(String.upcase(value), "-----BEGIN ") or
      local_path?(value)
  end

  defp local_path?(value) do
    not String.starts_with?(value, ["http://", "https://"]) and
      (String.contains?(value, ["/", "\\"]) or
         Regex.match?(~r/\A[A-Za-z]:/, value) or value in [".", "..", "~"])
  end

  defp valid_previous?("baseline", 1, nil, nil), do: true

  defp valid_previous?(operation, version, previous_version, previous_revision)
       when operation in ["update", "apply", "rollback"] and is_integer(previous_version) and
              previous_version > 0 and previous_version < version,
       do: digest?(previous_revision)

  defp valid_previous?(_operation, _version, _previous_version, _previous_revision), do: false

  defp snapshot_digest(snapshot, service) do
    with {:ok, parsed} <- TomlHelpers.parse_toml(snapshot) do
      merged = Schema.merge_defaults(parsed)
      {:ok, digest(Map.get(merged, service, %{}))}
    else
      _failure -> {:error, :invalid_snapshot}
    end
  end

  defp digest(value) do
    encoded = :erlang.term_to_binary(value, [:deterministic])

    :crypto.hash(:sha256, encoded)
    |> Base.encode16(case: :lower)
  end

  defp digest?(digest), do: is_binary(digest) and String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp validation_errors(errors) do
    errors
    |> Enum.take(@max_validation_errors)
    |> Enum.map(fn {field, message} ->
      %{"field" => bounded(field), "message" => bounded(message)}
    end)
  end

  defp validation_reason([]), do: "invalid configuration"
  defp validation_reason([{field, _message} | _rest]), do: "invalid configuration at #{field}"

  defp mutation_failure_reason(:activation_failed), do: "activation failed"
  defp mutation_failure_reason(:agent_unavailable), do: "Agent replacement failed"
  defp mutation_failure_reason(:invalid_config), do: "installed config validation failed"
  defp mutation_failure_reason(:storage_failed), do: "history persistence failed"
  defp mutation_failure_reason(_reason), do: "durable install failed"

  defp rollback_failure_reason([:ok, :ok, {:error, _reason}]),
    do: "runtime reactivation failed"

  defp rollback_failure_reason([:ok, {:error, _reason}, _activation]),
    do: "Agent restore failed"

  defp rollback_failure_reason([{:error, _reason}, _agent, _activation]),
    do: "file restore failed"

  defp rollback_failure_reason(_results), do: "rollback failed"

  defp bounded(value) do
    value
    |> to_string()
    |> String.slice(0, @max_reason_bytes)
  end

  defp path_transaction(%{path: nil}, _function), do: {:error, :unsupported}

  defp path_transaction(state, function) do
    lock = {{__MODULE__, state.path}, self()}

    case :global.trans(lock, function) do
      :aborted -> {:error, :unavailable}
      result -> result
    end
  end

  defp history_position(latest, applied) do
    %{version: applied.version, digest: applied.digest, next_version: latest.version + 1}
  end

  defp record_path(record, state),
    do: Path.join(service_history_dir(record.service, state), "v#{record.version}.term")

  defp lifecycle_path(record, sequence, state) do
    name = "v#{record.version}-e#{String.pad_leading(Integer.to_string(sequence), 4, "0")}.term"
    Path.join(service_history_dir(record.service, state), name)
  end

  defp service_history_dir(service, state), do: Path.join(state.history_dir, service)

  defp canonical_path(path) when is_binary(path), do: Path.expand(path)
  defp canonical_path(_path), do: nil

  defp history_dir(path, opts, configured) do
    configured_history =
      Keyword.get(opts, :history_dir, Keyword.get(configured, :history_dir))

    cond do
      is_binary(configured_history) -> Path.expand(configured_history)
      is_binary(path) -> Path.expand(path <> ".history")
      true -> nil
    end
  end
end
