defmodule YellowDog.Server.Control.Dispatcher do
  @moduledoc false

  require Logger

  alias YellowDog.Server.Control.Dhcpv4
  alias YellowDog.Server.Control.Dhcpv6
  alias YellowDog.Server.Control.Dns
  alias YellowDog.Server.Control.Identity
  alias YellowDog.Server.Control.Mdns
  alias YellowDog.Server.Control.Netboot
  alias YellowDog.Server.Control.Result
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Server.Control.Runtime
  alias YellowDog.Server.Control.Settings
  alias YellowDog.Server.ProfileResolver
  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @production_adapters %{
    runtime: Runtime,
    dns: Dns,
    dhcpv4: Dhcpv4,
    dhcpv6: Dhcpv6,
    mdns: Mdns,
    netboot: Netboot,
    identity: Identity,
    settings: Settings
  }
  @test_environment Mix.env() == :test
  @production_dependencies %{
    adapters: @production_adapters,
    service_registry: ServiceRegistry,
    profile_resolver: ProfileResolver
  }
  @mutation_lock_resource {__MODULE__, :mutations}

  @create_operations MapSet.new([
                       "server.dhcp.pools.create",
                       "server.dns.acls.create",
                       "server.dns.providers.create",
                       "server.dns.records.create",
                       "server.dns.views.create",
                       "server.dns.zones.create",
                       "server.identity.tokens.create",
                       "server.mdns.services.register",
                       "server.netboot.assets.upload",
                       "server.netboot.devices.put",
                       "server.netboot.profiles.put"
                     ])

  @doc false
  @spec dispatch(Envelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(%Envelope{target_type: :server} = envelope) do
    try do
      dispatch_server(envelope)
    rescue
      exception ->
        log_failure(:error, exception, __STACKTRACE__, envelope.operation)
        internal_error()
    catch
      kind, reason ->
        log_failure(kind, reason, __STACKTRACE__, envelope.operation)
        internal_error()
    end
  end

  def dispatch(_envelope), do: invalid_error()

  defp dispatch_server(envelope) do
    with {:ok, %Operation{target_type: :server} = operation} <-
           ServerOperation.fetch(envelope.operation),
         {:ok, _validated} <- Operation.validate_envelope(envelope, operation.kind),
         {:ok, dependencies} <- dependencies(),
         {:ok, adapter, service} <-
           route(operation, envelope.payload, dependencies.adapters),
         :ok <- ensure_service_available(service, dependencies),
         :ok <- ensure_adapter_available(adapter, operation.kind) do
      dispatch_operation(operation, envelope, adapter)
    else
      {:error, %Error{}} = error -> error
      _ -> invalid_error()
    end
  end

  defp route(%Operation{capability: "runtime." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :runtime, nil)

  defp route(%Operation{capability: "dns." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :dns, :dns)

  defp route(%Operation{capability: "dhcp." <> _rest}, %{"family" => "ipv4"}, adapters),
    do: fetch_route(adapters, :dhcpv4, :dhcpv4)

  defp route(%Operation{capability: "dhcp." <> _rest}, %{"family" => "ipv6"}, adapters),
    do: fetch_route(adapters, :dhcpv6, :dhcpv6)

  defp route(%Operation{capability: "mdns." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :mdns, :mdns)

  defp route(%Operation{capability: "netboot." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :netboot, :netboot)

  defp route(%Operation{capability: "identity." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :identity, :identity)

  defp route(%Operation{capability: "settings." <> _rest}, _payload, adapters),
    do: fetch_route(adapters, :settings, nil)

  defp route(_operation, _payload, _adapters), do: unsupported_error()

  defp fetch_route(adapters, route_key, service) do
    case Map.fetch(adapters, route_key) do
      {:ok, adapter} -> {:ok, adapter, service}
      :error -> internal_error()
    end
  end

  defp ensure_service_available(nil, _dependencies), do: :ok

  defp ensure_service_available(service, dependencies) do
    with {:ok, %{available?: true}} <-
           apply(dependencies.service_registry, :fetch, [service]),
         %{services: services} when is_map(services) <-
           apply(dependencies.profile_resolver, :resolve, []),
         true <- Map.get(services, service, false) do
      :ok
    else
      _ -> unsupported_error()
    end
  end

  if @test_environment do
    defp dependencies do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      with true <- Keyword.keyword?(config),
           adapter_overrides when is_map(adapter_overrides) <-
             Keyword.get(config, :adapters, %{}),
           true <- valid_adapter_overrides?(adapter_overrides),
           service_registry when is_atom(service_registry) and not is_nil(service_registry) <-
             Keyword.get(config, :service_registry, @production_dependencies.service_registry),
           profile_resolver when is_atom(profile_resolver) and not is_nil(profile_resolver) <-
             Keyword.get(config, :profile_resolver, @production_dependencies.profile_resolver) do
        {:ok,
         %{
           adapters: Map.merge(@production_adapters, adapter_overrides),
           service_registry: service_registry,
           profile_resolver: profile_resolver
         }}
      else
        _ -> internal_error()
      end
    end

    defp valid_adapter_overrides?(overrides) do
      Enum.all?(overrides, fn {route_key, adapter} ->
        Map.has_key?(@production_adapters, route_key) and is_atom(adapter) and not is_nil(adapter)
      end)
    end
  else
    defp dependencies, do: {:ok, @production_dependencies}
  end

  defp ensure_adapter_available(adapter, :query) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 2) do
      :ok
    else
      unsupported_error()
    end
  end

  defp ensure_adapter_available(adapter, kind) when kind in [:command, :config] do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 2) and
         function_exported?(adapter, :current, 2) do
      :ok
    else
      unsupported_error()
    end
  end

  defp dispatch_operation(%Operation{kind: :query} = operation, envelope, adapter) do
    invoke_adapter(operation, envelope.payload, adapter)
  end

  defp dispatch_operation(operation, envelope, adapter) do
    lock_id = {@mutation_lock_resource, self()}

    case :global.trans(
           lock_id,
           fn ->
             with :ok <- check_revision(operation, envelope, adapter) do
               invoke_adapter(operation, envelope.payload, adapter)
             end
           end,
           [node()]
         ) do
      :aborted -> internal_error()
      result -> result
    end
  end

  defp invoke_adapter(operation, payload, adapter) do
    adapter
    |> apply(:dispatch, [operation.name, payload])
    |> normalize_adapter_result(operation)
  end

  defp check_revision(operation, envelope, adapter) do
    case apply(adapter, :current, [operation.name, envelope.payload]) do
      {:ok, current} ->
        Revision.check(envelope.expected_revision, current, revision_policy(operation))

      {:error, %Error{} = error} ->
        validate_adapter_error(error)

      _other ->
        internal_error()
    end
  end

  defp revision_policy(%Operation{name: name}) do
    if MapSet.member?(@create_operations, name), do: :create, else: :mutation
  end

  defp normalize_adapter_result({:ok, value}, operation) do
    with {:ok, value} <- Result.normalize(value),
         {:ok, value} <- Operation.validate_result(operation, value) do
      {:ok, value}
    end
  end

  defp normalize_adapter_result({:error, %Error{} = error}, _operation) do
    validate_adapter_error(error)
  end

  defp normalize_adapter_result(_result, _operation), do: internal_error()

  defp validate_adapter_error(%Error{} = error) do
    with wire when is_map(wire) <- Error.to_wire(error),
         {:ok, validated} <- Error.from_wire(wire),
         true <- validated == error do
      {:error, error}
    else
      _ -> internal_error()
    end
  end

  defp log_failure(kind, reason, stacktrace, operation) do
    Logger.error([
      "server control dispatch failed for ",
      operation,
      "\n",
      Exception.format(kind, reason, stacktrace)
    ])
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
