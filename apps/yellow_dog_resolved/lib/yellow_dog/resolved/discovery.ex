defmodule YellowDog.Resolved.Discovery do
  @moduledoc """
  EDNS discovery probe for YellowDog DNS management server.
  Sends EDNS0 probes with private-use option code 65321 to discover
  management WebSocket endpoints.
  """
  use GenServer

  require Logger

  @edns_option_code 65321
  @edns_version 1
  @discovery_domain "_yellowdog._tcp.local"

  # Client API

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec instance_id() :: binary()
  def instance_id do
    GenServer.call(__MODULE__, :instance_id)
  end

  # Server callbacks

  @impl true
  def init(config) do
    uuid = generate_uuid()

    ws_config = get_in(config, [:discovery, :websocket]) || %{}
    reconnect_base = Map.get(ws_config, :reconnect_base_s, 5) * 1000
    reconnect_max = Map.get(ws_config, :reconnect_max_s, 60) * 1000

    state = %{
      instance_id: uuid,
      upstreams: Map.get(config, :upstreams, []),
      ws_config: ws_config,
      management_pid: nil,
      discovered_endpoint: nil,
      reconnect_delay: reconnect_base,
      reconnect_base: reconnect_base,
      reconnect_max: reconnect_max
    }

    # Start discovery probe asynchronously
    send(self(), :probe)

    {:ok, state}
  end

  @impl true
  def handle_call(:instance_id, _from, state) do
    {:reply, state.instance_id, state}
  end

  @impl true
  def handle_info(:probe, state) do
    # Run probe in a Task so the GenServer stays responsive during the
    # potentially multi-second Abyss.Client.send_recv calls.
    discovery = self()

    Task.start(fn ->
      # Wrap in try/rescue so any unexpected exception still delivers
      # {:probe_result, :not_found} rather than crashing the task silently.
      result =
        try do
          find_endpoint(state.upstreams, state.instance_id)
        rescue
          _ -> :not_found
        catch
          :throw, _ -> :not_found
        end

      send(discovery, {:probe_result, result})
    end)

    {:noreply, state}
  end

  def handle_info({:probe_result, {:ok, endpoint}}, state) do
    Logger.info("[Resolved] Discovered YellowDog DNS at #{endpoint}")

    management_config = %{
      endpoint: endpoint,
      instance_id: state.instance_id,
      ws_config: state.ws_config,
      parent: self()
    }

    case YellowDog.Resolved.Management.Client.start_link(management_config) do
      {:ok, pid} ->
        {:noreply,
         %{state | management_pid: pid, discovered_endpoint: endpoint, reconnect_delay: state.reconnect_base}}

      {:error, reason} ->
        Logger.warning("[Resolved] Failed to start management client: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:probe_result, :not_found}, state) do
    {:noreply, state}
  end

  def handle_info({:management_down, reason}, state) do
    Logger.info("[Resolved] Management connection lost: #{inspect(reason)}")

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :disconnected],
      %{},
      %{reason: reason}
    )

    # Re-discover after exponential backoff
    Process.send_after(self(), :probe, state.reconnect_delay)
    new_delay = min(state.reconnect_delay * 2, state.reconnect_max)

    {:noreply,
     %{state | management_pid: nil, discovered_endpoint: nil, reconnect_delay: new_delay}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  # Probe each upstream until one responds with a YellowDog endpoint.
  # Returns {:ok, endpoint} or :not_found. Designed to run in a Task.
  defp find_endpoint(upstreams, instance_id) do
    Enum.reduce_while(upstreams, :not_found, fn upstream, _acc ->
      :telemetry.execute(
        [:yellow_dog, :resolved, :discovery, :probe],
        %{},
        %{upstream: upstream}
      )

      case probe_upstream(upstream, instance_id) do
        {:ok, endpoint} ->
          :telemetry.execute(
            [:yellow_dog, :resolved, :discovery, :found],
            %{},
            %{upstream: upstream, ws_endpoint: endpoint}
          )

          {:halt, {:ok, endpoint}}

        :not_yellowdog ->
          :telemetry.execute(
            [:yellow_dog, :resolved, :discovery, :not_found],
            %{},
            %{upstream: upstream}
          )

          {:cont, :not_found}

        {:error, reason} ->
          Logger.debug(
            "[Resolved] Discovery probe to #{:inet.ntoa(upstream)} failed: #{inspect(reason)}"
          )

          {:cont, :not_found}
      end
    end)
  end

  defp probe_upstream(upstream, instance_id) do
    query = build_discovery_query(instance_id)
    packet = DNS.to_iodata(query) |> IO.iodata_to_binary()

    case Abyss.Client.send_recv(upstream, 53, packet, 5000) do
      {:ok, response_data} ->
        parse_discovery_response(response_data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_discovery_query(instance_id) do
    edns_data = <<@edns_version::8, instance_id::binary-size(16)>>
    edns_options = build_edns_option(edns_data)
    rdlen = byte_size(edns_options)

    # DNS.Parameter.to_iodata/1 for BitString treats the value as a domain
    # name, not raw RDATA.  Wrap in DNS.Message.Record.Data so the generic
    # implementation emits <<rdlength::16, edns_options::binary>> — the
    # correct wire format for OPT RDATA (RFC 6891 §6.1.2).
    opt_rr = %DNS.Message.Record{
      name: %DNS.Message.Domain{value: ".", size: 1},
      type: DNS.ResourceRecordType.new(41),
      class: DNS.Class.new(4096),
      ttl: 0,
      rdlength: rdlen,
      data: %DNS.Message.Record.Data{rdlength: rdlen, raw: edns_options}
    }

    query = DNS.Message.new()

    question =
      DNS.Message.Question.new(
        @discovery_domain,
        :srv,
        :in
      )

    %{
      query
      | qdlist: [question],
        arlist: [opt_rr],
        header: %{query.header | qdcount: 1, arcount: 1}
    }
  end

  defp build_edns_option(data) do
    # EDNS option: code (2 bytes) + length (2 bytes) + data
    option_length = byte_size(data)
    <<@edns_option_code::16, option_length::16, data::binary>>
  end

  defp parse_discovery_response(data) do
    try do
      case DNS.Message.from_iodata(data) do
        %DNS.Message{} = response ->
          # Look for EDNS option 65321 in additional section
          case find_edns_option(response.arlist) do
            {:ok, ws_path} ->
              # Find SRV record for host/port
              case find_srv_record(response.anlist) do
                {:ok, host, port} ->
                  {:ok, "ws://#{host}:#{port}#{ws_path}"}

                :not_found ->
                  :not_yellowdog
              end

            :not_found ->
              :not_yellowdog
          end

        _ ->
          :not_yellowdog
      end
    rescue
      _ -> :not_yellowdog
    catch
      :throw, _ -> :not_yellowdog
    end
  end

  defp find_edns_option(arlist) do
    Enum.find_value(arlist, :not_found, fn record ->
      if to_string(record.type) == "OPT" do
        case parse_edns_options(record.data) do
          {:ok, ws_path} -> {:ok, ws_path}
          _ -> nil
        end
      end
    end)
  end

  defp parse_edns_options(
         <<@edns_option_code::16, length::16, data::binary-size(length), _rest::binary>>
       ) do
    case data do
      <<@edns_version::8, ws_path::binary>> when byte_size(ws_path) > 0 ->
        {:ok, ws_path}

      _ ->
        :error
    end
  end

  defp parse_edns_options(data) when is_binary(data) and byte_size(data) >= 4 do
    case data do
      <<_code::16, length::16, _data::binary-size(length), rest::binary>> ->
        parse_edns_options(rest)

      _ ->
        :not_found
    end
  end

  defp parse_edns_options(_), do: :not_found

  defp find_srv_record(anlist) do
    Enum.find_value(anlist, :not_found, fn record ->
      if to_string(record.type) == "SRV" do
        case record.data do
          {_priority, _weight, port, target} when port >= 1 and port <= 65535 ->
            # DNS domain names in wire-format responses include a trailing dot (FQDN);
            # strip it before embedding in the WebSocket URL.
            host = target |> to_string() |> String.trim_trailing(".")
            {:ok, host, port}

          _ ->
            nil
        end
      end
    end)
  end

  defp generate_uuid do
    :crypto.strong_rand_bytes(16)
  end
end
