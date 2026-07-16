defmodule YellowDog.ManagementCore do
  @moduledoc """
  Public facade for YellowDog management state.

  Concrete server and Netman contexts persist their state without changing the
  console-facing API.
  """

  import Bitwise

  alias YellowDog.Management.Commands
  alias YellowDog.Management.ConfigVersions
  alias YellowDog.Management.DisconnectedTransport
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Profiles
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Snapshots
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Journal
  alias YellowDog.Sync.Operation

  @default_request_timeout 5_000

  @doc "Lists registered managed server instances."
  def list_servers, do: Servers.list()

  @doc "Fetches a registered managed server by id."
  def get_server(id), do: Servers.get(id)

  @doc "Registers or replaces a managed server record."
  def register_server(attrs), do: Servers.register(attrs)

  @doc "Updates the status for a registered managed server."
  def update_server_status(id, status), do: Servers.update_status(id, status)

  @doc "Lists registered Netman instances."
  def list_netmans, do: Netmans.list()

  @doc "Fetches a registered Netman instance by id."
  def get_netman(id), do: Netmans.get(id)

  @doc "Registers or replaces a Netman record."
  def register_netman(attrs), do: Netmans.register(attrs)

  @doc "Updates the status for a registered Netman instance."
  def update_netman_status(id, status), do: Netmans.update_status(id, status)

  @doc "Lists concrete server profiles."
  def list_server_profiles, do: Profiles.list_server_profiles()

  @doc "Lists concrete Netman profiles."
  def list_netman_profiles, do: Profiles.list_netman_profiles()

  @doc "Lists management events in deterministic global order."
  def list_events, do: EventStore.list()

  @doc "Publishes an immutable desired configuration for a registered server."
  def publish_server_config(server_id, attrs),
    do: ConfigVersions.publish(:server, server_id, attrs)

  @doc "Publishes an immutable desired configuration for a registered Netman."
  def publish_netman_config(netman_id, attrs),
    do: ConfigVersions.publish(:netman, netman_id, attrs)

  @doc "Fetches a concrete server configuration version."
  def get_server_config_version(server_id, version),
    do: ConfigVersions.get(:server, server_id, version)

  @doc "Fetches a concrete Netman configuration version."
  def get_netman_config_version(netman_id, version),
    do: ConfigVersions.get(:netman, netman_id, version)

  @doc "Transitions a desired configuration using lifecycle CAS details."
  def transition_config(target_type, target_id, version, state, details),
    do: ConfigVersions.transition(target_type, target_id, version, state, details)

  @doc "Returns the latest desired configuration that remains deliverable."
  def latest_desired_config(target_type, target_id),
    do: ConfigVersions.latest_desired(target_type, target_id)

  @doc "Queries a concrete server and durably stores its validated snapshot."
  def query_server(server_id, snapshot_domain, operation, payload),
    do: query(:server, server_id, snapshot_domain, operation, payload)

  @doc "Queries a concrete Netman and durably stores its validated snapshot."
  def query_netman(netman_id, snapshot_domain, operation, payload),
    do: query(:netman, netman_id, snapshot_domain, operation, payload)

  @doc "Executes a durable command against a concrete server."
  def command_server(server_id, operation, payload, expected_revision, idempotency_key),
    do:
      command(
        :server,
        server_id,
        operation,
        payload,
        expected_revision,
        idempotency_key
      )

  @doc "Executes a durable command against a concrete Netman."
  def command_netman(netman_id, operation, payload, expected_revision, idempotency_key),
    do:
      command(
        :netman,
        netman_id,
        operation,
        payload,
        expected_revision,
        idempotency_key
      )

  @doc "Returns the latest durable snapshot for a concrete server and domain."
  def get_server_snapshot(server_id, domain) do
    with {:ok, _server} <- registered_target(:server, server_id) do
      Snapshots.get(:server, server_id, domain)
    end
  end

  @doc "Returns the latest durable snapshot for a concrete Netman and domain."
  def get_netman_snapshot(netman_id, domain) do
    with {:ok, _netman} <- registered_target(:netman, netman_id) do
      Snapshots.get(:netman, netman_id, domain)
    end
  end

  @doc "Reconciles a validated runtime journal and marks the concrete target online."
  def runtime_connected(target_type, target_id, %Journal{} = journal) do
    with {:ok, _target} <- registered_target(target_type, target_id),
         {:ok, journal} <- validate_journal(journal, target_type, target_id),
         {:ok, unresolved_ids} <- Commands.reconcile(target_type, target_id, journal.entries),
         {:ok, _target} <- persist_status(target_type, target_id, :online),
         {:ok, pending_config} <- pending_config(target_type, target_id) do
      {:ok,
       %{
         pending_config: pending_config,
         unresolved_command_ids: Enum.sort(unresolved_ids)
       }}
    end
  end

  def runtime_connected(_target_type, _target_id, _journal),
    do: invalid("invalid runtime journal")

  @doc "Marks a concrete runtime offline and makes its pending commands unknown."
  def runtime_disconnected(target_type, target_id) do
    with {:ok, _target} <- registered_target(target_type, target_id),
         {:ok, unresolved_ids} <- Commands.mark_target_unknown(target_type, target_id),
         {:ok, _target} <- persist_status(target_type, target_id, :offline) do
      {:ok, %{pending_config: nil, unresolved_command_ids: Enum.sort(unresolved_ids)}}
    end
  end

  defp query(target_type, target_id, snapshot_domain, operation, payload) do
    with {:ok, _target} <- registered_target(target_type, target_id),
         :ok <- valid_snapshot_domain(target_type, target_id, snapshot_domain),
         {:ok, envelope} <-
           build_envelope(target_type, target_id, operation, payload, nil, uuid(), :query),
         :ok <- connected(target_type, target_id),
         {:ok, result} <- query_request(envelope),
         {:ok, _snapshot} <- Snapshots.put(envelope, snapshot_domain, result, DateTime.utc_now()) do
      {:ok, result}
    end
  end

  defp command(target_type, target_id, operation, payload, expected_revision, idempotency_key) do
    with {:ok, _target} <- registered_target(target_type, target_id),
         {:ok, envelope} <-
           build_envelope(
             target_type,
             target_id,
             operation,
             payload,
             expected_revision,
             idempotency_key,
             :command
           ) do
      case Commands.replay(envelope) do
        :miss -> reserve_and_deliver(envelope)
        {:replay, result} -> result
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp reserve_and_deliver(envelope) do
    with :ok <- connected(envelope.target_type, envelope.target_id) do
      case Commands.reserve(envelope) do
        {:reserved, request_id} -> deliver_command(envelope, request_id)
        {:replay, result} -> result
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp deliver_command(envelope, request_id) do
    case transport_request(envelope) do
      {:ok, result} ->
        case Operation.validate_result(envelope.operation, envelope.target_type, :command, result) do
          {:ok, result} ->
            Commands.resolve(request_id, {:completed, result})

          {:error, %Error{} = error} ->
            resolve_unknown(request_id, error, "malformed_success")
        end

      {:error, %Error{code: :timeout} = error} ->
        resolve_unknown(request_id, error, "transport_timeout")

      {:error, %Error{code: :not_connected} = error} ->
        resolve_unknown(request_id, error, "transport_not_connected")

      {:error, %Error{} = error} ->
        case validate_transport_error(error) do
          {:ok, error} ->
            Commands.resolve(request_id, {:failed, error})

          {:error, %Error{} = invalid_error} ->
            resolve_unknown(request_id, invalid_error, "malformed_transport")
        end

      {:transport_failure, %Error{} = error} ->
        reason = if error.code == :timeout, do: "transport_timeout", else: "malformed_transport"
        resolve_unknown(request_id, error, reason)

      _invalid ->
        resolve_unknown(
          request_id,
          Error.new(:invalid, "runtime returned an invalid command response", %{}),
          "malformed_transport"
        )
    end
  end

  defp resolve_unknown(request_id, error, reason) do
    error = Commands.unknown_error(error, request_id, reason)
    Commands.resolve(request_id, {:unknown, error, reason})
  end

  defp query_request(envelope) do
    case transport_request(envelope) do
      {:ok, result} ->
        Operation.validate_result(envelope.operation, envelope.target_type, :query, result)

      {:error, %Error{} = error} ->
        case validate_transport_error(error) do
          {:ok, error} -> {:error, error}
          {:error, %Error{}} -> invalid("runtime returned an invalid query error")
        end

      {:transport_failure, %Error{} = error} ->
        {:error, error}

      _invalid ->
        invalid("runtime returned an invalid query response")
    end
  end

  defp build_envelope(
         target_type,
         target_id,
         operation,
         payload,
         expected_revision,
         idempotency_key,
         kind
       ) do
    with {:ok, payload_digest} <- Digest.calculate(payload),
         envelope = %Envelope{
           protocol_version: 1,
           request_id: uuid(),
           target_type: target_type,
           target_id: target_id,
           operation: operation,
           idempotency_key: idempotency_key,
           payload: payload,
           payload_digest: payload_digest,
           expected_revision: expected_revision,
           config_version: nil,
           sent_at: DateTime.utc_now()
         },
         {:ok, envelope} <- Operation.validate_envelope(envelope, kind) do
      {:ok, envelope}
    end
  end

  defp connected(target_type, target_id) do
    transport = transport_module()

    try do
      if transport.connected?(target_type, target_id), do: :ok, else: not_connected()
    rescue
      _exception -> not_connected()
    catch
      _kind, _reason -> not_connected()
    end
  end

  defp transport_request(envelope) do
    transport_module().request(envelope, request_timeout())
  rescue
    _exception ->
      {:transport_failure, Error.new(:internal, "transport request failed", %{})}
  catch
    :exit, {:timeout, _reason} ->
      {:transport_failure, Error.new(:timeout, "transport request timed out", %{})}

    _kind, _reason ->
      {:transport_failure, Error.new(:internal, "transport request failed", %{})}
  end

  defp validate_transport_error(%Error{} = error) do
    wire = Error.to_wire(error)

    with :ok <- Operation.validate_transport(error.details),
         {:ok, decoded} <- Error.from_wire(wire),
         true <- decoded == error do
      {:ok, error}
    else
      _invalid -> invalid("invalid runtime error")
    end
  end

  defp validate_journal(journal, target_type, target_id) do
    with {:ok, encoded} <- Message.encode(journal),
         {:ok, %Journal{} = decoded} <- Message.decode(encoded),
         true <- decoded.target_type == target_type,
         true <- decoded.target_id == target_id do
      {:ok, decoded}
    else
      _invalid -> invalid("invalid runtime journal")
    end
  end

  defp registered_target(:server, target_id), do: registered_result(Servers.get(target_id))
  defp registered_target(:netman, target_id), do: registered_result(Netmans.get(target_id))
  defp registered_target(_target_type, _target_id), do: invalid("invalid concrete target")

  defp registered_result({:ok, target}), do: {:ok, target}
  defp registered_result({:error, :not_found}), do: not_found()
  defp registered_result({:error, %Error{}} = error), do: error
  defp registered_result(_invalid), do: internal("target registry failed")

  defp persist_status(:server, target_id, status),
    do: status_result(Servers.update_status(target_id, status))

  defp persist_status(:netman, target_id, status),
    do: status_result(Netmans.update_status(target_id, status))

  defp status_result({:ok, target}), do: {:ok, target}
  defp status_result({:error, :not_found}), do: not_found()
  defp status_result({:error, %Error{}} = error), do: error
  defp status_result(_invalid), do: internal("target status persistence failed")

  defp pending_config(target_type, target_id) do
    case ConfigVersions.latest_desired(target_type, target_id) do
      {:ok, config} -> {:ok, config}
      {:error, %Error{code: :not_found}} -> {:ok, nil}
      {:error, %Error{}} = error -> error
    end
  end

  defp valid_snapshot_domain(:server, target_id, domain) do
    case StoragePath.server_snapshot(EventStore.config().root, target_id, domain) do
      {:ok, _path} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp valid_snapshot_domain(:netman, target_id, domain) do
    case StoragePath.netman_snapshot(EventStore.config().root, target_id, domain) do
      {:ok, _path} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp valid_snapshot_domain(_target_type, _target_id, _domain),
    do: invalid("invalid snapshot domain")

  defp transport_module do
    case Application.get_env(
           :yellow_dog_management_core,
           :transport_module,
           DisconnectedTransport
         ) do
      module when is_atom(module) -> module
      _invalid -> DisconnectedTransport
    end
  end

  defp request_timeout do
    case Application.get_env(
           :yellow_dog_management_core,
           :request_timeout,
           @default_request_timeout
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_request_timeout
    end
  end

  defp uuid do
    <<prefix::binary-size(6), version, middle, variant, suffix::binary-size(7)>> =
      :crypto.strong_rand_bytes(16)

    bytes =
      <<prefix::binary, bor(band(version, 0x0F), 0x40), middle, bor(band(variant, 0x3F), 0x80),
        suffix::binary>>

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(bytes, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  defp not_connected,
    do: {:error, Error.new(:not_connected, "runtime is not connected", %{})}

  defp not_found, do: {:error, Error.new(:not_found, "concrete target was not found", %{})}
  defp invalid(message), do: {:error, Error.new(:invalid, message, %{})}
  defp internal(message), do: {:error, Error.new(:internal, message, %{})}
end
