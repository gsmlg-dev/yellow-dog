defmodule YellowDog.Resolved.Listener do
  @moduledoc """
  Abyss UDP handler for incoming DNS queries.

  Receives raw DNS packets, parses them, routes through the resolution
  pipeline, and sends responses back to clients.
  """

  use Abyss.Handler

  require Logger

  @doc "Returns the Abyss supervisor child spec for starting the UDP listener."
  @spec listener_spec(map()) :: Supervisor.child_spec()
  def listener_spec(config) do
    listen_ip = config.listen
    port = config.port

    %{
      id: __MODULE__,
      start:
        {Abyss, :start_link,
         [
           [
             handler_module: __MODULE__,
             port: port,
             transport_module: Abyss.Transport.UDP.Broadcast,
             transport_options: [ip: listen_ip],
             num_listeners: 1,
             num_connections: 1024,
             read_timeout: 30_000
           ]
         ]},
      type: :supervisor
    }
  end

  @impl Abyss.Handler
  def handle_data({client_ip, client_port, data}, state) do
    :telemetry.execute(
      [:yellow_dog, :resolved, :listener, :request],
      %{bytes: byte_size(data)},
      %{client_ip: client_ip}
    )

    case parse_query(data) do
      {:ok, query} ->
        # Router.resolve always returns {:ok, ...} — errors produce SERVFAIL internally
        {_ok, response} = extract_response(YellowDog.Resolved.Router.resolve(query, data))
        send_response(state.socket, client_ip, client_port, response)

      {:error, txn_id} ->
        :telemetry.execute(
          [:yellow_dog, :resolved, :listener, :parse_error],
          %{bytes: byte_size(data)},
          %{client_ip: client_ip, txn_id: txn_id}
        )

        # Malformed query — send FORMERR
        response =
          YellowDog.Resolved.ResponseBuilder.build_formerr(txn_id)
          |> encode()

        send_response(state.socket, client_ip, client_port, response)
    end

    {:continue, state}
  end

  # Private functions

  defp extract_response({:ok, response, _source}), do: {:ok, response}
  defp extract_response({:ok, response}), do: {:ok, response}

  defp parse_query(data) when byte_size(data) >= 12 do
    <<txn_id::16, _rest::binary>> = data

    try do
      {:ok, DNS.Message.from_iodata(data)}
    rescue
      _ -> {:error, txn_id}
    catch
      _, _ -> {:error, txn_id}
    end
  end

  defp parse_query(<<txn_id::16, _rest::binary>>), do: {:error, txn_id}
  defp parse_query(_), do: {:error, 0}

  defp send_response(socket, client_ip, client_port, response) do
    case Abyss.Transport.UDP.send(socket, client_ip, client_port, response) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :resolved, :listener, :send_error],
          %{},
          %{client_ip: client_ip, reason: reason}
        )

        Logger.warning("UDP send failed to #{:inet.ntoa(client_ip)}: #{inspect(reason)}")
    end
  end

  defp encode(message) do
    DNS.to_iodata(message) |> IO.iodata_to_binary()
  end
end
