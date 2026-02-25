defmodule YellowDog.Resolved.Discovery do
  @moduledoc """
  EDNS discovery and WebSocket management connection for YellowDog DNS servers.

  On startup, sends EDNS0 probes (option code 65321) to each configured upstream.
  If an upstream responds with a valid EDNS 65321 option containing a WebSocket path,
  the discovery module establishes a management WebSocket connection.

  Non-YellowDog upstreams are gracefully ignored.
  """

  use GenServer

  require Logger

  @edns_option_code 65321
  @edns_version 1

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Get the current discovery state."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    instance_id = :crypto.strong_rand_bytes(16)

    state = %{
      upstreams: config.upstreams,
      instance_id: instance_id,
      ws_endpoint: nil,
      ws_config: config.discovery.websocket,
      management_pid: nil,
      backoff: config.discovery.websocket.reconnect_base_s,
      probe_timeout_ms: config.upstream_timeout_ms
    }

    # Probe upstreams after a short delay to let other services start
    Process.send_after(self(), :probe, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      instance_id: Base.encode16(state.instance_id, case: :lower),
      ws_endpoint: state.ws_endpoint,
      connected: state.management_pid != nil and Process.alive?(state.management_pid)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state = probe_upstreams(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = probe_upstreams(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{management_pid: pid} = state) do
    Logger.info("Management connection lost: #{inspect(reason)}")

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :disconnected],
      %{},
      %{reason: reason}
    )

    # Schedule reconnect with backoff
    backoff = state.backoff
    Process.send_after(self(), :reconnect, backoff * 1000)

    new_backoff = min(backoff * 2, state.ws_config.reconnect_max_s)
    {:noreply, %{state | management_pid: nil, ws_endpoint: nil, backoff: new_backoff}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp probe_upstreams(state) do
    Enum.reduce_while(state.upstreams, state, fn upstream, acc ->
      :telemetry.execute(
        [:yellow_dog, :resolved, :discovery, :probe],
        %{},
        %{upstream: upstream}
      )

      case probe_upstream(upstream, acc) do
        {:found, ws_endpoint} ->
          Logger.info("YellowDog DNS discovered at #{:inet.ntoa(upstream)}: #{ws_endpoint}")

          :telemetry.execute(
            [:yellow_dog, :resolved, :discovery, :found],
            %{},
            %{upstream: upstream, ws_endpoint: ws_endpoint}
          )

          new_state = start_management_connection(acc, ws_endpoint)
          {:halt, new_state}

        :not_found ->
          :telemetry.execute(
            [:yellow_dog, :resolved, :discovery, :not_found],
            %{},
            %{upstream: upstream}
          )

          {:cont, acc}
      end
    end)
  end

  defp probe_upstream(upstream, state) do
    # Build a discovery DNS query with EDNS option 65321
    query = build_discovery_query(state.instance_id)
    query_binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

    case Abyss.Client.send_recv(upstream, 53, query_binary, state.probe_timeout_ms) do
      {:ok, response_binary} ->
        parse_discovery_response(response_binary)

      {:error, _reason} ->
        :not_found
    end
  end

  defp build_discovery_query(instance_id) do
    query = DNS.Message.new()

    query =
      query
      |> DNS.Message.update_header_attr(:id, DNS.Message.Header.generate_id())
      |> DNS.Message.update_header_attr(:rd, 1)
      |> DNS.Message.add_question(DNS.Message.Question.new("_yellowdog._tcp.local", 33, 1))

    # Add EDNS OPT record with discovery option
    edns_data = <<@edns_version::8, instance_id::binary>>

    opt_record =
      DNS.Message.Record.new(
        ".",
        41,
        4096,
        0,
        DNS.Message.Record.Data.new(DNS.ResourceRecordType.new(41), edns_data)
      )

    Map.update(query, :arlist, [opt_record], &[opt_record | &1])
    |> DNS.Message.update_header_attr(:arcount, 1)
  end

  @doc false
  @spec parse_discovery_response(binary()) :: {:found, String.t()} | :not_found
  def parse_discovery_response(response_binary) do
    try do
      response = DNS.Message.from_iodata(response_binary)

      # Look for EDNS OPT record with option 65321 in additional records
      case find_edns_option(response.arlist) do
        {:ok, ws_path} ->
          # Extract SRV record from answer for host:port
          case find_srv_record(response.anlist) do
            {:ok, host, port} ->
              {:found, "ws://#{host}:#{port}#{ws_path}"}

            :not_found ->
              :not_found
          end

        :not_found ->
          :not_found
      end
    rescue
      _ -> :not_found
    catch
      _, _ -> :not_found
    end
  end

  defp find_edns_option(arlist) do
    Enum.find_value(arlist, :not_found, fn record ->
      if to_string(record.type) == "OPT" do
        case extract_yellowdog_option(record.data) do
          {:ok, ws_path} -> {:ok, ws_path}
          :not_found -> nil
        end
      end
    end)
  end

  defp extract_yellowdog_option(data) do
    raw = if is_map(data), do: Map.get(data, :raw, <<>>), else: <<>>

    case raw do
      <<@edns_version::8, ws_path::binary>> when byte_size(ws_path) > 0 ->
        {:ok, ws_path}

      _ ->
        :not_found
    end
  end

  defp find_srv_record(anlist) do
    Enum.find_value(anlist, :not_found, fn record ->
      if to_string(record.type) == "SRV" do
        case record.data do
          %{data: {_priority, _weight, port, domain}} ->
            {:ok, to_string(domain), port}

          _ ->
            nil
        end
      end
    end)
  end

  defp start_management_connection(state, ws_endpoint) do
    case YellowDog.Resolved.Management.Client.start_link(%{
           endpoint: ws_endpoint,
           instance_id: state.instance_id,
           ws_config: state.ws_config
         }) do
      {:ok, pid} ->
        Process.monitor(pid)

        :telemetry.execute(
          [:yellow_dog, :resolved, :management, :connected],
          %{},
          %{endpoint: ws_endpoint}
        )

        # Reset backoff on successful connection
        %{
          state
          | management_pid: pid,
            ws_endpoint: ws_endpoint,
            backoff: state.ws_config.reconnect_base_s
        }

      {:error, reason} ->
        Logger.warning("Failed to start management connection: #{inspect(reason)}")
        state
    end
  end

  @doc "Encode the EDNS option data for discovery probe."
  @spec encode_edns_option(binary()) :: binary()
  def encode_edns_option(instance_id) do
    # Option Code (2 bytes) + Option Length (2 bytes) + Option Data
    data = <<@edns_version::8, instance_id::binary>>
    <<@edns_option_code::16, byte_size(data)::16, data::binary>>
  end

  @doc "Decode an EDNS discovery response option."
  @spec decode_edns_option(binary()) :: {:ok, %{version: integer(), data: binary()}} | :error
  def decode_edns_option(<<@edns_option_code::16, length::16, data::binary-size(length)>>) do
    case data do
      <<version::8, payload::binary>> ->
        {:ok, %{version: version, data: payload}}

      _ ->
        :error
    end
  end

  def decode_edns_option(_), do: :error
end
