defmodule YellowDog.Management.MacDatabase do
  use GenServer

  alias GSMLG.MAC.{Compiler, Parser, Vendor}

  @max_file_bytes 64 * 1024 * 1024
  @read_chunk_bytes 1024 * 1024
  @load_timeout 30_000
  @mac_pattern ~r/\A(?:[a-fA-F0-9]{12}|[a-fA-F0-9]{2}(?::[a-fA-F0-9]{2}){5}|[a-fA-F0-9]{2}(?:-[a-fA-F0-9]{2}){5}|[a-fA-F0-9]{4}(?:\.[a-fA-F0-9]{4}){2})\z/
  @prefix_pattern ~r/\A(?:[a-fA-F0-9]{2}(?::[a-fA-F0-9]{2}){2,5}|[a-fA-F0-9]{2}(?:-[a-fA-F0-9]{2}){2,5}|(?:[a-fA-F0-9]{2}){3,6})(?:\/(?:2[4-9]|3[0-9]|4[0-8]))?\z/

  def start_link(opts) do
    options =
      if Keyword.has_key?(opts, :name) and opts[:name] == nil,
        do: [],
        else: [name: Keyword.get(opts, :name, __MODULE__)]

    GenServer.start_link(__MODULE__, Keyword.get(opts, :path), options)
  end

  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  def lookup(mac, server \\ __MODULE__) do
    with {:ok, address} <- parse_mac(mac) do
      GenServer.call(server, {:lookup, address})
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload, :infinity)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(path) do
    Process.flag(:trap_exit, true)
    path = if is_binary(path) and path != "", do: Path.expand(path), else: nil

    state = %{
      source: :compiled,
      status: :loaded,
      entry_count: Vendor.entries(),
      loaded_at: DateTime.utc_now(),
      path: path,
      configured: path != nil,
      file_info: nil,
      last_error: nil,
      table: Vendor.mac_lookup_table(),
      loader: nil
    }

    {:ok, state, {:continue, :load_configured}}
  end

  @impl true
  def handle_continue(:load_configured, state) do
    {:noreply, if(state.configured, do: start_load(state, nil), else: state)}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.drop(state, [:table, :loader]), state}
  end

  def handle_call({:lookup, <<key::bits-size(24), _rest::bits-size(24)>> = address}, _from, state) do
    result =
      case state.table[key] do
        vendor when is_list(vendor) ->
          vendor_result(vendor)

        {width, entries} when width in 24..48 ->
          <<prefix::bits-size(width), _rest::bits>> = address
          vendor_result(entries[prefix])

        _entry ->
          :error
      end

    {:reply, result, state}
  end

  def handle_call(:reload, _from, %{configured: false} = state),
    do: {:reply, {:error, :unconfigured}, state}

  def handle_call(:reload, _from, %{loader: loader} = state) when loader != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call(:reload, from, state), do: {:noreply, start_load(state, from)}
  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def handle_info({:load_result, token, result}, %{loader: %{token: token}} = state) do
    {:noreply, finish_load(state, result)}
  end

  def handle_info({:load_timeout, token}, %{loader: %{token: token, pid: loader_pid}} = state) do
    Process.exit(loader_pid, :kill)
    {:noreply, finish_load(state, {:error, :load_timeout})}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{loader: %{monitor: monitor}} = state
      ) do
    {:noreply, finish_load(state, {:error, :loader_failed})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{loader: nil}), do: :ok

  def terminate(_reason, %{loader: loader}) do
    stop_loader(loader)
    if loader.from, do: GenServer.reply(loader.from, {:error, :cancelled})
  end

  defp start_load(state, from) do
    owner = self()
    token = make_ref()
    path = state.path

    {:ok, loader_pid} =
      Task.start_link(fn ->
        Process.flag(:max_heap_size, %{size: 8_000_000, kill: true, error_logger: false})
        send(owner, {:load_result, token, load_file(path)})
      end)

    loader = %{
      pid: loader_pid,
      monitor: Process.monitor(loader_pid),
      token: token,
      timer: Process.send_after(owner, {:load_timeout, token}, @load_timeout),
      from: from
    }

    %{state | loader: loader, status: :loading, last_error: nil}
  end

  defp finish_load(state, result) do
    loader = state.loader
    Process.cancel_timer(loader.timer)
    Process.demonitor(loader.monitor, [:flush])
    if loader.from, do: GenServer.reply(loader.from, public_result(result))

    case result do
      {:ok, table, count, stat} ->
        %{
          state
          | source: :file,
            status: :loaded,
            table: table,
            entry_count: count,
            loaded_at: DateTime.utc_now(),
            file_info: %{size: stat.size, mtime: stat.mtime},
            last_error: nil,
            loader: nil
        }

      {:error, reason} ->
        %{state | status: :error, last_error: reason, loader: nil}
    end
  end

  defp public_result({:ok, _table, _count, _stat}), do: :ok
  defp public_result({:error, reason}), do: {:error, reason}

  defp stop_loader(loader) do
    Process.cancel_timer(loader.timer)
    Process.demonitor(loader.monitor, [:flush])
    Process.exit(loader.pid, :kill)
  end

  defp load_file(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         :ok <- regular_file(stat),
         {:ok, read_result} <- File.open(path, [:read, :binary, :raw], &read_bounded(&1, [], 0)),
         {:ok, contents} <- read_result,
         {:ok, expected_count} <- validate_contents(contents) do
      # TODO(upstream): gsmlg-dev/gsmlg_umbrella#8
      table = Compiler.build_lookup_table(contents)
      count = Compiler.count_entries(table)

      if count == expected_count do
        {:ok, table, count, %{stat | size: byte_size(contents)}}
      else
        {:error, :invalid_database}
      end
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

  defp validate_contents(contents) do
    if String.valid?(contents) do
      contents
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{}, MapSet.new()}, &validate_line/2)
      |> case do
        {:ok, _widths, prefixes} ->
          if MapSet.size(prefixes) > 0,
            do: {:ok, MapSet.size(prefixes)},
            else: {:error, :empty_database}

        error ->
          error
      end
    else
      {:error, :invalid_utf8}
    end
  end

  defp validate_line({line, line_number}, {:ok, widths, prefixes}) do
    line = String.trim(line)

    if line == "" or String.starts_with?(line, "#") do
      {:cont, {:ok, widths, prefixes}}
    else
      case parse_record(line) do
        {:ok, <<key::bits-size(24), _rest::bits>> = prefix} ->
          width = bit_size(prefix)

          if Map.has_key?(widths, key) and widths[key] != width do
            {:halt, {:error, :inconsistent_prefix_lengths}}
          else
            {:cont, {:ok, Map.put(widths, key, width), MapSet.put(prefixes, prefix)}}
          end

        :error ->
          {:halt, {:error, {:invalid_entry, line_number}}}
      end
    end
  end

  defp parse_record(line) do
    case String.split(line, "\t") do
      [prefix, short | _names] ->
        if byte_size(prefix) <= 64 and Regex.match?(@prefix_pattern, prefix) and
             String.trim(short) != "" do
          case Parser.parse_line(line) do
            {prefix, _vendor} when bit_size(prefix) in 24..48 -> {:ok, prefix}
            _record -> :error
          end
        else
          :error
        end

      _fields ->
        :error
    end
  end

  defp parse_mac(mac) when is_binary(mac) and byte_size(mac) <= 64 do
    if String.valid?(mac) and Regex.match?(@mac_pattern, String.trim(mac)) do
      {:ok, Parser.to_bitstring(String.trim(mac))}
    else
      {:error, :invalid_mac}
    end
  end

  defp parse_mac(_mac), do: {:error, :invalid_mac}

  defp vendor_result(vendor) when is_list(vendor),
    do: {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}

  defp vendor_result(_vendor), do: :error
end
