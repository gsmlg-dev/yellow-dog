defmodule YellowDog.Management.ConfigVersions do
  @moduledoc """
  Serializes durable configuration publication and lifecycle transitions.
  """

  use GenServer

  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.EventStore.Config
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Operation

  @max_version 9_223_372_036_854_775_807
  @lifecycle_keys Enum.sort([
                    "applied_version",
                    "counter",
                    "desired_version",
                    "schema_version",
                    "versions"
                  ])
  @version_filename ~r/\A([1-9][0-9]*)-([0-9a-f]{64})\.json\z/

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def publish(target_type, target_id, attrs),
    do: call({:publish, target_type, target_id, attrs})

  @doc false
  def get(target_type, target_id, version),
    do: call({:get, target_type, target_id, version})

  @doc false
  def transition(target_type, target_id, version, state, details),
    do: call({:transition, target_type, target_id, version, state, details})

  @doc false
  def latest_desired(target_type, target_id),
    do: call({:latest_desired, target_type, target_id})

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def handle_call({{:publish, target_type, target_id, attrs}, deadline, config}, _from, state) do
    {:reply, do_publish(target_type, target_id, attrs, deadline, config), state}
  end

  def handle_call({{:get, target_type, target_id, version}, deadline, config}, _from, state) do
    {:reply, do_get(target_type, target_id, version, deadline, config), state}
  end

  def handle_call(
        {{:transition, target_type, target_id, version, next_state, details}, deadline, config},
        _from,
        state
      ) do
    {:reply,
     do_transition(target_type, target_id, version, next_state, details, deadline, config), state}
  end

  def handle_call({{:latest_desired, target_type, target_id}, deadline, config}, _from, state) do
    {:reply, do_latest_desired(target_type, target_id, deadline, config), state}
  end

  defp do_publish(target_type, target_id, attrs, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, target_type} <- target_type(target_type),
         {:ok, record} <- registered_target(target_type, target_id),
         {:ok, attrs} <- attrs(attrs),
         {:ok, target} <- load_target(target_type, target_id, deadline, config),
         :ok <- ensure_before_deadline(deadline),
         {:ok, next_version} <- next_version(target, deadline, config),
         :ok <- ensure_before_deadline(deadline),
         {:ok, previous} <- applied_pair(target),
         {:ok, version} <-
           ConfigVersion.new(
             target_type,
             target_id,
             next_version,
             attrs.operation,
             profile(record),
             attrs.payload,
             attrs.expected_revision,
             DateTime.utc_now(:second),
             previous
           ),
         {:ok, version_path} <- version_path(version, config.root),
         {:ok, ^version_path} <-
           create_immutable(
             version_path,
             ConfigVersion.immutable_document(version),
             deadline,
             config
           ),
         {:ok, committed} <- commit_publication(target, version, deadline, config) do
      {:ok, committed}
    end
  end

  defp do_get(target_type, target_id, version, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, target_type} <- target_type(target_type),
         {:ok, _record} <- registered_target(target_type, target_id),
         :ok <- validate_version(version),
         {:ok, target} <- load_target(target_type, target_id, deadline, config),
         {:ok, config_version} <- fetch_version(target, version) do
      {:ok, config_version}
    end
  end

  defp do_latest_desired(target_type, target_id, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, target_type} <- target_type(target_type),
         {:ok, _record} <- registered_target(target_type, target_id),
         {:ok, target} <- load_target(target_type, target_id, deadline, config),
         {:ok, desired_version} <- desired_version(target.lifecycle),
         {:ok, version} <- fetch_version(target, desired_version),
         true <- version.state in [:desired, :delivered, :applying] do
      {:ok, version}
    else
      false -> not_found()
      {:error, %Error{}} = error -> error
      _missing -> not_found()
    end
  end

  defp do_transition(target_type, target_id, version, next_state, details, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, target_type} <- target_type(target_type),
         {:ok, _record} <- registered_target(target_type, target_id),
         :ok <- validate_version(version),
         {:ok, next_state} <- transition_state(next_state),
         {:ok, target} <- load_target(target_type, target_id, deadline, config),
         :ok <- current_desired_version(target.lifecycle, version),
         {:ok, current} <- fetch_version(target, version),
         :ok <- allowed_state_transition(current.state, next_state),
         {:ok, expected_state_revision, acknowledgement} <- details(details),
         :ok <- expected_state_revision(current, expected_state_revision),
         {:ok, acknowledgement} <-
           validate_acknowledgement(current, next_state, acknowledgement),
         :ok <- allowed_transition(current.state, next_state, acknowledgement.failure),
         updated = apply_transition(current, next_state, acknowledgement),
         {:ok, committed} <- commit_transition(target, updated, deadline, config) do
      {:ok, committed}
    end
  end

  defp commit_publication(target, version, deadline, config) do
    updated_lifecycle =
      target.lifecycle
      |> Map.put("counter", version.version)
      |> Map.put("desired_version", version.version)
      |> put_version(version)

    target.manifest_path
    |> ManifestStore.commit_section(
      "config_lifecycle",
      fn current_section ->
        with :ok <- unchanged_section(current_section, target.raw_section) do
          {:ok, updated_lifecycle, version}
        end
      end,
      deadline,
      config
    )
    |> publication_commit_result()
  end

  defp commit_transition(target, version, deadline, config) do
    updated_lifecycle =
      target.lifecycle
      |> put_version(version)
      |> update_applied_pointer(version)

    ManifestStore.commit_section(
      target.manifest_path,
      "config_lifecycle",
      fn current_section ->
        with :ok <- unchanged_section(current_section, target.raw_section) do
          {:ok, updated_lifecycle, version}
        end
      end,
      deadline,
      config
    )
  end

  defp load_target(target_type, target_id, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, manifest_path} <- manifest_path(config.root, target_type, target_id),
         :ok <- ensure_before_deadline(deadline),
         {:ok, manifest} <- read_manifest(manifest_path, deadline, config),
         :ok <- ensure_before_deadline(deadline),
         raw_section = Map.get(manifest, "config_lifecycle"),
         {:ok, lifecycle} <- decode_lifecycle(raw_section),
         :ok <- ensure_before_deadline(deadline),
         {:ok, versions} <- load_versions(target_type, target_id, lifecycle, deadline, config),
         :ok <- ensure_before_deadline(deadline),
         :ok <- validate_pointers(lifecycle, versions),
         :ok <- ensure_before_deadline(deadline) do
      {:ok,
       %{
         target_type: target_type,
         target_id: target_id,
         root: config.root,
         manifest_path: manifest_path,
         raw_section: raw_section,
         lifecycle: lifecycle,
         versions: versions
       }}
    else
      {:error, %Error{code: code}} = error when code in [:internal, :timeout] -> error
      {:error, %Error{}} -> invalid()
      _invalid -> invalid()
    end
  end

  defp read_manifest(path, deadline, config) do
    case owned_file_operation(fn -> AtomicJson.read(path, config.file_ops) end, deadline) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:ok, _invalid} -> invalid()
      {:error, %Error{code: :not_found}} -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp decode_lifecycle(nil), do: {:ok, empty_lifecycle()}

  defp decode_lifecycle(value) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == @lifecycle_keys,
         1 <- value["schema_version"],
         :ok <- counter(value["counter"]),
         :ok <- optional_version(value["desired_version"]),
         :ok <- optional_version(value["applied_version"]),
         versions when is_map(versions) <- value["versions"],
         :ok <- validate_lifecycle_entries(versions, value["counter"]),
         :ok <-
           validate_lifecycle_coherence(
             versions,
             value["counter"],
             value["desired_version"]
           ) do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp decode_lifecycle(_value), do: invalid()

  defp validate_lifecycle_entries(versions, counter) do
    Enum.reduce_while(versions, :ok, fn {key, lifecycle}, :ok ->
      with {version, ""} <- Integer.parse(key),
           true <- Integer.to_string(version) == key,
           :ok <- validate_version(version),
           true <- version <= counter,
           true <- is_map(lifecycle) do
        {:cont, :ok}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
  end

  defp validate_lifecycle_coherence(versions, counter, desired_version)
       when map_size(versions) == 0 do
    if counter == 0 and is_nil(desired_version), do: :ok, else: invalid()
  end

  defp validate_lifecycle_coherence(versions, counter, desired_version) do
    max_referenced_version =
      versions
      |> Map.keys()
      |> Enum.map(&String.to_integer/1)
      |> Enum.max()

    if counter == max_referenced_version and desired_version == counter,
      do: :ok,
      else: invalid()
  end

  defp load_versions(target_type, target_id, lifecycle, deadline, config) do
    Enum.reduce_while(lifecycle["versions"], {:ok, %{}}, fn {key, state}, {:ok, versions} ->
      version = String.to_integer(key)

      with :ok <- ensure_before_deadline(deadline),
           {:ok, digest} <- Digest.validate(state["digest"]),
           {:ok, path} <-
             storage_version_path(config.root, target_type, target_id, version, digest),
           :ok <- ensure_before_deadline(deadline),
           {:ok, immutable} <-
             owned_file_operation(fn -> AtomicJson.read(path, config.file_ops) end, deadline),
           :ok <- ensure_before_deadline(deadline),
           {:ok, config_version} <-
             ConfigVersion.decode(immutable, state, target_type, target_id, path, config.root),
           :ok <- ensure_before_deadline(deadline) do
        {:cont, {:ok, Map.put(versions, version, config_version)}}
      else
        {:error, %Error{code: code}} = error when code in [:internal, :timeout] -> {:halt, error}
        _invalid -> {:halt, invalid()}
      end
    end)
  end

  defp validate_pointers(lifecycle, versions) do
    with :ok <- pointer_exists(lifecycle["desired_version"], versions),
         :ok <- applied_pointer(lifecycle["applied_version"], versions),
         :ok <- active_desired_previous_pair(lifecycle, versions) do
      :ok
    end
  end

  defp pointer_exists(nil, _versions), do: :ok

  defp pointer_exists(version, versions) do
    if Map.has_key?(versions, version), do: :ok, else: invalid()
  end

  defp applied_pointer(nil, _versions), do: :ok

  defp applied_pointer(version, versions) do
    case Map.fetch(versions, version) do
      {:ok, %ConfigVersion{state: :applied}} -> :ok
      _invalid -> invalid()
    end
  end

  defp active_desired_previous_pair(%{"desired_version" => nil}, _versions), do: :ok

  defp active_desired_previous_pair(lifecycle, versions) do
    desired = Map.fetch!(versions, lifecycle["desired_version"])

    if desired.state in [:desired, :delivered, :applying] do
      expected_pair = applied_previous_pair(lifecycle["applied_version"], versions)

      if {desired.previous_version, desired.previous_revision} == expected_pair,
        do: :ok,
        else: invalid()
    else
      :ok
    end
  end

  defp applied_previous_pair(nil, _versions), do: {nil, nil}

  defp applied_previous_pair(version, versions) do
    applied = Map.fetch!(versions, version)
    {applied.version, applied.applied_revision}
  end

  defp next_version(target, deadline, config) do
    with :ok <- ensure_before_deadline(deadline),
         {:ok, versions_dir} <- versions_path(target.root, target.target_type, target.target_id),
         :ok <- ensure_before_deadline(deadline),
         {:ok, filename_max} <- highest_filename_version(versions_dir, deadline, config),
         :ok <- ensure_before_deadline(deadline),
         current <- max(filename_max, target.lifecycle["counter"]),
         true <- current < @max_version do
      {:ok, current + 1}
    else
      false -> conflict("config version limit reached")
      {:error, %Error{}} = error -> error
      _invalid -> internal()
    end
  end

  defp highest_filename_version(directory, deadline, config) do
    case owned_file_operation(fn -> config.file_ops.ls(directory) end, deadline) do
      {:ok, filenames} ->
        Enum.reduce_while(filenames, {:ok, 0}, fn filename, {:ok, current} ->
          case ensure_before_deadline(deadline) do
            :ok -> {:cont, {:ok, highest_filename(filename, current)}}
            {:error, %Error{}} = error -> {:halt, error}
          end
        end)

      {:error, :enoent} ->
        {:ok, 0}

      {:error, %Error{}} = error ->
        error

      {:error, _reason} ->
        internal()
    end
  end

  defp highest_filename(filename, current) do
    case Regex.run(@version_filename, filename, capture: :all_but_first) do
      [version, _digest] ->
        case Integer.parse(version) do
          {value, ""} when value <= @max_version -> max(value, current)
          _invalid -> current
        end

      _not_canonical ->
        current
    end
  end

  defp applied_pair(%{lifecycle: %{"applied_version" => nil}}), do: {:ok, nil}

  defp applied_pair(%{lifecycle: lifecycle, versions: versions}) do
    with {:ok, applied} <- Map.fetch(versions, lifecycle["applied_version"]),
         %ConfigVersion{state: :applied, applied_revision: revision} <- applied,
         true <- is_binary(revision) do
      {:ok, {applied.version, revision}}
    else
      _invalid -> invalid()
    end
  end

  defp attrs(attrs) when is_list(attrs), do: attrs(Map.new(attrs))

  defp attrs(attrs) when is_map(attrs) do
    with {:ok, operation} <- fetch_attr(attrs, :operation),
         {:ok, payload} <- fetch_attr(attrs, :payload),
         expected_revision <- get_attr(attrs, :expected_revision) do
      {:ok, %{operation: operation, payload: payload, expected_revision: expected_revision}}
    else
      _invalid -> invalid()
    end
  end

  defp attrs(_attrs), do: invalid()

  defp details(details) when is_list(details), do: details(Map.new(details))

  defp details(details) when is_map(details) do
    with {:ok, expected_state_revision} <- fetch_attr(details, :expected_state_revision),
         true <- is_integer(expected_state_revision) and expected_state_revision >= 0,
         {:ok, acknowledgement} <- fetch_attr(details, :acknowledgement),
         true <- is_map(acknowledgement) do
      {:ok, expected_state_revision, acknowledgement}
    else
      _invalid -> invalid()
    end
  end

  defp details(_details), do: invalid()

  defp validate_acknowledgement(version, next_state, acknowledgement) do
    with {:ok, ack} <- acknowledgement_map(acknowledgement),
         :ok <- acknowledgement_identity(version, next_state, ack),
         :ok <- validate_failure_reason(ack.failure),
         :ok <- validate_observed_at(ack.observed_at),
         :ok <- validate_runtime_fields(version, next_state, ack),
         {:ok, _result} <-
           Operation.validate_result(version.operation, version.target_type, :config, ack.wire) do
      {:ok, ack}
    else
      {:error, %Error{code: :conflict}} = error -> error
      {:error, %Error{}} -> invalid()
      _invalid -> invalid()
    end
  end

  defp acknowledgement_map(%ConfigState{} = acknowledgement) do
    acknowledgement_map(Map.from_struct(acknowledgement))
  end

  defp acknowledgement_map(acknowledgement) when is_map(acknowledgement) do
    with {:ok, target_type} <- fetch_attr(acknowledgement, :target_type),
         {:ok, target_id} <- fetch_attr(acknowledgement, :target_id),
         {:ok, operation} <- fetch_attr(acknowledgement, :operation),
         {:ok, state} <- fetch_attr(acknowledgement, :state),
         {:ok, state} <- acknowledgement_state(state),
         {:ok, version} <- fetch_attr(acknowledgement, :version),
         {:ok, digest} <- fetch_attr(acknowledgement, :digest),
         {:ok, applied_revision} <- fetch_attr(acknowledgement, :applied_revision),
         {:ok, previous_version} <- fetch_attr(acknowledgement, :previous_version),
         {:ok, previous_revision} <- fetch_attr(acknowledgement, :previous_revision),
         {:ok, failure} <- fetch_attr(acknowledgement, :failure),
         {:ok, rollback} <- fetch_attr(acknowledgement, :rollback),
         {:ok, observed_at} <- fetch_attr(acknowledgement, :observed_at) do
      wire = %{
        "state" => Atom.to_string(state),
        "version" => version,
        "digest" => digest,
        "applied_revision" => applied_revision,
        "previous_version" => previous_version,
        "previous_revision" => previous_revision,
        "failure" => failure,
        "rollback" => rollback
      }

      {:ok,
       %{
         target_type: target_type,
         target_id: target_id,
         operation: operation,
         state: state,
         version: version,
         digest: digest,
         applied_revision: applied_revision,
         previous_version: previous_version,
         previous_revision: previous_revision,
         failure: failure,
         rollback: rollback,
         observed_at: observed_at,
         wire: wire
       }}
    else
      _invalid -> invalid()
    end
  end

  defp acknowledgement_map(_acknowledgement), do: invalid()

  defp acknowledgement_identity(version, next_state, ack) do
    if ack.target_type == version.target_type and ack.target_id == version.target_id and
         ack.operation == version.operation and ack.state == next_state and
         ack.version == version.version and ack.digest == version.digest do
      :ok
    else
      conflict("config acknowledgement mismatch")
    end
  end

  defp validate_runtime_fields(_version, :delivered, ack) do
    exact_runtime_fields(ack, nil, nil, nil)
  end

  defp validate_runtime_fields(version, next_state, ack)
       when next_state in [:applying, :applied] do
    applied_revision = if next_state == :applied, do: :required, else: nil

    exact_runtime_fields(
      ack,
      version.previous_version,
      version.previous_revision,
      applied_revision
    )
  end

  defp validate_runtime_fields(version, :failed, ack) do
    case version.state do
      state when state in [:desired, :delivered] ->
        exact_runtime_fields(ack, nil, nil, nil)

      :applying ->
        exact_runtime_fields(ack, version.previous_version, version.previous_revision, nil)

      _terminal ->
        conflict("invalid config lifecycle transition")
    end
  end

  defp exact_runtime_fields(ack, previous_version, previous_revision, :required) do
    if ack.previous_version == previous_version and ack.previous_revision == previous_revision and
         match?({:ok, _digest}, Digest.validate(ack.applied_revision)) do
      :ok
    else
      conflict("config runtime revision mismatch")
    end
  end

  defp exact_runtime_fields(ack, previous_version, previous_revision, nil) do
    if ack.previous_version == previous_version and ack.previous_revision == previous_revision and
         is_nil(ack.applied_revision) do
      :ok
    else
      conflict("config runtime revision mismatch")
    end
  end

  defp validate_failure_reason(nil), do: :ok

  defp validate_failure_reason(%{"reason" => reason}) do
    with {:ok, _reason} <- Bounds.message(reason),
         true <- reason != "" do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_failure_reason(_failure), do: invalid()

  defp validate_observed_at(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp validate_observed_at(_observed_at), do: invalid()

  defp allowed_state_transition(:desired, next_state) when next_state in [:delivered, :failed],
    do: :ok

  defp allowed_state_transition(:delivered, next_state) when next_state in [:applying, :failed],
    do: :ok

  defp allowed_state_transition(:applying, next_state) when next_state in [:applied, :failed],
    do: :ok

  defp allowed_state_transition(_current, _next),
    do: conflict("invalid config lifecycle transition")

  defp allowed_transition(:desired, :delivered, nil), do: :ok
  defp allowed_transition(:delivered, :applying, nil), do: :ok
  defp allowed_transition(:applying, :applied, nil), do: :ok

  defp allowed_transition(:desired, :failed, %{"phase" => "delivery"}), do: :ok
  defp allowed_transition(:delivered, :failed, %{"phase" => "validation"}), do: :ok

  defp allowed_transition(:applying, :failed, %{"phase" => phase})
       when phase in ["apply", "rollback"],
       do: :ok

  defp allowed_transition(_current, _next, _failure),
    do: conflict("invalid config lifecycle transition")

  defp apply_transition(version, :delivered, ack) do
    %{
      version
      | state: :delivered,
        state_revision: version.state_revision + 1,
        state_changed_at: ack.observed_at,
        delivered_at: ack.observed_at
    }
  end

  defp apply_transition(version, :applying, ack) do
    %{
      version
      | state: :applying,
        state_revision: version.state_revision + 1,
        state_changed_at: ack.observed_at,
        applying_at: ack.observed_at
    }
  end

  defp apply_transition(version, :applied, ack) do
    %{
      version
      | state: :applied,
        state_revision: version.state_revision + 1,
        state_changed_at: ack.observed_at,
        applied_at: ack.observed_at,
        applied_revision: ack.applied_revision
    }
  end

  defp apply_transition(version, :failed, ack) do
    rollback = ack.rollback

    %{
      version
      | state: :failed,
        state_revision: version.state_revision + 1,
        state_changed_at: ack.observed_at,
        failed_at: ack.observed_at,
        failure_phase: failure_phase(ack.failure),
        failure_reason: ack.failure["reason"],
        rollback: rollback,
        restored_version: rollback_value(rollback, "restored_version"),
        restored_revision: rollback_value(rollback, "restored_revision")
    }
  end

  defp update_applied_pointer(lifecycle, %ConfigVersion{state: :applied} = version),
    do: Map.put(lifecycle, "applied_version", version.version)

  defp update_applied_pointer(
         lifecycle,
         %ConfigVersion{state: :failed, rollback: %{"succeeded" => true}} = version
       ),
       do: Map.put(lifecycle, "applied_version", version.restored_version)

  defp update_applied_pointer(lifecycle, _version), do: lifecycle

  defp put_version(lifecycle, version) do
    put_in(
      lifecycle,
      ["versions", Integer.to_string(version.version)],
      ConfigVersion.lifecycle_document(version)
    )
  end

  defp fetch_version(target, version) do
    case Map.fetch(target.versions, version) do
      {:ok, config_version} -> {:ok, config_version}
      :error -> not_found()
    end
  end

  defp desired_version(%{"desired_version" => nil}), do: not_found()
  defp desired_version(%{"desired_version" => version}), do: {:ok, version}

  defp current_desired_version(%{"desired_version" => version}, version), do: :ok

  defp current_desired_version(_lifecycle, _version),
    do: conflict("config version is no longer desired")

  defp expected_state_revision(version, expected) do
    if version.state_revision == expected,
      do: :ok,
      else: conflict("stale config state revision")
  end

  defp unchanged_section(current, expected) do
    if current == expected,
      do: :ok,
      else: conflict("config lifecycle changed concurrently")
  end

  defp publication_commit_result({:ok, _version} = success), do: success

  defp publication_commit_result({:error, %Error{code: code}} = error)
       when code in [:conflict, :timeout],
       do: error

  defp publication_commit_result({:error, %Error{}}), do: internal()

  defp registered_target(:server, target_id), do: registered(Servers.get(target_id))
  defp registered_target(:netman, target_id), do: registered(Netmans.get(target_id))

  defp registered({:ok, record}), do: {:ok, record}
  defp registered(_missing), do: not_found()

  defp profile(%{profile: profile}) when is_atom(profile), do: Atom.to_string(profile)
  defp profile(%{profile: profile}) when is_binary(profile), do: profile

  defp target_type(:server), do: {:ok, :server}
  defp target_type(:netman), do: {:ok, :netman}
  defp target_type(_target_type), do: invalid()

  defp transition_state(state) when state in [:desired, :delivered, :applying, :applied, :failed],
    do: {:ok, state}

  defp transition_state(_state), do: invalid()

  defp acknowledgement_state(state)
       when state in [:delivered, :applying, :applied, :failed],
       do: {:ok, state}

  defp acknowledgement_state("delivered"), do: {:ok, :delivered}
  defp acknowledgement_state("applying"), do: {:ok, :applying}
  defp acknowledgement_state("applied"), do: {:ok, :applied}
  defp acknowledgement_state("failed"), do: {:ok, :failed}
  defp acknowledgement_state(_state), do: invalid()

  defp failure_phase(%{"phase" => "delivery"}), do: :delivery
  defp failure_phase(%{"phase" => "validation"}), do: :validation
  defp failure_phase(%{"phase" => "apply"}), do: :apply
  defp failure_phase(%{"phase" => "rollback"}), do: :rollback

  defp rollback_value(nil, _key), do: nil
  defp rollback_value(rollback, key), do: rollback[key]

  defp manifest_path(root, :server, target_id), do: StoragePath.server_manifest(root, target_id)
  defp manifest_path(root, :netman, target_id), do: StoragePath.netman_manifest(root, target_id)

  defp versions_path(root, :server, target_id), do: StoragePath.server_versions(root, target_id)
  defp versions_path(root, :netman, target_id), do: StoragePath.netman_versions(root, target_id)

  defp storage_version_path(root, :server, target_id, version, digest),
    do: StoragePath.server_version(root, target_id, version, digest)

  defp storage_version_path(root, :netman, target_id, version, digest),
    do: StoragePath.netman_version(root, target_id, version, digest)

  defp version_path(version, root),
    do:
      storage_version_path(
        root,
        version.target_type,
        version.target_id,
        version.version,
        version.digest
      )

  defp create_immutable(path, document, deadline, %Config{} = config) do
    staging_path = AtomicJson.staging_path(path)

    result =
      with :ok <- ensure_before_deadline(deadline),
           {:ok, ^staging_path} <-
             owned_file_operation(
               fn -> AtomicJson.stage(path, document, staging_path, config.file_ops) end,
               deadline
             ),
           :ok <- ensure_before_deadline(deadline),
           {:ok, ^path} <-
             promote_immutable(staging_path, path, document, deadline, config),
           :ok <- ensure_before_deadline(deadline) do
        {:ok, path}
      end

    case remove_staging(staging_path, deadline, config) do
      :ok -> result
      {:error, %Error{}} = cleanup_error -> cleanup_error
    end
  end

  defp promote_immutable(staging_path, path, document, deadline, config) do
    result =
      owned_file_operation(
        fn -> AtomicJson.promote(staging_path, path, config.file_ops) end,
        deadline
      )

    case result do
      {:error, %Error{code: :timeout}} ->
        reconcile_immutable_promotion(path, document, deadline, config)

      other ->
        other
    end
  end

  defp reconcile_immutable_promotion(path, document, _deadline, config) do
    recovery_deadline = reserved_deadline(config)

    case owned_file_operation(
           fn -> AtomicJson.read(path, config.file_ops) end,
           recovery_deadline
         ) do
      {:ok, ^document} -> timeout()
      {:error, %Error{code: :not_found}} -> timeout()
      {:error, %Error{code: :timeout}} -> timeout()
      {:ok, _other} -> conflict("immutable config path is occupied")
      {:error, %Error{}} -> internal()
    end
  end

  defp remove_staging(staging_path, _deadline, config) do
    cleanup_deadline = reserved_deadline(config)
    first_attempt_deadline = cleanup_attempt_deadline(cleanup_deadline)

    case remove_staging_once(staging_path, first_attempt_deadline, config) do
      :ok -> :ok
      {:error, _reason} -> remove_staging_once(staging_path, cleanup_deadline, config)
    end
  end

  defp remove_staging_once(staging_path, deadline, config) do
    case owned_file_operation(fn -> config.file_ops.rm(staging_path) end, deadline) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, %Error{}} = error -> error
      {:error, reason} -> staging_cleanup_error(reason)
      _invalid -> staging_cleanup_error(:invalid_result)
    end
  end

  defp cleanup_attempt_deadline(cleanup_deadline) do
    now = System.monotonic_time(:millisecond)
    min(now + max(div(max(cleanup_deadline - now, 0), 2), 1), cleanup_deadline)
  end

  defp reserved_deadline(config) do
    System.monotonic_time(:millisecond) + config.transport_margin_ms
  end

  defp owned_file_operation(operation, deadline)
       when is_function(operation, 0) and is_integer(deadline) do
    owner = self()
    token = make_ref()

    {worker_pid, monitor_ref} =
      :erlang.spawn_opt(
        fn ->
          send(owner, {:config_file_operation_result, token, run_file_operation(operation)})
        end,
        [:link, :monitor]
      )

    await_file_operation(worker_pid, monitor_ref, token, deadline)
  end

  defp run_file_operation(operation) do
    operation.()
  rescue
    _exception -> internal()
  catch
    _kind, _reason -> internal()
  end

  defp await_file_operation(worker_pid, monitor_ref, token, deadline) do
    receive do
      {:config_file_operation_result, ^token, result} ->
        await_file_worker_down(worker_pid, monitor_ref, token)
        result

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        result = take_file_operation_result(token, internal())
        flush_file_worker_messages(worker_pid, token)
        result

      {:EXIT, ^worker_pid, _reason} ->
        await_file_worker_down(worker_pid, monitor_ref, token)
        take_file_operation_result(token, internal())
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(worker_pid, :kill)
        await_file_worker_down(worker_pid, monitor_ref, token)
        timeout()
    end
  end

  defp await_file_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_file_worker_messages(worker_pid, token)

      {:config_file_operation_result, ^token, _result} ->
        await_file_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_file_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp take_file_operation_result(token, fallback) do
    receive do
      {:config_file_operation_result, ^token, result} -> result
    after
      0 -> fallback
    end
  end

  defp flush_file_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} ->
        flush_file_worker_messages(worker_pid, token)

      {:config_file_operation_result, ^token, _result} ->
        flush_file_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp counter(value) when is_integer(value) and value >= 0 and value <= @max_version, do: :ok
  defp counter(_value), do: invalid()

  defp optional_version(nil), do: :ok
  defp optional_version(value), do: validate_version(value)

  defp validate_version(value)
       when is_integer(value) and value >= 1 and value <= @max_version,
       do: :ok

  defp validate_version(_value), do: invalid()

  defp empty_lifecycle do
    %{
      "schema_version" => 1,
      "counter" => 0,
      "desired_version" => nil,
      "applied_version" => nil,
      "versions" => %{}
    }
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp call(request) do
    {deadline, config} = EventStore.operation()

    GenServer.call(
      __MODULE__,
      {request, deadline, config},
      EventStore.call_timeout(deadline, 6, config)
    )
  catch
    :exit, {:timeout, _reason} -> timeout()
    :exit, _reason -> internal()
  end

  defp ensure_before_deadline(deadline) do
    if deadline <= System.monotonic_time(:millisecond), do: timeout(), else: :ok
  end

  defp invalid, do: {:error, Error.new(:invalid, "invalid config lifecycle", %{})}
  defp not_found, do: {:error, Error.new(:not_found, "config version not found", %{})}
  defp timeout, do: {:error, Error.new(:timeout, "config lifecycle operation timed out", %{})}
  defp internal, do: {:error, Error.new(:internal, "config lifecycle persistence failed", %{})}

  defp staging_cleanup_error(reason) do
    {:error,
     Error.new(:internal, "config staging cleanup failed", %{"reason" => inspect(reason)})}
  end

  defp conflict(message), do: {:error, Error.new(:conflict, message, %{})}
end
