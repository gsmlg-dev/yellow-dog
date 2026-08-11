defmodule YellowDog.Console.NetmanControlChannel do
  @moduledoc """
  Canonical Sync message channel for one authenticated typed Netman connection.

  Configuration state publications are durably receipted after the complete
  Hello, Status, and Journal handshake. Inbound config delivery and events are
  not valid runtime-to-management messages.
  """

  use Phoenix.Channel, log_handle_in: false

  alias YellowDog.Console.NetmanConnections
  alias YellowDog.Console.ServerChannel.SyncCodec

  @sync_event "sync"
  @payload_keys ["message", "publication_sequence"]

  @impl true
  def join("netman:control:" <> topic_netman_id, _payload, socket) do
    netman_id = socket.assigns.netman_id

    cond do
      topic_netman_id != netman_id ->
        {:error, error_reply(:invalid)}

      :ok == NetmanConnections.begin_candidate(netman_id, self()) ->
        {:ok, %{}, assign(socket, :handshake_state, :awaiting_hello)}

      true ->
        {:error, error_reply(:internal)}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, error_reply(:invalid)}

  @impl true
  def handle_in(@sync_event, payload, socket) do
    with {:ok, encoded, publication_sequence} <- exact_payload(payload),
         {:ok, message} <- SyncCodec.decode(encoded),
         :ok <- matching_netman(message, socket.assigns.netman_id),
         :ok <- valid_publication_sequence(message.tag, publication_sequence) do
      dispatch(
        socket.assigns.handshake_state,
        message,
        encoded,
        publication_sequence,
        socket
      )
    else
      {:error, code} -> error(code, socket)
      _invalid -> error(:invalid, socket)
    end
  end

  def handle_in(_event, _payload, socket), do: error(:invalid, socket)

  @impl true
  def handle_info({:netman_connection_replaced, _new_channel_pid}, socket) do
    {:stop, {:shutdown, :replaced}, socket}
  end

  def handle_info(:netman_handshake_timeout, socket) do
    {:stop, {:shutdown, :handshake_timeout}, socket}
  end

  def handle_info({:netman_management_push, encoded}, socket) when is_binary(encoded) do
    :ok = push(socket, @sync_event, %{"message" => encoded, "publication_sequence" => nil})
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    NetmanConnections.disconnect(socket.assigns.netman_id, self())
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp dispatch(:awaiting_hello, %{tag: :hello, identity: identity}, _encoded, nil, socket) do
    socket =
      socket
      |> assign(:identity, identity)
      |> assign(:handshake_state, :awaiting_status)

    accepted(socket)
  end

  defp dispatch(:awaiting_hello, _message, _encoded, _sequence, socket),
    do: error(:not_connected, socket)

  defp dispatch(:awaiting_status, %{tag: :status, status: status}, _encoded, nil, socket) do
    accepted(
      socket
      |> assign(:status, status)
      |> assign(:handshake_state, :awaiting_journal)
    )
  end

  defp dispatch(:awaiting_status, _message, _encoded, _sequence, socket),
    do: error(:not_connected, socket)

  defp dispatch(:awaiting_journal, %{tag: :journal}, encoded, nil, socket) do
    case NetmanConnections.activate_after_journal(
           socket.assigns.netman_id,
           self(),
           socket.assigns.identity,
           socket.assigns.status,
           encoded
         ) do
      {:ok, _replaced_pid} ->
        accepted(assign(socket, :handshake_state, :active))

      {:error, code} ->
        error(code, socket)
    end
  end

  defp dispatch(:awaiting_journal, _message, _encoded, _sequence, socket),
    do: error(:not_connected, socket)

  defp dispatch(:active, %{tag: :heartbeat}, _encoded, nil, socket) do
    case NetmanConnections.touch(socket.assigns.netman_id, self()) do
      :ok -> accepted(socket)
      {:error, _reason} -> error(:not_connected, socket)
    end
  end

  defp dispatch(:active, %{tag: :status, status: status}, _encoded, nil, socket) do
    case NetmanConnections.update_status(socket.assigns.netman_id, self(), status) do
      :ok -> accepted(socket)
      {:error, code} -> error(code, socket)
    end
  end

  defp dispatch(:active, %{tag: :result} = result, _encoded, nil, socket) do
    case NetmanConnections.resolve_result(socket.assigns.netman_id, self(), result) do
      {:error, code} -> error(code, socket)
      _resolved_or_ignored -> accepted(socket)
    end
  end

  defp dispatch(:active, %{tag: :journal}, encoded, nil, socket) do
    case NetmanConnections.reconcile_journal(socket.assigns.netman_id, self(), encoded) do
      :ok -> accepted(socket)
      {:error, code} -> error(code, socket)
    end
  end

  defp dispatch(:active, %{tag: :config_state}, encoded, publication_sequence, socket) do
    case NetmanConnections.accept_config_state(
           socket.assigns.netman_id,
           self(),
           publication_sequence,
           encoded
         ) do
      {:ok, receipt} when is_map(receipt) -> {:reply, {:ok, receipt}, socket}
      {:error, code} -> error(code, socket)
      _invalid -> error(:internal, socket)
    end
  catch
    :exit, _reason -> error(:internal, socket)
  end

  defp dispatch(:active, _message, _encoded, _sequence, socket),
    do: error(:unsupported, socket)

  defp exact_payload(payload) when is_map(payload) do
    if Enum.sort(Map.keys(payload)) == @payload_keys and is_binary(payload["message"]) do
      {:ok, payload["message"], payload["publication_sequence"]}
    else
      {:error, :invalid}
    end
  end

  defp exact_payload(_payload), do: {:error, :invalid}

  defp valid_publication_sequence(:config_state, sequence)
       when is_integer(sequence) and sequence > 0,
       do: :ok

  defp valid_publication_sequence(:config_state, _sequence), do: {:error, :invalid}
  defp valid_publication_sequence(_tag, nil), do: :ok
  defp valid_publication_sequence(_tag, _sequence), do: {:error, :invalid}

  defp matching_netman(
         %{tag: :hello, identity: %{target_type: :netman, id: netman_id}},
         netman_id
       ),
       do: :ok

  defp matching_netman(
         %{target_type: :netman, target_id: netman_id},
         netman_id
       ),
       do: :ok

  defp matching_netman(%{tag: :result, target_type: :netman}, _netman_id), do: :ok
  defp matching_netman(_message, _netman_id), do: {:error, :invalid}

  defp accepted(socket), do: {:reply, {:ok, %{"accepted" => true}}, socket}
  defp error(code, socket), do: {:reply, {:error, error_reply(code)}, socket}
  defp error_reply(code), do: %{"error" => wire_error(code)}

  defp wire_error(:not_connected),
    do: %{"code" => "not_connected", "message" => "not connected", "details" => %{}}

  defp wire_error(:not_found),
    do: %{"code" => "not_found", "message" => "not found", "details" => %{}}

  defp wire_error(:conflict),
    do: %{"code" => "conflict", "message" => "conflict", "details" => %{}}

  defp wire_error(:unsupported),
    do: %{"code" => "unsupported", "message" => "unsupported message", "details" => %{}}

  defp wire_error(:timeout),
    do: %{"code" => "timeout", "message" => "operation timed out", "details" => %{}}

  defp wire_error(:apply_failed),
    do: %{"code" => "apply_failed", "message" => "apply failed", "details" => %{}}

  defp wire_error(:rollback_failed),
    do: %{"code" => "rollback_failed", "message" => "rollback failed", "details" => %{}}

  defp wire_error(:internal),
    do: %{"code" => "internal", "message" => "internal error", "details" => %{}}

  defp wire_error(_invalid),
    do: %{"code" => "invalid", "message" => "invalid message", "details" => %{}}
end
