defmodule YellowDog.Management.GeoIPDownload do
  @moduledoc """
  Downloads a bounded gzip MMDB into an immutable, digest-addressed artifact.

  Options `:timeout`, `:max_compressed_bytes` and `:max_decompressed_bytes` may
  lower the 120 second, 64 MiB and 256 MiB ceilings. `:url` is a controlled
  caller/test injection; it must not come from public request parameters.
  """

  @compressed_limit 64 * 1024 * 1024
  @decompressed_limit 256 * 1024 * 1024
  @timeout 120_000
  @chunk_size 16 * 1024

  @doc "Verify a durable immutable artifact without retaining a lookup database."
  def verify(type, %{path: path, digest: digest, size: size}) when type in [:city, :country] do
    safely(fn ->
      contents = artifact_contents(path, size)
      actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      if actual != digest, do: fail(:artifact_digest_mismatch)
      {:ok, validate_contents(contents, type)}
    end)
  end

  def verify(_type, _artifact), do: {:error, :invalid_artifact}

  @doc "Check availability by hashing bounded immutable bytes; publication already validates their format."
  def check_artifact(%{path: path, digest: digest, size: size}) do
    safely(fn ->
      artifact_stat(path, size)

      with_file(path, [:read, :binary, :raw], fn input ->
        actual = hash_file(input, :crypto.hash_init(:sha256))
        if actual != digest, do: fail(:artifact_digest_mismatch)
      end)

      :ok
    end)
  end

  def check_artifact(_artifact), do: {:error, :invalid_artifact}

  defp artifact_contents(path, size) do
    artifact_stat(path, size)
    with_file(path, [:read, :binary, :raw], fn input -> read_artifact(input, [], 0, size) end)
  end

  defp artifact_stat(path, size)
       when is_integer(size) and size > 0 and size <= @decompressed_limit do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: ^size, mode: mode}} when :erlang.band(mode, 0o222) == 0 ->
        :ok

      {:error, reason} ->
        fail({:file_error, reason})

      _other ->
        fail(:invalid_artifact_file)
    end
  end

  defp artifact_stat(_path, _size), do: fail(:invalid_artifact_size)

  defp read_artifact(input, chunks, total, expected) do
    case :file.read(input, @chunk_size) do
      {:ok, bytes} when total + byte_size(bytes) <= expected ->
        read_artifact(input, [bytes | chunks], total + byte_size(bytes), expected)

      :eof when total == expected ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {:error, reason} ->
        fail({:file_error, reason})

      _other ->
        fail(:invalid_artifact_size)
    end
  end

  def fetch(type, directory, opts \\ []) do
    with {:ok, config} <- configuration(type, directory, opts) do
      caller = self()
      reference = make_ref()
      {owner, monitor} = spawn_monitor(fn -> own_download(caller, reference, config) end)

      receive do
        {^reference, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^owner, reason} ->
          {:error, {:download_process, reason}}
      end
    end
  end

  defp configuration(type, _directory, _opts) when type not in [:city, :country],
    do: {:error, :invalid_type}

  defp configuration(type, directory, opts) when is_binary(directory) and is_list(opts) do
    allowed = [:url, :timeout, :max_compressed_bytes, :max_decompressed_bytes]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Enum.uniq(Keyword.keys(opts))) == length(opts) do
      config = %{
        type: type,
        directory: Path.expand(directory),
        url: Keyword.get(opts, :url, default_url(type)),
        timeout: Keyword.get(opts, :timeout, @timeout),
        compressed_limit: Keyword.get(opts, :max_compressed_bytes, @compressed_limit),
        decompressed_limit: Keyword.get(opts, :max_decompressed_bytes, @decompressed_limit)
      }

      cond do
        directory == "" or String.contains?(directory, <<0>>) ->
          {:error, :invalid_directory}

        not bounded?(config.timeout, @timeout) or
          not bounded?(config.compressed_limit, @compressed_limit) or
            not bounded?(config.decompressed_limit, @decompressed_limit) ->
          {:error, :invalid_options}

        true ->
          case valid_url(config.url) do
            {:ok, uri} -> {:ok, Map.put(config, :uri, uri)}
            error -> error
          end
      end
    else
      {:error, :invalid_options}
    end
  end

  defp configuration(_type, _directory, _opts), do: {:error, :invalid_options}

  defp bounded?(value, maximum), do: is_integer(value) and value > 0 and value <= maximum

  defp default_url(type) do
    date = Date.utc_today()
    month = String.pad_leading(Integer.to_string(date.month), 2, "0")
    "https://download.db-ip.com/free/dbip-#{type}-lite-#{date.year}-#{month}.mmdb.gz"
  end

  defp valid_url(url) when is_binary(url) and byte_size(url) <= 4096 do
    with true <- String.valid?(url) and not Regex.match?(~r/[\x00-\x20\x7f]/, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- is_integer(uri.port) and uri.port in 1..65_535 do
      {:ok, uri}
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp valid_url(_url), do: {:error, :invalid_url}

  defp own_download(caller, reference, config) do
    caller_monitor = Process.monitor(caller)
    config = Map.put(config, :deadline, System.monotonic_time(:millisecond) + config.timeout)
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    compressed = Path.join(config.directory, ".geo-ip-#{suffix}.gz.tmp")
    inflated = Path.join(config.directory, ".geo-ip-#{suffix}.mmdb.tmp")
    owner = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        result =
          safely(fn ->
            ensure_ok(File.mkdir_p(config.directory))
            download(compressed, inflated, config)
          end)

        send(owner, {:download_result, self(), result})
      end)

    timer = Process.send_after(self(), :download_timeout, config.timeout)

    result = await_download(worker, worker_monitor, caller_monitor)

    Process.cancel_timer(timer)
    shutdown_monitor = Process.monitor(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^shutdown_monitor, :process, ^worker, _reason} -> :ok
    end

    File.rm(compressed)
    File.rm(inflated)
    Process.demonitor(worker_monitor, [:flush])
    Process.demonitor(caller_monitor, [:flush])
    send(caller, {reference, result})
  end

  defp await_download(worker, worker_monitor, caller_monitor) do
    receive do
      {:download_result, ^worker, result} -> result
      {:DOWN, ^worker_monitor, :process, ^worker, reason} -> {:error, {:download_process, reason}}
      {:DOWN, ^caller_monitor, :process, _caller, _reason} -> {:error, :cancelled}
      :download_timeout -> {:error, :timeout}
    end
  end

  defp connect(config) do
    transport = [
      timeout: remaining_timeout(config),
      buffer: @chunk_size,
      recbuf: @chunk_size
    ]

    {scheme, transport} =
      case config.uri.scheme do
        "https" ->
          {:https,
           transport ++
             [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: String.to_charlist(config.uri.host),
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ]}

        "http" ->
          {:http, transport}
      end

    case Mint.HTTP.connect(scheme, config.uri.host, config.uri.port,
           mode: :passive,
           protocols: [:http1],
           max_header_list_size: 32_768,
           transport_opts: transport
         ) do
      {:ok, connection} -> connection
      {:error, reason} -> fail(http_failure(reason))
    end
  end

  defp download(compressed, inflated, config) do
    with_file(compressed, [:write, :binary, :raw, :exclusive], fn output ->
      connection = connect(config)

      try do
        path = if config.uri.path in [nil, ""], do: "/", else: config.uri.path
        path = if is_nil(config.uri.query), do: path, else: path <> "?" <> config.uri.query
        headers = [{"accept-encoding", "identity"}, {"connection", "close"}]

        case Mint.HTTP.request(connection, "GET", path, headers, nil) do
          {:ok, connection, request} ->
            state = %{status: nil, headers: false, expected: nil, size: 0, done: false}
            stream(connection, request, output, config, state)

          {:error, _connection, reason} ->
            fail(http_failure(reason))
        end
      after
        Mint.HTTP.close(connection)
      end
    end)

    {digest, size} = inflate(compressed, inflated, config.decompressed_limit)
    metadata = validate_database(inflated, config.type)
    path = Path.join(config.directory, "#{digest}.mmdb")
    remaining_timeout(config)
    publish(inflated, path, digest, size)
    sync_directory(config.directory)

    {:ok, %{path: path, digest: digest, size: size, source_url: config.url, metadata: metadata}}
  end

  defp stream(connection, request, output, config, state) do
    case Mint.HTTP.recv(connection, 0, remaining_timeout(config)) do
      {:ok, connection, responses} ->
        state = consume(responses, request, output, config.compressed_limit, state)

        if state.done do
          finish_transfer(state)
        else
          stream(connection, request, output, config, state)
        end

      {:error, _connection, reason, _responses} ->
        fail(http_failure(reason))
    end
  end

  defp consume(responses, request, output, limit, state) do
    Enum.reduce(responses, state, fn response, state ->
      case response do
        {:status, ^request, 200} when is_nil(state.status) ->
          %{state | status: 200}

        {:status, ^request, status} ->
          fail({:http_status, status})

        {:headers, ^request, headers} when state.status == 200 and not state.headers ->
          %{state | headers: true, expected: check_headers(headers, limit)}

        {:headers, ^request, headers} when state.headers ->
          check_headers(headers, limit)
          state

        {:data, ^request, chunk} when state.status == 200 and state.headers and not state.done ->
          next_size = state.size + byte_size(chunk)
          if next_size > limit, do: fail(:compressed_limit)
          ensure_ok(:file.write(output, chunk))
          %{state | size: next_size}

        {:done, ^request} when state.status == 200 and state.headers ->
          %{state | done: true}

        _ ->
          fail(:invalid_http_response)
      end
    end)
  end

  defp finish_transfer(state) do
    if state.size == 0 or (not is_nil(state.expected) and state.size != state.expected),
      do: fail(:truncated_transfer)

    :ok
  end

  defp remaining_timeout(config) do
    remaining = config.deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: fail(:timeout)
    remaining
  end

  defp http_failure(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp http_failure(:timeout), do: :timeout
  defp http_failure(reason), do: {:http_error, reason}

  defp check_headers(headers, limit) do
    headers =
      Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)

    if Map.has_key?(headers, "content-range") or
         String.starts_with?(
           String.downcase(headers["content-type"] || ""),
           "multipart/byteranges"
         ) do
      fail(:partial_response)
    end

    if headers["content-encoding"] not in [nil, "identity"], do: fail(:unexpected_encoding)

    case headers["content-length"] do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 and size <= limit -> size
          {size, ""} when size > limit -> fail(:compressed_limit)
          _ -> fail(:invalid_content_length)
        end
    end
  end

  defp inflate(compressed, inflated, limit) do
    with_file(compressed, [:read, :binary, :raw], fn input ->
      with_file(inflated, [:write, :binary, :raw, :exclusive], fn output ->
        inflater = :zlib.open()

        try do
          :ok = :zlib.inflateInit(inflater, 31, :error)
          hash = :crypto.hash_init(:sha256)
          {hash, size} = inflate_file(input, output, inflater, limit, hash, 0)
          :ok = :zlib.inflateEnd(inflater)
          ensure_ok(:file.sync(output))
          {Base.encode16(:crypto.hash_final(hash), case: :lower), size}
        catch
          :error, :data_error -> fail(:invalid_gzip)
        after
          :zlib.close(inflater)
        end
      end)
    end)
  end

  defp inflate_file(input, output, inflater, limit, hash, size) do
    case :file.read(input, @chunk_size) do
      {:ok, chunk} ->
        {hash, size} = inflate_chunk(inflater, chunk, output, limit, hash, size)
        inflate_file(input, output, inflater, limit, hash, size)

      :eof ->
        inflate_chunk(inflater, <<>>, output, limit, hash, size)

      {:error, reason} ->
        fail({:file_error, reason})
    end
  end

  defp inflate_chunk(inflater, input, output, limit, hash, size) do
    {status, bytes} = :zlib.safeInflate(inflater, input)
    next_size = size + IO.iodata_length(bytes)
    if next_size > limit, do: fail(:decompressed_limit)
    ensure_ok(:file.write(output, bytes))
    hash = :crypto.hash_update(hash, bytes)

    case status do
      :continue -> inflate_chunk(inflater, <<>>, output, limit, hash, next_size)
      :finished -> {hash, next_size}
    end
  end

  defp validate_database(path, type) do
    contents = unwrap(File.read(path))
    validate_contents(contents, type)
  end

  defp validate_contents(contents, type) do
    parsed =
      try do
        MMDB2Decoder.parse_database(contents)
      rescue
        _error -> fail({:invalid_database, :malformed})
      end

    case parsed do
      {:ok, metadata, _tree, _data} ->
        valid_metadata?(metadata) || fail(:invalid_metadata)

        expected_type?(metadata.database_type, type) ||
          fail({:wrong_dataset, metadata.database_type})

        metadata |> Map.from_struct() |> Jason.encode!() |> Jason.decode!()

      {:error, reason} ->
        fail({:invalid_database, reason})
    end
  end

  defp valid_metadata?(metadata) do
    metadata.binary_format_major_version == 2 and
      is_integer(metadata.binary_format_minor_version) and
      metadata.binary_format_minor_version >= 0 and
      is_integer(metadata.build_epoch) and metadata.build_epoch > 0 and
      metadata.ip_version in [4, 6] and metadata.record_size in [24, 28, 32] and
      is_integer(metadata.node_count) and metadata.node_count > 0 and
      valid_string?(metadata.database_type) and is_map(metadata.description) and
      Enum.all?(metadata.description, fn {key, value} ->
        valid_string?(key) and valid_string?(value)
      end) and
      is_list(metadata.languages) and Enum.all?(metadata.languages, &valid_string?/1)
  end

  defp valid_string?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp expected_type?(database_type, :city),
    do: database_type in ["DBIP-City-Lite", "DBIP-City", "GeoIP2-City", "GeoLite2-City"]

  defp expected_type?(database_type, :country),
    do:
      database_type in ["DBIP-Country-Lite", "DBIP-Country", "GeoIP2-Country", "GeoLite2-Country"]

  defp publish(temporary, path, digest, size) do
    ensure_ok(File.chmod(temporary, 0o444))
    with_file(temporary, [:read, :binary, :raw], &ensure_ok(:file.sync(&1)))

    case File.ln(temporary, path) do
      :ok -> :ok
      {:error, :eexist} -> verify_existing(path, digest, size)
      {:error, reason} -> fail({:file_error, reason})
    end
  end

  defp verify_existing(path, digest, size) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: ^size, mode: mode}} when :erlang.band(mode, 0o222) == 0 ->
        with_file(path, [:read, :binary, :raw], fn input ->
          existing = hash_file(input, :crypto.hash_init(:sha256))
          if existing != digest, do: fail(:artifact_conflict)
          ensure_ok(:file.sync(input))
        end)

      _ ->
        fail(:artifact_conflict)
    end
  end

  defp hash_file(input, hash, total \\ 0) do
    case :file.read(input, @chunk_size) do
      {:ok, bytes} when total + byte_size(bytes) <= @decompressed_limit ->
        hash_file(input, :crypto.hash_update(hash, bytes), total + byte_size(bytes))

      {:ok, _bytes} ->
        fail(:invalid_artifact_size)

      :eof ->
        Base.encode16(:crypto.hash_final(hash), case: :lower)

      {:error, reason} ->
        fail({:file_error, reason})
    end
  end

  defp sync_directory(directory) do
    with_file(directory, [:read, :raw, :directory], &ensure_ok(:file.sync(&1)))
  end

  defp with_file(path, modes, operation) do
    descriptor = unwrap(:file.open(String.to_charlist(path), modes))

    try do
      operation.(descriptor)
    after
      :file.close(descriptor)
    end
  end

  defp ensure_ok(:ok), do: :ok
  defp ensure_ok({:error, reason}), do: fail({:file_error, reason})
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: fail({:file_error, reason})
  defp fail(reason), do: throw({:download_error, reason})

  defp safely(operation) do
    try do
      operation.()
    rescue
      error -> {:error, {:download_failed, Exception.message(error)}}
    catch
      :throw, {:download_error, reason} -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
