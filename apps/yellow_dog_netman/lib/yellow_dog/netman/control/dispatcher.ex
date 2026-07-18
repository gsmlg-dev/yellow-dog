defmodule YellowDog.Netman.Control.Dispatcher do
  @moduledoc """
  Validates and routes fixed Netman control operations.

  Query adapters implement `dispatch/2`. Mutation adapters implement `current/2`,
  returning `{:ok, canonical_revision | :missing}`, and `dispatch/3`. The third
  argument is trusted dispatcher context with an owner precondition so the adapter
  can map directly to its atomic persistence API.
  """

  require Logger

  alias YellowDog.Netman.Control.ModeGate
  alias YellowDog.Netman.Control.Result
  alias YellowDog.Netman.Control.Revision
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @production_adapters %{
    runtime: YellowDog.Netman.Control.Runtime,
    profiles: YellowDog.Netman.Control.Profiles,
    network: YellowDog.Netman.Control.Network,
    resolved: YellowDog.Netman.Control.Resolved,
    dhcp_client: YellowDog.Netman.Control.DhcpClient,
    vpn: YellowDog.Netman.Control.Vpn
  }
  @test_environment Mix.env() == :test
  @mutation_lock_resource {__MODULE__, :mutations}
  @create_operations MapSet.new(["netman.profiles.put"])
  @adapter_error_messages %{
    not_connected: "not connected",
    not_found: "resource not found",
    invalid: "invalid value",
    conflict: "operation conflict",
    unsupported: "unsupported operation",
    timeout: "operation timed out",
    apply_failed: "apply failed",
    rollback_failed: "rollback failed",
    internal: "internal error"
  }

  @type mutation_context :: %{
          expected_revision: String.t() | nil,
          current_revision: String.t() | :missing,
          precondition: :must_be_missing | {:revision, String.t()},
          config_version: pos_integer() | nil
        }

  @spec dispatch(Envelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(%Envelope{target_type: :netman} = envelope) do
    try do
      dispatch_netman(envelope)
    rescue
      _exception ->
        Logger.error("netman control dispatch failed")
        internal_error()
    catch
      _kind, _reason ->
        Logger.error("netman control dispatch failed")
        internal_error()
    end
  end

  def dispatch(_envelope), do: invalid_error()

  defp dispatch_netman(envelope) do
    with {:ok, %Operation{target_type: :netman} = operation} <-
           NetmanOperation.fetch(envelope.operation),
         {:ok, _validated} <- Operation.validate_envelope(envelope, operation.kind),
         {:ok, state} <- RuntimeState.snapshot(),
         :ok <- ModeGate.check(operation, state.apply_mode, envelope.payload),
         :ok <- ensure_capability(operation.capability, state.features),
         {:ok, adapter} <- route(operation),
         :ok <- ensure_adapter_available(adapter, operation) do
      dispatch_operation(operation, envelope, adapter)
    else
      {:error, %Error{}} = error -> error
      :error -> unsupported_error()
      _ -> invalid_error()
    end
  end

  defp route(%Operation{capability: "runtime." <> _rest}), do: fetch_route(:runtime)
  defp route(%Operation{capability: "profiles." <> _rest}), do: fetch_route(:profiles)
  defp route(%Operation{capability: "network." <> _rest}), do: fetch_route(:network)

  defp route(%Operation{capability: "resolved." <> _rest}), do: fetch_route(:resolved)
  defp route(%Operation{capability: "dhcp_client." <> _rest}), do: fetch_route(:dhcp_client)
  defp route(%Operation{capability: "vpn." <> _rest}), do: fetch_route(:vpn)
  defp route(_operation), do: unsupported_error()

  defp fetch_route(route_key) do
    case Map.fetch(adapters(), route_key) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> internal_error()
    end
  end

  defp ensure_capability("runtime." <> _rest, _features), do: :ok
  defp ensure_capability("profiles." <> _rest, _features), do: :ok

  defp ensure_capability("network.links." <> _rest, features),
    do: feature_enabled?(features, [:link_state])

  defp ensure_capability("network.addresses." <> _rest, features),
    do: feature_enabled?(features, [:interfaces])

  defp ensure_capability("network.routes." <> _rest, features),
    do: feature_enabled?(features, [:routes])

  defp ensure_capability("network.connections." <> _rest, features),
    do: feature_enabled?(features, [:interfaces, :link_state])

  defp ensure_capability("resolved." <> _rest, features),
    do: feature_enabled?(features, [:dns_client])

  defp ensure_capability("dhcp_client." <> _rest, features),
    do: feature_enabled?(features, [:dhcp_client])

  defp ensure_capability("vpn." <> _rest, features), do: feature_enabled?(features, [:vpn])
  defp ensure_capability(_capability, _features), do: unsupported_error()

  defp feature_enabled?(features, required) when is_map(features) do
    if Enum.all?(required, &Map.get(features, &1, false)), do: :ok, else: unsupported_error()
  end

  defp feature_enabled?(_features, _required), do: unsupported_error()

  if @test_environment do
    defp adapters do
      case Application.get_env(:yellow_dog_netman, __MODULE__, []) do
        config when is_list(config) ->
          overrides = Keyword.get(config, :adapters, %{})

          if valid_adapter_overrides?(overrides) do
            Map.merge(@production_adapters, overrides)
          else
            %{}
          end

        _config ->
          %{}
      end
    end

    defp valid_adapter_overrides?(overrides) when is_map(overrides) do
      Enum.all?(overrides, fn {route_key, adapter} ->
        Map.has_key?(@production_adapters, route_key) and is_atom(adapter) and not is_nil(adapter)
      end)
    end

    defp valid_adapter_overrides?(_overrides), do: false
  else
    defp adapters, do: @production_adapters
  end

  defp ensure_adapter_available(adapter, operation) do
    if Code.ensure_loaded?(adapter) and adapter_available?(adapter, operation) do
      :ok
    else
      unsupported_error()
    end
  end

  defp adapter_available?(adapter, operation) do
    if mutation?(operation) do
      function_exported?(adapter, :current, 2) and function_exported?(adapter, :dispatch, 3)
    else
      function_exported?(adapter, :dispatch, 2)
    end
  end

  defp dispatch_operation(operation, envelope, adapter) do
    if mutation?(operation) do
      dispatch_mutation(operation, envelope, adapter)
    else
      invoke_adapter(operation, envelope.payload, adapter)
    end
  end

  defp dispatch_mutation(operation, envelope, adapter) do
    lock_id = {@mutation_lock_resource, self()}

    case :global.trans(
           lock_id,
           fn ->
             with {:ok, context} <- mutation_context(operation, envelope, adapter) do
               invoke_mutation_adapter(operation, envelope.payload, context, adapter)
             end
           end,
           [node()]
         ) do
      :aborted -> internal_error()
      result -> result
    end
  end

  defp mutation?(%Operation{kind: kind, name: name}) when kind in [:command, :config],
    do: name != "netman.profiles.validate"

  defp mutation?(_operation), do: false

  defp mutation_context(operation, envelope, adapter) do
    case apply(adapter, :current, [operation.name, envelope.payload]) do
      {:ok, current_revision} ->
        with :ok <-
               Revision.check(
                 envelope.expected_revision,
                 current_revision,
                 revision_policy(operation)
               ) do
          {:ok,
           %{
             expected_revision: envelope.expected_revision,
             current_revision: current_revision,
             precondition: owner_precondition(current_revision, envelope.expected_revision),
             config_version: envelope.config_version
           }}
        end

      {:error, %Error{} = error} ->
        sanitize_adapter_error(error)

      _other ->
        internal_error()
    end
  end

  defp revision_policy(%Operation{name: name}) do
    if MapSet.member?(@create_operations, name), do: :create, else: :mutation
  end

  defp owner_precondition(:missing, nil), do: :must_be_missing

  defp owner_precondition(_current_revision, expected_revision),
    do: {:revision, expected_revision}

  defp invoke_adapter(operation, payload, adapter) do
    adapter
    |> apply(:dispatch, [operation.name, payload])
    |> normalize_adapter_result(operation)
  end

  defp invoke_mutation_adapter(operation, payload, context, adapter) do
    adapter
    |> apply(:dispatch, [operation.name, payload, context])
    |> normalize_adapter_result(operation)
  end

  defp normalize_adapter_result({:ok, value}, operation) do
    with {:ok, value} <- Result.normalize(value),
         {:ok, value} <- Operation.validate_result(operation, value) do
      {:ok, value}
    end
  end

  defp normalize_adapter_result({:error, %Error{} = error}, _operation),
    do: sanitize_adapter_error(error)

  defp normalize_adapter_result(_result, _operation), do: internal_error()

  defp sanitize_adapter_error(%Error{code: code}) do
    case Map.fetch(@adapter_error_messages, code) do
      {:ok, message} -> {:error, Error.new(code, message, %{})}
      :error -> internal_error()
    end
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
