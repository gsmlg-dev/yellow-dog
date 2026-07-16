defmodule YellowDog.Management.Snapshots do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.EventStore
  alias YellowDog.Management.EventStore.Config
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @document_keys Enum.sort([
                   "domain",
                   "observed_at",
                   "operation",
                   "query_digest",
                   "received_at",
                   "request_id",
                   "requested_at",
                   "revision",
                   "schema_version",
                   "stored_at",
                   "target_id",
                   "target_type",
                   "value"
                 ])
  @request_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @snapshot_file ~r/\A(.+)\.json\z/
  @snapshot_stage ~r/\A\..+\.json\..+\.stage\z/

  defmodule Record do
    @moduledoc false
    @enforce_keys [
      :target_type,
      :target_id,
      :domain,
      :operation,
      :request_id,
      :query_digest,
      :revision,
      :value,
      :requested_at,
      :observed_at,
      :received_at,
      :stored_at,
      :path
    ]
    defstruct @enforce_keys
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def put(%Envelope{} = envelope, domain, result, %DateTime{} = received_at),
    do: call({:put, envelope, domain, result, received_at})

  @doc false
  def get(target_type, target_id, domain), do: call({:get, target_type, target_id, domain})

  @impl true
  def init(:ok) do
    config = EventStore.config()

    with :ok <- cleanup_staging(config),
         {:ok, records} <- load_records(config) do
      {:ok, %{records: records, config: config}}
    else
      {:error, %Error{} = error} ->
        {:stop, {:snapshot_recovery_failed, error.code}}
    end
  end

  @impl true
  def handle_call({request, deadline, requested_config}, _from, state) do
    if requested_config == state.config do
      {reply, state} = handle_request(request, deadline, state)
      {:reply, reply, state}
    else
      {:reply, internal(), state}
    end
  end

  defp handle_request({:put, envelope, domain, result, received_at}, deadline, state) do
    with {:ok, envelope} <- Operation.validate_envelope(envelope, :query),
         {:ok, result} <-
           Operation.validate_result(
             envelope.operation,
             envelope.target_type,
             :query,
             result
           ),
         {:ok, received_at} <- utc_datetime(received_at),
         {:ok, path} <-
           snapshot_path(state.config.root, envelope.target_type, envelope.target_id, domain),
         {:ok, record} <- new_record(envelope, domain, result, received_at, path),
         {:ok, reply, state} <- compare_and_store(record, deadline, state) do
      {reply, state}
    else
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp handle_request({:get, target_type, target_id, domain}, _deadline, state) do
    with {:ok, _path} <- snapshot_path(state.config.root, target_type, target_id, domain),
         {:ok, record} <- Map.fetch(state.records, {target_type, target_id, domain}) do
      {{:ok, public_record(record)}, state}
    else
      :error -> {not_found(), state}
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp new_record(envelope, domain, result, received_at, path) do
    with {:ok, revision} <- result_revision(result),
         {:ok, observed_at} <- effective_observed_at(result, envelope.sent_at) do
      {:ok,
       %Record{
         target_type: envelope.target_type,
         target_id: envelope.target_id,
         domain: domain,
         operation: envelope.operation,
         request_id: envelope.request_id,
         query_digest: envelope.payload_digest,
         revision: revision,
         value: result,
         requested_at: envelope.sent_at,
         observed_at: observed_at,
         received_at: received_at,
         stored_at: latest_datetime([DateTime.utc_now(), envelope.sent_at, received_at]),
         path: path
       }}
    end
  end

  defp compare_and_store(record, deadline, state) do
    key = {record.target_type, record.target_id, record.domain}

    case Map.fetch(state.records, key) do
      :error ->
        with :ok <- ensure_capacity(state) do
          store(record, key, deadline, state)
        end

      {:ok, current} ->
        case compare_order(record, current) do
          :gt ->
            store(record, key, deadline, state)

          :lt ->
            {:ok, {:ok, public_record(current)}, state}

          :eq when record.revision == current.revision ->
            {:ok, {:ok, public_record(current)}, state}

          :eq ->
            conflict()
        end
    end
  end

  defp store(record, key, deadline, state) do
    with :ok <- persist_replace(record, deadline, state.config) do
      state = %{state | records: Map.put(state.records, key, record)}
      {:ok, {:ok, public_record(record)}, state}
    end
  end

  defp compare_order(left, right) do
    case DateTime.compare(left.observed_at, right.observed_at) do
      :eq -> compare_request_id(left.request_id, right.request_id)
      other -> other
    end
  end

  defp compare_request_id(left, right) when left < right, do: :lt
  defp compare_request_id(left, right) when left > right, do: :gt
  defp compare_request_id(_left, _right), do: :eq

  defp public_record(record) do
    record
    |> Map.from_struct()
    |> Map.delete(:path)
  end

  defp result_revision(%{"revision" => revision}), do: Digest.validate(revision)
  defp result_revision(result), do: Digest.calculate(result)

  defp effective_observed_at(%{"observed_at" => observed_at}, _sent_at),
    do: utc_datetime(observed_at)

  defp effective_observed_at(_result, sent_at), do: utc_datetime(sent_at)

  defp persist_replace(record, deadline, config) do
    document = document(record)
    staging_path = AtomicJson.staging_path(record.path)

    result =
      AtomicJson.owned(
        fn -> AtomicJson.replace(record.path, document, staging_path, config.file_ops) end,
        deadline
      )

    result = reconcile_write(result, record.path, document, config)
    cleanup_result = cleanup_staging_path(staging_path, config)

    case {result, cleanup_result} do
      {{:ok, path}, :ok} when path == record.path -> :ok
      {{:error, %Error{}} = error, :ok} -> error
      {_result, {:error, %Error{}} = error} -> error
    end
  end

  defp reconcile_write({:error, %Error{code: :timeout}} = timeout, path, document, config) do
    case AtomicJson.owned(
           fn -> AtomicJson.read(path, config.file_ops) end,
           recovery_deadline(config)
         ) do
      {:ok, ^document} -> {:ok, path}
      _other -> timeout
    end
  end

  defp reconcile_write(result, _path, _document, _config), do: result

  defp cleanup_staging_path(path, config) do
    case AtomicJson.owned(fn -> config.file_ops.rm(path) end, recovery_deadline(config)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, %Error{}} = error -> error
      {:error, reason} -> internal("snapshot staging cleanup failed: #{inspect(reason)}")
      _invalid -> internal("snapshot staging cleanup failed")
    end
  end

  defp document(record) do
    %{
      "schema_version" => 1,
      "target_type" => Atom.to_string(record.target_type),
      "target_id" => record.target_id,
      "domain" => record.domain,
      "operation" => record.operation,
      "request_id" => record.request_id,
      "query_digest" => record.query_digest,
      "revision" => record.revision,
      "value" => record.value,
      "requested_at" => DateTime.to_iso8601(record.requested_at),
      "observed_at" => DateTime.to_iso8601(record.observed_at),
      "received_at" => DateTime.to_iso8601(record.received_at),
      "stored_at" => DateTime.to_iso8601(record.stored_at)
    }
  end

  defp load_records(%Config{root: root} = config) when is_binary(root) do
    with :ok <- ensure_recovery_capacity(root, config) do
      Enum.reduce_while([{:server, "servers"}, {:netman, "netmans"}], {:ok, %{}}, fn
        {target_type, directory}, {:ok, records} ->
          case load_target_type(root, target_type, directory, config, records) do
            {:ok, records} -> {:cont, {:ok, records}}
            {:error, %Error{}} = error -> {:halt, error}
          end
      end)
    end
  end

  defp load_records(_config), do: {:ok, %{}}

  defp load_target_type(root, target_type, target_directory, config, records) do
    directory = Path.join([root, "snapshots", target_directory])

    with {:ok, target_ids} <- list_directory(directory, startup_deadline(config), config) do
      Enum.reduce_while(Enum.sort(target_ids), {:ok, records}, fn target_id, {:ok, records} ->
        if safe_snapshot_target?(root, target_type, target_id) do
          target_path = Path.join(directory, target_id)

          case load_target_snapshots(target_type, target_id, target_path, config, records) do
            {:ok, records} -> {:cont, {:ok, records}}
            {:error, %Error{}} = error -> {:halt, error}
          end
        else
          {:cont, {:ok, records}}
        end
      end)
    end
  end

  defp load_target_snapshots(target_type, target_id, directory, config, records) do
    with {:ok, filenames} <- list_directory(directory, startup_deadline(config), config) do
      Enum.reduce_while(Enum.sort(filenames), {:ok, records}, fn filename, {:ok, records} ->
        case safe_snapshot_file?(config.root, target_type, target_id, directory, filename) do
          {:ok, domain} ->
            load_snapshot(
              target_type,
              target_id,
              domain,
              directory,
              filename,
              config,
              records
            )

          :error ->
            {:cont, {:ok, records}}
        end
      end)
    end
  end

  defp load_snapshot(
         target_type,
         target_id,
         domain,
         directory,
         filename,
         config,
         records
       ) do
    path = Path.join(directory, filename)

    case AtomicJson.owned(
           fn -> AtomicJson.read(path, config.file_ops) end,
           startup_deadline(config)
         ) do
      {:ok, document} ->
        case decode_record(document, target_type, target_id, domain, path, config.root) do
          {:ok, record} ->
            key = {record.target_type, record.target_id, record.domain}
            {:cont, {:ok, Map.put(records, key, record)}}

          {:error, %Error{}} ->
            ignore_malformed(path, records)
        end

      {:error, %Error{code: code}} = error when code in [:timeout, :internal] ->
        {:halt, error}

      _invalid ->
        ignore_malformed(path, records)
    end
  end

  defp decode_record(document, expected_type, expected_id, expected_domain, path, root)
       when is_map(document) do
    with true <- Enum.sort(Map.keys(document)) == @document_keys,
         1 <- document["schema_version"],
         {:ok, target_type} <- decode_target_type(document["target_type"]),
         true <- target_type == expected_type,
         true <- document["target_id"] == expected_id,
         true <- document["domain"] == expected_domain,
         {:ok, ^path} <- snapshot_path(root, target_type, expected_id, expected_domain),
         operation when is_binary(operation) <- document["operation"],
         {:ok, %{target_type: ^target_type, kind: :query}} <- Operation.lookup(operation),
         request_id when is_binary(request_id) <- document["request_id"],
         true <- Regex.match?(@request_id, request_id),
         {:ok, query_digest} <- Digest.validate(document["query_digest"]),
         {:ok, revision} <- Digest.validate(document["revision"]),
         {:ok, value} <-
           Operation.validate_result(operation, target_type, :query, document["value"]),
         {:ok, ^revision} <- result_revision(value),
         {:ok, requested_at} <- utc_datetime(document["requested_at"]),
         {:ok, observed_at} <- utc_datetime(document["observed_at"]),
         {:ok, ^observed_at} <- effective_observed_at(value, requested_at),
         {:ok, received_at} <- utc_datetime(document["received_at"]),
         {:ok, stored_at} <- utc_datetime(document["stored_at"]),
         true <- DateTime.compare(requested_at, received_at) in [:lt, :eq],
         true <- DateTime.compare(received_at, stored_at) in [:lt, :eq] do
      {:ok,
       %Record{
         target_type: target_type,
         target_id: expected_id,
         domain: expected_domain,
         operation: operation,
         request_id: request_id,
         query_digest: query_digest,
         revision: revision,
         value: value,
         requested_at: requested_at,
         observed_at: observed_at,
         received_at: received_at,
         stored_at: stored_at,
         path: path
       }}
    else
      _invalid -> invalid()
    end
  end

  defp decode_record(_document, _type, _id, _domain, _path, _root), do: invalid()

  defp decode_target_type("server"), do: {:ok, :server}
  defp decode_target_type("netman"), do: {:ok, :netman}
  defp decode_target_type(_target_type), do: invalid()

  defp snapshot_path(root, :server, target_id, domain),
    do: StoragePath.server_snapshot(root, target_id, domain)

  defp snapshot_path(root, :netman, target_id, domain),
    do: StoragePath.netman_snapshot(root, target_id, domain)

  defp snapshot_path(_root, _target_type, _target_id, _domain), do: invalid()

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}

  defp utc_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _invalid -> invalid()
    end
  end

  defp utc_datetime(_value), do: invalid()

  defp list_directory(directory, deadline, config) do
    case AtomicJson.owned(fn -> AtomicJson.ls(directory, config.file_ops) end, deadline) do
      {:ok, filenames} when is_list(filenames) -> {:ok, filenames}
      {:error, :enoent} -> {:ok, []}
      {:error, :enotdir} -> {:ok, []}
      {:error, %Error{}} = error -> error
      {:error, reason} -> internal("snapshot directory read failed: #{inspect(reason)}")
      _invalid -> internal("snapshot directory read failed")
    end
  end

  defp ensure_recovery_capacity(root, config) do
    with {:ok, count} <- count_candidate_snapshots(root, config) do
      if count <= config.max_snapshot_records do
        :ok
      else
        capacity_conflict("snapshots", config.max_snapshot_records)
      end
    end
  end

  defp count_candidate_snapshots(root, config) do
    Enum.reduce_while([{:server, "servers"}, {:netman, "netmans"}], {:ok, 0}, fn
      {target_type, target_directory}, {:ok, count} ->
        case count_target_type_snapshots(root, target_type, target_directory, config) do
          {:ok, target_count} -> {:cont, {:ok, count + target_count}}
          {:error, %Error{}} = error -> {:halt, error}
        end
    end)
  end

  defp count_target_type_snapshots(root, target_type, target_directory, config) do
    base = Path.join([root, "snapshots", target_directory])

    with {:ok, target_ids} <- list_directory(base, startup_deadline(config), config) do
      Enum.reduce_while(Enum.sort(target_ids), {:ok, 0}, fn target_id, {:ok, count} ->
        if safe_snapshot_target?(root, target_type, target_id) do
          directory = Path.join(base, target_id)

          case list_directory(directory, startup_deadline(config), config) do
            {:ok, filenames} ->
              candidate_count =
                Enum.count(filenames, fn filename ->
                  match?(
                    {:ok, _domain},
                    safe_snapshot_file?(root, target_type, target_id, directory, filename)
                  )
                end)

              {:cont, {:ok, count + candidate_count}}

            {:error, %Error{}} = error ->
              {:halt, error}
          end
        else
          {:cont, {:ok, count}}
        end
      end)
    end
  end

  defp safe_snapshot_target?(root, :server, target_id) when is_binary(target_id) do
    Path.basename(target_id) == target_id and
      match?({:ok, _path}, StoragePath.server_snapshot(root, target_id, "runtime.capabilities"))
  end

  defp safe_snapshot_target?(root, :netman, target_id) when is_binary(target_id) do
    Path.basename(target_id) == target_id and
      match?({:ok, _path}, StoragePath.netman_snapshot(root, target_id, "runtime.capabilities"))
  end

  defp safe_snapshot_target?(_root, _target_type, _target_id), do: false

  defp safe_snapshot_file?(root, target_type, target_id, directory, filename)
       when is_binary(filename) do
    with true <- Path.basename(filename) == filename,
         [_, domain] <- Regex.run(@snapshot_file, filename),
         {:ok, path} <- snapshot_path(root, target_type, target_id, domain),
         true <- path == Path.join(directory, filename) do
      {:ok, domain}
    else
      _invalid -> :error
    end
  end

  defp safe_snapshot_file?(_root, _target_type, _target_id, _directory, _filename), do: :error

  defp safe_snapshot_stage?(filename) when is_binary(filename),
    do: Path.basename(filename) == filename and Regex.match?(@snapshot_stage, filename)

  defp safe_snapshot_stage?(_filename), do: false

  defp ignore_malformed(path, records) do
    Logger.warning("Ignoring malformed durable snapshot: #{path}")
    {:cont, {:ok, records}}
  end

  defp cleanup_staging(%Config{root: root} = config) when is_binary(root) do
    Enum.reduce_while([{:server, "servers"}, {:netman, "netmans"}], :ok, fn
      {target_type, target_directory}, :ok ->
        case cleanup_target_type_staging(root, target_type, target_directory, config) do
          :ok -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
        end
    end)
  end

  defp cleanup_staging(_config), do: :ok

  defp cleanup_target_type_staging(root, target_type, target_directory, config) do
    base = Path.join([root, "snapshots", target_directory])

    with {:ok, target_ids} <- list_directory(base, startup_deadline(config), config) do
      Enum.reduce_while(Enum.sort(target_ids), :ok, fn target_id, :ok ->
        if safe_snapshot_target?(root, target_type, target_id) do
          directory = Path.join(base, target_id)

          case list_directory(directory, startup_deadline(config), config) do
            {:ok, filenames} ->
              case cleanup_snapshot_files(directory, filenames, config) do
                :ok -> {:cont, :ok}
                {:error, %Error{}} = error -> {:halt, error}
              end

            {:error, %Error{}} = error ->
              {:halt, error}
          end
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp cleanup_snapshot_files(directory, filenames, config) do
    filenames
    |> Enum.filter(&safe_snapshot_stage?/1)
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn filename, :ok ->
      case cleanup_staging_path(Path.join(directory, filename), config) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp call(request) do
    {deadline, config} = EventStore.operation()

    GenServer.call(
      __MODULE__,
      {request, deadline, config},
      EventStore.call_timeout(deadline, 3, config)
    )
  catch
    :exit, {:timeout, _reason} -> EventStore.timeout_result()
    :exit, _reason -> internal()
  end

  defp recovery_deadline(config) do
    System.monotonic_time(:millisecond) + config.transport_margin_ms
  end

  defp startup_deadline(config) do
    System.monotonic_time(:millisecond) + config.operation_timeout_ms
  end

  defp latest_datetime([first | rest]) do
    Enum.reduce(rest, first, fn value, latest ->
      if DateTime.compare(value, latest) == :gt, do: value, else: latest
    end)
  end

  defp ensure_capacity(state) do
    if map_size(state.records) < state.config.max_snapshot_records do
      :ok
    else
      capacity_conflict("snapshots", state.config.max_snapshot_records)
    end
  end

  defp capacity_conflict(resource, limit) do
    {:error,
     Error.new(:conflict, "durable #{resource} capacity reached", %{
       "limit" => limit,
       "resource" => resource
     })}
  end

  defp not_found, do: {:error, Error.new(:not_found, "snapshot was not found", %{})}
  defp conflict, do: {:error, Error.new(:conflict, "snapshot observation order conflicts", %{})}
  defp invalid, do: {:error, Error.new(:invalid, "invalid snapshot", %{})}

  defp internal(message \\ "snapshot persistence failed"),
    do: {:error, Error.new(:internal, message, %{})}
end
