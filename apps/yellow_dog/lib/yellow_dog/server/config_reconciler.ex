defmodule YellowDog.Server.ConfigReconciler do
  @moduledoc """
  Reconciles running service supervisors after managed config activation.

  The management Server agent is deliberately excluded so applying a config
  cannot tear down the control channel that is acknowledging it.
  """

  alias YellowDog.Server.ProfileResolver
  alias YellowDog.Server.ServiceRegistry

  @production_dependencies %{
    profile_resolver: ProfileResolver,
    runtime: YellowDog.Application,
    service_registry: ServiceRegistry
  }

  @type phase :: :start | :stop | :restart_start | :restart_stop
  @type error_reason ::
          :invalid_reconciliation_input
          | {:service_reconciliation_failed, atom(), phase()}

  @doc """
  Starts, stops, or restarts only the service supervisors affected by a config
  replacement.
  """
  @spec reconcile(map(), map()) :: :ok | {:error, error_reason()}
  def reconcile(previous, next) do
    reconcile(previous, next, @production_dependencies)
  end

  @doc false
  @spec reconcile(map(), map(), map()) :: :ok | {:error, error_reason()}
  def reconcile(previous, next, dependencies)
      when is_map(previous) and is_map(next) and is_map(dependencies) do
    with {:ok, previous_services} <- resolve_services(previous, dependencies),
         {:ok, next_services} <- resolve_services(next, dependencies),
         {:ok, metadata} <- controllable_services(dependencies),
         {:ok, actions} <- plan(metadata, previous_services, next_services, previous, next) do
      execute(actions, dependencies)
    else
      _invalid -> {:error, :invalid_reconciliation_input}
    end
  end

  def reconcile(_previous, _next, _dependencies),
    do: {:error, :invalid_reconciliation_input}

  defp resolve_services(config, %{profile_resolver: resolver}) do
    case safe_call(resolver, :resolve, [config]) do
      {:ok, %{services: services}} when is_map(services) -> {:ok, services}
      _invalid -> :error
    end
  end

  defp resolve_services(_config, _dependencies), do: :error

  defp controllable_services(%{service_registry: registry}) do
    case safe_call(registry, :all, []) do
      {:ok, services} when is_list(services) -> validate_services(services)
      _invalid -> :error
    end
  end

  defp controllable_services(_dependencies), do: :error

  defp validate_services(services) do
    services =
      Enum.filter(services, fn
        %{name: :server_agent} -> false
        %{controllable?: true} -> true
        _metadata -> false
      end)

    if Enum.all?(services, &valid_service?/1) and unique_service_names?(services),
      do: {:ok, services},
      else: :error
  end

  defp valid_service?(%{name: name, supervisor: supervisor})
       when is_atom(name) and is_atom(supervisor),
       do: true

  defp valid_service?(_metadata), do: false

  defp unique_service_names?(services) do
    names = Enum.map(services, & &1.name)
    length(names) == MapSet.size(MapSet.new(names))
  end

  defp plan(metadata, previous_services, next_services, previous, next) do
    Enum.reduce_while(metadata, {:ok, []}, fn service, {:ok, actions} ->
      with {:ok, previous_enabled?} <- enabled(previous_services, service.name),
           {:ok, next_enabled?} <- enabled(next_services, service.name) do
        action =
          action(
            previous_enabled?,
            next_enabled?,
            service_config(previous, service.name),
            service_config(next, service.name)
          )

        next_actions = if action == :none, do: actions, else: [{action, service} | actions]
        {:cont, {:ok, next_actions}}
      else
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, actions} -> {:ok, Enum.reverse(actions)}
      :error -> :error
    end
  end

  defp enabled(services, service) do
    case Map.fetch(services, service) do
      {:ok, enabled?} when is_boolean(enabled?) -> {:ok, enabled?}
      _missing_or_invalid -> :error
    end
  end

  defp action(false, true, _previous_config, _next_config), do: :start
  defp action(true, false, _previous_config, _next_config), do: :stop
  defp action(true, true, config, config), do: :none
  defp action(true, true, _previous_config, _next_config), do: :restart
  defp action(false, false, _previous_config, _next_config), do: :none

  defp service_config(config, service) do
    value =
      cond do
        Map.has_key?(config, service) ->
          Map.fetch!(config, service)

        Map.has_key?(config, Atom.to_string(service)) ->
          Map.fetch!(config, Atom.to_string(service))

        true ->
          %{}
      end

    canonicalize(value)
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {canonicalize_key(key), canonicalize(nested)} end)
    |> Enum.sort()
    |> then(&{:map, &1})
  end

  defp canonicalize(value) when is_list(value), do: {:list, Enum.map(value, &canonicalize/1)}

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> then(&{:tuple, &1})
  end

  defp canonicalize(value), do: value

  defp canonicalize_key(key) when is_atom(key), do: {:name, Atom.to_string(key)}
  defp canonicalize_key(key) when is_binary(key), do: {:name, key}
  defp canonicalize_key(key), do: {:term, key}

  defp execute(actions, dependencies) do
    Enum.reduce_while(actions, :ok, fn {action, service}, :ok ->
      case execute(action, service, dependencies) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute(:start, service, dependencies),
    do: run_phase(:start, :start, service, dependencies)

  defp execute(:stop, service, dependencies),
    do: run_phase(:stop, :stop, service, dependencies)

  defp execute(:restart, service, dependencies) do
    with :ok <- run_phase(:stop, :restart_stop, service, dependencies),
         :ok <- run_phase(:start, :restart_start, service, dependencies) do
      :ok
    end
  end

  defp run_phase(operation, error_phase, service, %{runtime: runtime}) do
    function =
      if operation == :start, do: :start_service_supervisor, else: :stop_service_supervisor

    case safe_call(runtime, function, [service.name, service.supervisor]) do
      {:ok, result} -> normalize_result(operation, result, service.name, error_phase)
      :error -> reconciliation_error(service.name, error_phase)
    end
  end

  defp run_phase(_operation, error_phase, service, _dependencies),
    do: reconciliation_error(service.name, error_phase)

  defp normalize_result(:start, {:ok, _pid_or_state}, _service, _phase), do: :ok

  defp normalize_result(:start, {:error, {:already_started, _pid}}, _service, _phase),
    do: :ok

  defp normalize_result(:stop, :ok, _service, _phase), do: :ok
  defp normalize_result(:stop, {:error, :not_found}, _service, _phase), do: :ok

  defp normalize_result(_operation, _result, service, phase),
    do: reconciliation_error(service, phase)

  defp reconciliation_error(service, phase),
    do: {:error, {:service_reconciliation_failed, service, phase}}

  defp safe_call(module, function, arguments) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      {:ok, apply(module, function, arguments)}
    else
      :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_call(_module, _function, _arguments), do: :error
end
