defmodule YellowDog.Management.GeoIP do
  use GenServer

  @types [:city, :country]
  @max_file_bytes 256 * 1024 * 1024
  @read_chunk_bytes 1024 * 1024
  @load_timeout 30_000

  def start_link(opts) do
    options =
      if opts[:name] == nil and Keyword.has_key?(opts, :name),
        do: [],
        else: [name: opts[:name] || __MODULE__]

    GenServer.start_link(__MODULE__, opts, options)
  end

  def lookup(ip_string, type \\ :city, server \\ __MODULE__)

  def lookup(ip_string, type, server) when type in @types do
    with {:ok, address} <- parse_ip(ip_string),
         {:ok, {metadata, tree, data}} <- call(server, {:database, type}) do
      lookup_data(address, metadata, tree, data)
    end
  end

  def lookup(_ip_string, _type, _server), do: {:error, :invalid_type}

  def info(server \\ __MODULE__), do: call(server, :info)

  def reload(type, server \\ __MODULE__)
  def reload(type, server) when type in @types, do: call(server, {:reload, type}, :infinity)
  def reload(_type, _server), do: {:error, :invalid_type}

  def unload(type, server \\ __MODULE__)
  def unload(type, server) when type in @types, do: call(server, {:unload, type})
  def unload(_type, _server), do: {:error, :invalid_type}

  def activate(type, path, authority, server \\ __MODULE__)
      when type in @types and is_binary(path) and is_function(authority, 1),
      do: call(server, {:activate, type, Path.expand(path), authority}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    paths = Keyword.get(opts, :paths, %{})

    selected =
      if opts[:restore_selection],
        do: YellowDog.Management.TaskArtifacts.selected_artifacts(),
        else: %{}

    entries =
      Map.new(@types, fn type ->
        artifact = selected[type]
        path = if artifact, do: artifact.path, else: Map.get(paths, type)
        path = if is_binary(path) and path != "", do: Path.expand(path), else: nil

        {type,
         %{
           name: type,
           path: path,
           digest: if(artifact, do: artifact.digest, else: nil),
           pinned_digest: if(artifact, do: artifact.digest, else: nil),
           status: if(path, do: :unloaded, else: :unconfigured),
           database: nil,
           metadata: %{},
           file_size: nil,
           modified_at: nil,
           loaded_at: nil,
           last_error: nil,
           loader: nil
         }}
      end)

    {:ok, entries, {:continue, :load_configured}}
  end

  @impl true
  def handle_continue(:load_configured, entries) do
    {:noreply,
     Map.new(entries, fn {type, entry} ->
       {type, if(entry.path, do: start_load(type, entry, nil), else: entry)}
     end)}
  end

  @impl true
  def handle_call(:info, _from, entries) do
    result =
      Enum.map(@types, fn type ->
        entry = entries[type]

        entry
        |> Map.drop([:database, :loader, :pinned_digest])
        |> Map.put(:loaded, entry.database != nil)
        |> Map.put(:configured, entry.path != nil)
      end)

    {:reply, result, entries}
  end

  def handle_call({:database, type}, _from, entries) when type in @types do
    entry = entries[type]

    result =
      cond do
        entry.database != nil -> {:ok, entry.database}
        entry.path == nil -> {:error, :unconfigured}
        entry.loader != nil -> {:error, :loading}
        true -> {:error, :not_loaded}
      end

    {:reply, result, entries}
  end

  def handle_call({:reload, type}, from, entries) when type in @types do
    entry = entries[type]

    cond do
      entry.path == nil -> {:reply, {:error, :unconfigured}, entries}
      entry.loader != nil -> {:reply, {:error, :busy}, entries}
      true -> {:noreply, Map.put(entries, type, start_load(type, entry, from))}
    end
  end

  def handle_call({:unload, type}, _from, entries) when type in @types do
    entry = entries[type]
    cancel_loader(entry.loader)

    entry =
      %{
        entry
        | database: nil,
          metadata: %{},
          file_size: nil,
          modified_at: nil,
          loaded_at: nil,
          last_error: nil,
          loader: nil,
          status: if(entry.path, do: :unloaded, else: :unconfigured)
      }

    {:reply, :ok, Map.put(entries, type, entry)}
  end

  def handle_call({:activate, type, path, authority}, from, entries) when type in @types do
    entry = entries[type]

    if entry.loader do
      {:reply, {:error, :busy}, entries}
    else
      {:noreply, Map.put(entries, type, start_load(type, entry, from, path, authority))}
    end
  end

  def handle_call(_request, _from, entries), do: {:reply, {:error, :invalid_type}, entries}

  @impl true
  def handle_info({:load_result, type, token, result}, entries) when type in @types do
    case entries[type].loader do
      %{token: ^token} -> {:noreply, finish_load(entries, type, result)}
      _loader -> {:noreply, entries}
    end
  end

  def handle_info({:load_timeout, type, token}, entries) when type in @types do
    case entries[type].loader do
      %{token: ^token, pid: loader_pid} ->
        Process.exit(loader_pid, :kill)
        {:noreply, finish_load(entries, type, {:error, :load_timeout})}

      _loader ->
        {:noreply, entries}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, entries) do
    case Enum.find(@types, fn type ->
           entries[type].loader != nil and entries[type].loader.monitor == monitor_ref
         end) do
      nil -> {:noreply, entries}
      type -> {:noreply, finish_load(entries, type, {:error, :loader_failed})}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, entries), do: {:noreply, entries}
  def handle_info(_message, entries), do: {:noreply, entries}

  @impl true
  def terminate(_reason, entries) do
    Enum.each(entries, fn {_type, entry} -> cancel_loader(entry.loader) end)
  end

  defp start_load(type, entry, from, candidate_path \\ nil, authority \\ nil) do
    owner = self()
    token = make_ref()
    path = candidate_path || entry.path

    {:ok, loader_pid} =
      Task.start_link(fn ->
        Process.flag(:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false})
        send(owner, {:load_result, type, token, load_file(path)})
      end)

    loader = %{
      pid: loader_pid,
      monitor: Process.monitor(loader_pid),
      token: token,
      timer: Process.send_after(owner, {:load_timeout, type, token}, @load_timeout),
      from: from,
      path: path,
      authority: authority,
      expected_digest: if(candidate_path, do: nil, else: entry.pinned_digest)
    }

    %{entry | loader: loader, status: :loading, last_error: nil}
  end

  defp finish_load(entries, type, result) do
    entry = entries[type]
    Process.cancel_timer(entry.loader.timer)
    Process.demonitor(entry.loader.monitor, [:flush])
    result = authorize(result, entry.loader)

    updated =
      case result do
        {:ok, database, stat, digest} ->
          %{
            entry
            | path: entry.loader.path,
              digest: digest,
              pinned_digest: if(entry.loader.authority, do: digest, else: entry.pinned_digest),
              database: database,
              metadata: database |> elem(0) |> Map.from_struct(),
              file_size: stat.size,
              modified_at: stat.mtime,
              loaded_at: DateTime.utc_now(),
              status: :loaded,
              last_error: nil,
              loader: nil
          }

        {:error, reason} ->
          %{entry | status: :error, last_error: reason, loader: nil}
      end

    if entry.loader.from, do: GenServer.reply(entry.loader.from, public_result(result))
    Map.put(entries, type, updated)
  end

  defp authorize({:ok, _database, _stat, digest}, %{expected_digest: expected})
       when is_binary(expected) and digest != expected,
       do: {:error, :artifact_digest_mismatch}

  defp authorize({:ok, database, stat, digest} = result, %{authority: authority, path: path})
       when is_function(authority, 1) do
    case authority.(%{
           path: path,
           digest: digest,
           size: stat.size,
           metadata: database |> elem(0) |> Map.from_struct()
         }) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :selection_commit_failed}
  catch
    _kind, _reason -> {:error, :selection_commit_failed}
  end

  defp authorize(result, _loader), do: result

  defp public_result({:ok, _database, _stat, _digest}), do: :ok
  defp public_result({:error, reason}), do: {:error, reason}

  defp cancel_loader(nil), do: :ok

  defp cancel_loader(loader) do
    Process.cancel_timer(loader.timer)
    Process.demonitor(loader.monitor, [:flush])
    Process.exit(loader.pid, :kill)
    if loader.from, do: GenServer.reply(loader.from, {:error, :cancelled})
    :ok
  end

  defp load_file(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         :ok <- regular_file(stat),
         {:ok, read_result} <-
           File.open(path, [:read, :binary, :raw], &read_bounded(&1, [], 0)),
         {:ok, contents} <- read_result,
         {:ok, metadata, tree, data} <- MMDB2Decoder.parse_database(contents),
         :ok <- valid_metadata(metadata) do
      digest = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
      {:ok, {metadata, tree, data}, %{stat | size: byte_size(contents)}, digest}
    end
  rescue
    _exception -> {:error, :invalid_database}
  catch
    _kind, _reason -> {:error, :invalid_database}
  end

  defp regular_file(%{type: :regular, size: size}) when size <= @max_file_bytes, do: :ok
  defp regular_file(%{type: :regular}), do: {:error, :too_large}
  defp regular_file(_stat), do: {:error, :not_regular_file}

  defp read_bounded(file, chunks, total) do
    case :file.read(file, @read_chunk_bytes) do
      {:ok, chunk} when total + byte_size(chunk) <= @max_file_bytes ->
        read_bounded(file, [chunk | chunks], total + byte_size(chunk))

      {:ok, _chunk} ->
        {:error, :too_large}

      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_metadata(%{
         binary_format_major_version: 2,
         ip_version: version,
         record_size: record_size,
         node_count: node_count
       })
       when version in [4, 6] and record_size in [24, 28, 32] and
              is_integer(node_count) and node_count > 0,
       do: :ok

  defp valid_metadata(_metadata), do: {:error, :invalid_database}

  defp parse_ip(ip_string) when is_binary(ip_string) and byte_size(ip_string) <= 64 do
    if String.valid?(ip_string) do
      case ip_string |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
        {:ok, address} -> {:ok, address}
        {:error, _reason} -> {:error, :invalid_ip}
      end
    else
      {:error, :invalid_ip}
    end
  end

  defp parse_ip(_ip_string), do: {:error, :invalid_ip}

  defp lookup_data(address, metadata, tree, data) do
    case MMDB2Decoder.find_pointer(address, metadata, tree) do
      {:ok, pointer} when pointer < 0 ->
        {:error, :not_found}

      {:ok, _pointer} ->
        case MMDB2Decoder.lookup(address, metadata, tree, data, %{map_keys: :strings}) do
          {:ok, raw} when is_map(raw) -> {:ok, normalize(raw)}
          {:ok, nil} -> {:error, :not_found}
          {:ok, _value} -> {:error, :invalid_database}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _exception -> {:error, :invalid_database}
  catch
    _kind, _reason -> {:error, :invalid_database}
  end

  defp normalize(raw) do
    subdivision =
      case raw["subdivisions"] do
        [first | _rest] -> get_in(first, ["names", "en"])
        _subdivisions -> nil
      end

    %{
      city: get_in(raw, ["city", "names", "en"]),
      country: get_in(raw, ["country", "names", "en"]),
      country_code: get_in(raw, ["country", "iso_code"]),
      continent: get_in(raw, ["continent", "names", "en"]),
      continent_code: get_in(raw, ["continent", "code"]),
      latitude: get_in(raw, ["location", "latitude"]),
      longitude: get_in(raw, ["location", "longitude"]),
      timezone: get_in(raw, ["location", "time_zone"]),
      postal_code: get_in(raw, ["postal", "code"]),
      subdivision: subdivision
    }
  end

  defp call(server, request, timeout \\ 5000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
