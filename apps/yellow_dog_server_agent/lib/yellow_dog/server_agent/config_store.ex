defmodule YellowDog.ServerAgent.ConfigStore do
  @moduledoc """
  Durable immutable staging for local Server configuration deliveries.
  """

  use GenServer

  alias YellowDog.ServerAgent.Storage
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @max_version 9_223_372_036_854_775_807
  @manifest_keys Enum.sort([
                   "current",
                   "previous",
                   "schema_version",
                   "target_id",
                   "target_type"
                 ])
  @immutable_keys Enum.sort([
                    "digest",
                    "expected_revision",
                    "operation",
                    "payload",
                    "profile",
                    "published_at",
                    "schema_version",
                    "target_id",
                    "target_type",
                    "version"
                  ])
  @pointer_keys ["digest", "version"]

  @enforce_keys [:data_dir, :server_id, :profile, :storage_opts]
  defstruct @enforce_keys

  @type pointer :: %{version: pos_integer(), digest: String.t()}
  @type state :: %__MODULE__{
          data_dir: Path.t(),
          server_id: String.t(),
          profile: String.t(),
          storage_opts: keyword()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case state_from_options(opts) do
      {:ok, state} ->
        GenServer.start_link(__MODULE__, state, name: Keyword.get(opts, :name, __MODULE__))

      :error ->
        {:error, :invalid_options}
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

  @spec stage(Envelope.t(), GenServer.server()) :: {:ok, map()} | {:error, Error.t()}
  def stage(envelope, server \\ __MODULE__), do: GenServer.call(server, {:stage, envelope})

  @spec current(GenServer.server()) :: {:ok, map()} | {:error, Error.t()}
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @spec previous(GenServer.server()) :: {:ok, map()} | {:error, Error.t()}
  def previous(server \\ __MODULE__), do: GenServer.call(server, :previous)

  @impl GenServer
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl GenServer
  def handle_call({:stage, envelope}, _from, state) do
    {:reply, stage_config(envelope, state), state}
  end

  def handle_call(:current, _from, state) do
    {:reply, read_selector(:current, state), state}
  end

  def handle_call(:previous, _from, state) do
    {:reply, read_selector(:previous, state), state}
  end

  defp stage_config(envelope, state) do
    with {:ok, config} <- validate_delivery(envelope, state),
         {:ok, manifest} <- manifest_for_staging(state),
         :ok <- validate_staged_versions(manifest, state),
         {:ok, next_manifest, replace_manifest?} <- next_manifest(manifest, config),
         {:ok, _path} <-
           create_version(
             version_path(state, config.version, config.digest),
             config.document,
             state
           ),
         :ok <- replace_manifest_if_needed(replace_manifest?, next_manifest, state) do
      {:ok, config.document}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp read_selector(selector, state) when selector in [:current, :previous] do
    with {:ok, manifest} <- read_manifest(state),
         {:ok, pointer} <- selected_pointer(manifest, selector),
         {:ok, document} <- read_manifest_version(pointer, state) do
      {:ok, document}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp validate_delivery(%Envelope{} = envelope, state) do
    with {:ok, _envelope} <- Operation.validate_envelope(envelope, :config),
         :ok <- exact_server(envelope, state),
         {:ok, version} <- version(envelope.config_version),
         :ok <- Digest.verify(envelope.payload, envelope.payload_digest),
         {:ok, operation} <- config_operation(envelope.operation, envelope.payload),
         :ok <- valid_profile(state.profile),
         {:ok, expected_revision} <- optional_digest(envelope.expected_revision),
         {:ok, published_at} <- utc_datetime(envelope.sent_at) do
      {:ok,
       %{
         version: version,
         digest: envelope.payload_digest,
         document: %{
           "schema_version" => 1,
           "target_type" => "server",
           "target_id" => state.server_id,
           "version" => version,
           "operation" => operation,
           "profile" => state.profile,
           "payload" => envelope.payload,
           "digest" => envelope.payload_digest,
           "expected_revision" => expected_revision,
           "published_at" => DateTime.to_iso8601(published_at)
         }
       }}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp validate_delivery(_envelope, _state), do: invalid()

  defp manifest_for_staging(state) do
    case read_final(manifest_path(state), state) do
      {:ok, manifest} -> decode_manifest(manifest, state)
      {:error, %Error{code: :not_found}} -> {:ok, %{current: nil, previous: nil}}
      {:error, %Error{}} = error -> error
    end
  end

  defp read_manifest(state) do
    with {:ok, manifest} <- read_final(manifest_path(state), state) do
      decode_manifest(manifest, state)
    end
  end

  defp read_version(path, state) do
    case read_final(path, state) do
      {:error, %Error{code: :not_found}} -> invalid()
      other -> other
    end
  end

  defp validate_staged_versions(%{current: current, previous: previous}, state) do
    with :ok <- validate_staged_version(current, state),
         :ok <- validate_staged_version(previous, state) do
      :ok
    end
  end

  defp validate_staged_versions(_manifest, _state), do: invalid()

  defp validate_staged_version(nil, _state), do: :ok

  defp validate_staged_version(pointer, state) do
    with {:ok, _document} <- read_manifest_version(pointer, state) do
      :ok
    end
  end

  defp read_manifest_version(pointer, state) do
    path = version_path(state, pointer.version, pointer.digest)

    with {:ok, document} <- read_version(path, state),
         {:ok, document} <- validate_immutable(document, pointer, path, state) do
      {:ok, document}
    end
  end

  defp next_manifest(%{current: nil, previous: nil}, config) do
    {:ok, %{current: pointer(config), previous: nil}, true}
  end

  defp next_manifest(%{current: %{version: version, digest: digest}} = manifest, config)
       when version == config.version and digest == config.digest do
    {:ok, manifest, false}
  end

  defp next_manifest(%{current: %{version: version}}, %{version: incoming})
       when incoming <= version,
       do: conflict()

  defp next_manifest(%{current: current}, config) do
    {:ok, %{current: pointer(config), previous: current}, true}
  end

  defp replace_manifest_if_needed(false, _manifest, _state), do: :ok

  defp replace_manifest_if_needed(true, manifest, state) do
    case replace_manifest(manifest_document(manifest, state), state) do
      {:ok, _path} -> :ok
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp decode_manifest(manifest, state) when is_map(manifest) do
    server_id = state.server_id

    with true <- Enum.sort(Map.keys(manifest)) == @manifest_keys,
         1 <- manifest["schema_version"],
         "server" <- manifest["target_type"],
         ^server_id <- manifest["target_id"],
         {:ok, current} <- decode_pointer(manifest["current"]),
         {:ok, previous} <- decode_pointer(manifest["previous"]),
         :ok <- coherent_pointers(current, previous) do
      {:ok, %{current: current, previous: previous}}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp decode_manifest(_manifest, _state), do: invalid()

  defp decode_pointer(nil), do: {:ok, nil}

  defp decode_pointer(pointer) when is_map(pointer) do
    with true <- Enum.sort(Map.keys(pointer)) == @pointer_keys,
         {:ok, version} <- version(pointer["version"]),
         {:ok, digest} <- Digest.validate(pointer["digest"]) do
      {:ok, %{version: version, digest: digest}}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp decode_pointer(_pointer), do: invalid()

  defp coherent_pointers(nil, nil), do: :ok
  defp coherent_pointers(%{version: _current}, nil), do: :ok

  defp coherent_pointers(%{version: current}, %{version: previous}) when previous < current,
    do: :ok

  defp coherent_pointers(_current, _previous), do: invalid()

  defp selected_pointer(manifest, selector) do
    case Map.fetch(manifest, selector) do
      {:ok, nil} -> not_found()
      {:ok, pointer} -> {:ok, pointer}
      :error -> invalid()
    end
  end

  defp validate_immutable(document, pointer, path, state) when is_map(document) do
    with true <- Enum.sort(Map.keys(document)) == @immutable_keys,
         1 <- document["schema_version"],
         "server" <- document["target_type"],
         true <- document["target_id"] == state.server_id,
         true <- document["version"] == pointer.version,
         true <- document["digest"] == pointer.digest,
         :ok <- Digest.verify(document["payload"], document["digest"]),
         {:ok, operation} <- config_operation(document["operation"], document["payload"]),
         true <- operation == document["operation"],
         true <- document["profile"] == state.profile,
         {:ok, _expected_revision} <- optional_digest(document["expected_revision"]),
         {:ok, _published_at} <- utc_datetime(document["published_at"]),
         true <- path == version_path(state, pointer.version, pointer.digest) do
      {:ok, document}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp validate_immutable(_document, _pointer, _path, _state), do: invalid()

  defp state_from_options(opts) when is_list(opts) do
    allowed = [:name, :data_dir, :server_id, :profile, :max_bytes, :storage_opts]

    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
         {:ok, data_dir} <- absolute_data_dir(Keyword.get(opts, :data_dir)),
         {:ok, server_id} <- nonempty_id(Keyword.get(opts, :server_id)),
         {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, storage_opts} <- storage_options(opts) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         server_id: server_id,
         profile: profile,
         storage_opts: storage_opts
       }}
    else
      _other -> :error
    end
  end

  defp state_from_options(_opts), do: :error

  defp storage_options(opts) do
    storage_opts = Keyword.get(opts, :storage_opts, [])

    with true <- is_list(storage_opts),
         true <- Keyword.keyword?(storage_opts),
         {:ok, storage_opts} <- maybe_put_max_bytes(storage_opts, Keyword.fetch(opts, :max_bytes)) do
      {:ok, storage_opts}
    else
      _other -> :error
    end
  end

  defp maybe_put_max_bytes(storage_opts, :error), do: {:ok, storage_opts}

  defp maybe_put_max_bytes(storage_opts, {:ok, max_bytes})
       when is_integer(max_bytes) and max_bytes > 0,
       do: {:ok, Keyword.put(storage_opts, :max_bytes, max_bytes)}

  defp maybe_put_max_bytes(_storage_opts, _max_bytes), do: :error

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)

    if Path.type(value) == :absolute and expanded == value, do: {:ok, value}, else: :error
  end

  defp absolute_data_dir(_value), do: :error

  defp exact_server(%Envelope{target_type: :server, target_id: target_id}, %{server_id: target_id}),
       do: :ok

  defp exact_server(_envelope, _state), do: invalid()

  defp config_operation(operation, payload) do
    with {:ok, %Operation{target_type: :server, kind: :config} = concrete} <-
           Operation.lookup(operation),
         {:ok, _payload} <- Operation.validate_payload(concrete, payload) do
      {:ok, operation}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp version(value) when is_integer(value) and value >= 1 and value <= @max_version,
    do: {:ok, value}

  defp version(_value), do: invalid()

  defp nonempty_id(value) do
    with {:ok, value} <- Bounds.id(value), true <- value != "" do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp profile(value) when is_atom(value), do: profile(Atom.to_string(value))

  defp profile(value) do
    with {:ok, value} <- nonempty_id(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp valid_profile(value) do
    case profile(value) do
      {:ok, ^value} -> :ok
      _other -> invalid()
    end
  end

  defp optional_digest(nil), do: {:ok, nil}
  defp optional_digest(value), do: Digest.validate(value)

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}

  defp utc_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _other -> invalid()
    end
  end

  defp utc_datetime(_value), do: invalid()

  defp pointer(%{version: version, digest: digest}), do: %{version: version, digest: digest}

  defp manifest_document(%{current: current, previous: previous}, state) do
    %{
      "schema_version" => 1,
      "target_type" => "server",
      "target_id" => state.server_id,
      "current" => encode_pointer(current),
      "previous" => encode_pointer(previous)
    }
  end

  defp encode_pointer(nil), do: nil

  defp encode_pointer(%{version: version, digest: digest}),
    do: %{"version" => version, "digest" => digest}

  defp create_version(path, document, state) do
    with :ok <- checked_final_path(path, state),
         {:ok, stored_path} <- Storage.create(path, document, state.storage_opts),
         :ok <- checked_final_path(path, state) do
      {:ok, stored_path}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp replace_manifest(document, state) do
    path = manifest_path(state)

    with :ok <- checked_final_path(path, state),
         {:ok, stored_path} <- Storage.replace(path, document, state.storage_opts),
         :ok <- checked_final_path(path, state) do
      {:ok, stored_path}
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp read_final(path, state) do
    with :ok <- checked_final_path(path, state) do
      Storage.read(path, state.storage_opts)
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp checked_final_path(path, state) do
    with :ok <- ensure_storage_boundary(state),
         :ok <- regular_file_or_missing(path) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp ensure_storage_boundary(state) do
    with :ok <- ensure_owned_directory(state.data_dir),
         :ok <- ensure_owned_directory(server_directory(state)),
         :ok <- ensure_owned_directory(versions_directory(state)) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _other -> invalid()
    end
  end

  defp ensure_owned_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:error, :enoent} -> create_owned_directory(path)
      _other -> invalid()
    end
  end

  defp create_owned_directory(path) do
    case File.mkdir(path) do
      :ok -> ensure_owned_directory(path)
      {:error, :eexist} -> ensure_owned_directory(path)
      _other -> invalid()
    end
  end

  defp regular_file_or_missing(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _other -> invalid()
    end
  end

  defp server_directory(state), do: Path.join(state.data_dir, "server")

  defp versions_directory(state), do: Path.join(server_directory(state), "versions")

  defp manifest_path(state), do: Path.join(server_directory(state), "manifest.json")

  defp version_path(state, version, digest),
    do: Path.join(versions_directory(state), "#{version}-#{digest}.json")

  defp invalid,
    do: {:error, %Error{code: :invalid, message: "invalid config document", details: %{}}}

  defp conflict,
    do: {:error, %Error{code: :conflict, message: "config version conflicts", details: %{}}}

  defp not_found,
    do: {:error, %Error{code: :not_found, message: "staged config not found", details: %{}}}
end
