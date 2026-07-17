defmodule YellowDog.Console.ServerChannel do
  @moduledoc """
  Canonical Sync message channel for one authenticated Server connection.
  """

  use Phoenix.Channel, log_handle_in: false

  alias __MODULE__.SyncCodec
  alias YellowDog.Console.ServerConnections

  @sync_event "sync"
  @payload_keys ["message", "publication_sequence"]

  @impl true
  def join("server:control:" <> topic_server_id, _payload, socket) do
    server_id = socket.assigns.server_id

    cond do
      topic_server_id != server_id ->
        {:error, error_reply(:invalid)}

      :ok == ServerConnections.begin_candidate(server_id, self()) ->
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
         :ok <- matching_server(message, socket.assigns.server_id),
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
  def handle_info({:server_connection_replaced, _new_channel_pid}, socket) do
    {:stop, {:shutdown, :replaced}, socket}
  end

  def handle_info(:server_handshake_timeout, socket) do
    {:stop, {:shutdown, :handshake_timeout}, socket}
  end

  def handle_info({:server_management_push, encoded}, socket) when is_binary(encoded) do
    :ok =
      push(socket, @sync_event, %{
        "message" => encoded,
        "publication_sequence" => nil
      })

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    ServerConnections.disconnect(socket.assigns.server_id, self())
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
    case ServerConnections.activate(
           socket.assigns.server_id,
           self(),
           socket.assigns.identity,
           status
         ) do
      {:ok, _replaced_pid} ->
        socket = assign(socket, :handshake_state, :active)
        accepted(socket)

      {:error, _reason} ->
        error(:invalid, socket)
    end
  end

  defp dispatch(:awaiting_status, _message, _encoded, _sequence, socket),
    do: error(:not_connected, socket)

  defp dispatch(:active, %{tag: :heartbeat}, _encoded, nil, socket) do
    case ServerConnections.touch(socket.assigns.server_id, self()) do
      :ok -> accepted(socket)
      {:error, _reason} -> error(:not_connected, socket)
    end
  end

  defp dispatch(:active, %{tag: :status, status: status}, _encoded, nil, socket) do
    case ServerConnections.update_status(socket.assigns.server_id, self(), status) do
      :ok -> accepted(socket)
      {:error, code} -> error(code, socket)
    end
  end

  defp dispatch(:active, %{tag: :result} = result, _encoded, nil, socket) do
    result =
      ServerConnections.resolve_result(
        socket.assigns.server_id,
        self(),
        result
      )

    case result do
      {:error, code} -> error(code, socket)
      _resolved_or_ignored -> accepted(socket)
    end
  end

  defp dispatch(:active, %{tag: :journal}, encoded, nil, socket) do
    case ServerConnections.reconcile_journal(
           socket.assigns.server_id,
           self(),
           encoded
         ) do
      :ok ->
        accepted(socket)

      {:error, code} ->
        error(code, socket)
    end
  end

  defp dispatch(
         :active,
         %{tag: :config_state},
         encoded,
         publication_sequence,
         socket
       ) do
    case ServerConnections.accept_config_state(
           socket.assigns.server_id,
           self(),
           publication_sequence,
           encoded
         ) do
      {:ok, receipt} when is_map(receipt) ->
        {:reply, {:ok, receipt}, socket}

      {:error, code} ->
        error(code, socket)

      _invalid ->
        error(:internal, socket)
    end
  catch
    :exit, _reason -> error(:internal, socket)
  end

  defp dispatch(:active, _message, _encoded, _sequence, socket),
    do: error(:unsupported, socket)

  defp exact_payload(payload) when is_map(payload) do
    if Enum.sort(Map.keys(payload)) == @payload_keys and
         is_binary(payload["message"]) do
      {:ok, payload["message"], payload["publication_sequence"]}
    else
      {:error, :invalid}
    end
  end

  defp exact_payload(_payload), do: {:error, :invalid}

  defp matching_server(%{tag: :hello, identity: %{id: server_id}}, server_id), do: :ok

  defp matching_server(
         %{target_type: :server, target_id: server_id},
         server_id
       ),
       do: :ok

  defp matching_server(%{tag: :result, target_type: target_type}, _server_id)
       when target_type in [:server, :netman],
       do: :ok

  defp matching_server(_message, _server_id), do: {:error, :invalid}

  defp valid_publication_sequence(:config_state, sequence)
       when is_integer(sequence) and sequence > 0,
       do: :ok

  defp valid_publication_sequence(:config_state, _sequence), do: {:error, :invalid}
  defp valid_publication_sequence(_tag, nil), do: :ok
  defp valid_publication_sequence(_tag, _sequence), do: {:error, :invalid}

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

  defmodule SyncCodec do
    @moduledoc false

    @message_module :"Elixir.YellowDog.Sync.Message"
    @hello_module :"Elixir.YellowDog.Sync.Message.Hello"
    @heartbeat_module :"Elixir.YellowDog.Sync.Message.Heartbeat"
    @status_module :"Elixir.YellowDog.Sync.Message.Status"
    @query_module :"Elixir.YellowDog.Sync.Message.Query"
    @command_module :"Elixir.YellowDog.Sync.Message.Command"
    @result_module :"Elixir.YellowDog.Sync.Message.Result"
    @config_delivery_module :"Elixir.YellowDog.Sync.Message.ConfigDelivery"
    @config_state_module :"Elixir.YellowDog.Sync.Message.ConfigState"
    @journal_module :"Elixir.YellowDog.Sync.Message.Journal"
    @event_module :"Elixir.YellowDog.Sync.Message.Event"
    @server_identity_module :"Elixir.YellowDog.Sync.Identity.Server"
    @envelope_module :"Elixir.YellowDog.Sync.Envelope"
    @operation_module :"Elixir.YellowDog.Sync.Operation"
    @error_module :"Elixir.YellowDog.Sync.Error"

    @spec decode(binary()) :: {:ok, map()} | {:error, :invalid}
    def decode(encoded) when is_binary(encoded) do
      with true <- Code.ensure_loaded?(@message_module),
           {:ok, decoded} <- codec_apply(:decode, [encoded]),
           {:ok, ^encoded} <- codec_apply(:encode, [decoded]),
           {:ok, summary} <- summarize(decoded) do
        {:ok, summary}
      else
        _invalid -> {:error, :invalid}
      end
    end

    def decode(_encoded), do: {:error, :invalid}

    @spec encode_request(map()) :: {:ok, binary(), map()} | {:error, :invalid}
    def encode_request(envelope) do
      with {:ok, kind} <- request_kind(envelope),
           {:ok, encoded} <- encode_envelope_wrapper(envelope, kind),
           {:ok, summary} <- envelope_correlation(envelope) do
        {:ok, encoded, summary}
      else
        _invalid -> {:error, :invalid}
      end
    end

    @spec encode_config_delivery(map()) :: {:ok, binary(), map()} | {:error, :invalid}
    def encode_config_delivery(envelope) do
      with {:ok, encoded} <- encode_envelope_wrapper(envelope, :config),
           {:ok, summary} <- envelope_correlation(envelope) do
        {:ok, encoded, summary}
      else
        _invalid -> {:error, :invalid}
      end
    end

    @spec reconcile_journal(binary(), String.t()) ::
            {:ok, map()} | {:error, atom()}
    def reconcile_journal(encoded, server_id) do
      with true <- Code.ensure_loaded?(@message_module),
           {:ok, decoded} <- canonical_decode(encoded),
           true <- Map.get(decoded, :__struct__) == @journal_module,
           :server <- Map.get(decoded, :target_type),
           ^server_id <- Map.get(decoded, :target_id),
           {:ok, result} <-
             YellowDog.ManagementCore.runtime_connected(:server, server_id, decoded),
           true <- is_map(result) do
        {:ok, result}
      else
        {:error, reason} -> {:error, management_error_code(reason)}
        _invalid -> {:error, :invalid}
      end
    rescue
      _exception -> {:error, :internal}
    catch
      :exit, _reason -> {:error, :internal}
    end

    @spec encode_config_version_delivery(map()) ::
            {:ok, binary(), map()} | {:error, :invalid}
    def encode_config_version_delivery(version) do
      config_version_module = :"Elixir.YellowDog.Management.ConfigVersion"

      with true <- Code.ensure_loaded?(@envelope_module),
           true <- Code.ensure_loaded?(config_version_module),
           true <- is_map(version),
           ^config_version_module <- Map.get(version, :__struct__),
           :server <- Map.get(version, :target_type),
           wire = config_version_envelope_wire(version),
           {:ok, envelope} <- dynamic_apply(@envelope_module, :from_wire, [wire]) do
        encode_config_delivery(envelope)
      else
        _invalid -> {:error, :invalid}
      end
    end

    defp canonical_decode(encoded) do
      with {:ok, decoded} <- codec_apply(:decode, [encoded]),
           {:ok, ^encoded} <- codec_apply(:encode, [decoded]) do
        {:ok, decoded}
      else
        _invalid -> {:error, :invalid}
      end
    end

    defp codec_apply(function, arguments) do
      apply(@message_module, function, arguments)
    rescue
      _exception -> {:error, :invalid}
    catch
      :exit, _reason -> {:error, :invalid}
    end

    defp summarize(message) do
      summarize(Map.get(message, :__struct__), message)
    end

    defp summarize(@hello_module, message) do
      identity = Map.get(message, :identity)

      if is_map(identity) and Map.get(identity, :__struct__) == @server_identity_module do
        {:ok,
         %{
           tag: :hello,
           identity:
             Map.take(identity, [
               :id,
               :name,
               :version,
               :profile,
               :capabilities,
               :config_revision
             ])
         }}
      else
        {:error, :invalid}
      end
    end

    defp summarize(@heartbeat_module, message) do
      target_summary(:heartbeat, message)
    end

    defp summarize(@status_module, message) do
      with {:ok, target} <- target_summary(:status, message) do
        {:ok,
         Map.put(target, :status, %{
           target_type: Map.get(message, :target_type),
           target_id: Map.get(message, :target_id),
           state: Map.get(message, :state),
           details: Map.get(message, :details),
           observed_at: Map.get(message, :observed_at)
         })}
      end
    end

    defp summarize(@query_module, message), do: envelope_summary(:query, message)
    defp summarize(@command_module, message), do: envelope_summary(:command, message)

    defp summarize(@result_module, message) do
      request_id = Map.get(message, :request_id)
      target_type = Map.get(message, :target_type)
      operation = Map.get(message, :operation)
      value = Map.get(message, :value)
      result_error = Map.get(message, :error)

      with true <- is_binary(request_id),
           true <- target_type in [:server, :netman],
           true <- is_binary(operation),
           {:ok, outcome} <- result_outcome(value, result_error) do
        {:ok,
         %{
           tag: :result,
           request_id: request_id,
           target_type: target_type,
           operation: operation,
           outcome: outcome
         }}
      else
        _invalid -> {:error, :invalid}
      end
    end

    defp summarize(@config_delivery_module, message),
      do: envelope_summary(:config_delivery, message)

    defp summarize(@config_state_module, message), do: target_summary(:config_state, message)
    defp summarize(@journal_module, message), do: target_summary(:journal, message)
    defp summarize(@event_module, message), do: target_summary(:event, message)
    defp summarize(_module, _message), do: {:error, :invalid}

    defp target_summary(tag, message) do
      {:ok,
       %{
         tag: tag,
         target_type: Map.get(message, :target_type),
         target_id: Map.get(message, :target_id)
       }}
    end

    defp envelope_summary(tag, message) do
      envelope = Map.get(message, :envelope)

      if is_map(envelope) do
        {:ok,
         %{
           tag: tag,
           target_type: Map.get(envelope, :target_type),
           target_id: Map.get(envelope, :target_id)
         }}
      else
        {:error, :invalid}
      end
    end

    defp request_kind(envelope) do
      with true <- Code.ensure_loaded?(@operation_module),
           true <- is_map(envelope),
           true <- Map.get(envelope, :__struct__) == @envelope_module,
           operation when is_binary(operation) <- Map.get(envelope, :operation),
           {:ok, operation_spec} <- dynamic_apply(@operation_module, :lookup, [operation]),
           kind when kind in [:query, :command] <- Map.get(operation_spec, :kind) do
        {:ok, kind}
      else
        _invalid -> {:error, :invalid}
      end
    end

    defp encode_envelope_wrapper(envelope, kind) do
      with true <- Code.ensure_loaded?(@message_module),
           true <- Code.ensure_loaded?(@operation_module),
           true <- is_map(envelope),
           true <- Map.get(envelope, :__struct__) == @envelope_module,
           {:ok, ^envelope} <-
             dynamic_apply(@operation_module, :validate_envelope, [envelope, kind]),
           {:ok, wrapper_module} <- wrapper_module(kind),
           wrapper <- struct(wrapper_module, envelope: envelope),
           {:ok, encoded} <- codec_apply(:encode, [wrapper]),
           {:ok, ^wrapper} <- codec_apply(:decode, [encoded]) do
        {:ok, encoded}
      else
        _invalid -> {:error, :invalid}
      end
    end

    defp wrapper_module(:query), do: {:ok, @query_module}
    defp wrapper_module(:command), do: {:ok, @command_module}
    defp wrapper_module(:config), do: {:ok, @config_delivery_module}
    defp wrapper_module(_kind), do: {:error, :invalid}

    defp config_version_envelope_wire(version) do
      %{
        "protocol_version" => 1,
        "request_id" => uuid(),
        "target_type" => "server",
        "target_id" => Map.get(version, :target_id),
        "operation" => Map.get(version, :operation),
        "idempotency_key" => uuid(),
        "payload" => Map.get(version, :payload),
        "payload_digest" => Map.get(version, :digest),
        "expected_revision" => Map.get(version, :expected_revision),
        "config_version" => Map.get(version, :version),
        "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end

    defp envelope_correlation(envelope) do
      request_id = Map.get(envelope, :request_id)
      target_type = Map.get(envelope, :target_type)
      target_id = Map.get(envelope, :target_id)
      operation = Map.get(envelope, :operation)

      if is_binary(request_id) and target_type == :server and is_binary(target_id) and
           is_binary(operation) do
        {:ok,
         %{
           request_id: request_id,
           target_type: target_type,
           target_id: target_id,
           operation: operation
         }}
      else
        {:error, :invalid}
      end
    end

    defp result_outcome(value, nil) when is_map(value), do: {:ok, {:ok, value}}

    defp result_outcome(nil, result_error)
         when is_map(result_error) do
      if Map.get(result_error, :__struct__) == @error_module,
        do: {:ok, {:error, result_error}},
        else: {:error, :invalid}
    end

    defp result_outcome(_value, _error), do: {:error, :invalid}

    defp uuid do
      <<prefix::binary-size(6), version, middle, variant, suffix::binary-size(7)>> =
        :crypto.strong_rand_bytes(16)

      bytes =
        <<prefix::binary, Bitwise.band(version, 0x0F) + 0x40, middle,
          Bitwise.band(variant, 0x3F) + 0x80, suffix::binary>>

      Base.encode16(bytes, case: :lower)
      |> then(fn value ->
        binary_part(value, 0, 8) <>
          "-" <>
          binary_part(value, 8, 4) <>
          "-" <>
          binary_part(value, 12, 4) <>
          "-" <>
          binary_part(value, 16, 4) <> "-" <> binary_part(value, 20, 12)
      end)
    end

    defp dynamic_apply(module, function, arguments) do
      apply(module, function, arguments)
    rescue
      _exception -> {:error, :invalid}
    catch
      :exit, _reason -> {:error, :invalid}
    end

    defp management_error_code(reason) when is_map(reason) do
      case Map.get(reason, :code) do
        code
        when code in [
               :not_connected,
               :not_found,
               :invalid,
               :conflict,
               :unsupported,
               :timeout,
               :apply_failed,
               :rollback_failed,
               :internal
             ] ->
          code

        _unknown ->
          :internal
      end
    end

    defp management_error_code(_reason), do: :internal
  end
end
