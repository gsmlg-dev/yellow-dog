defmodule YellowDog.Server.Control.Runtime do
  @moduledoc false

  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Server.Control.Revision
  alias YellowDog.ServiceManager
  alias YellowDog.Sync.Error

  @capabilities ["runtime.capabilities", "runtime.health", "runtime.services", "runtime.stats"]
  @production_dependencies %{service_manager: ServiceManager, service_registry: ServiceRegistry}
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.runtime.capabilities.get", %{}),
    do: {:ok, %{"capabilities" => @capabilities}}

  def dispatch("server.runtime.services.list", %{}) do
    items = service_items()

    with {:ok, revision} <- Revision.calculate(items) do
      {:ok,
       %{
         "items" => items,
         "revision" => revision,
         "observed_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
       }}
    end
  end

  def dispatch("server.runtime.health.get", %{}) do
    checks =
      service_items()
      |> Enum.map(&health_check/1)

    {:ok, %{"status" => overall_health(checks), "checks" => checks}}
  end

  def dispatch("server.runtime.stats.get", %{}) do
    {:ok, %{"requests" => 0, "errors" => service_error_count()}}
  end

  def dispatch(operation, %{"service" => service_id})
      when operation in [
             "server.runtime.services.start",
             "server.runtime.services.stop",
             "server.runtime.services.restart"
           ] do
    with {:ok, service} <- resolve_controllable_service(service_id) do
      control(operation, service, service_id)
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def current(operation, %{"service" => service_id})
      when operation in [
             "server.runtime.services.start",
             "server.runtime.services.stop",
             "server.runtime.services.restart"
           ] do
    with {:ok, service} <- resolve_controllable_service(service_id) do
      {:ok, %{"service" => service_id, "state" => service_state(service)}}
    end
  end

  def current(_operation, _payload), do: unsupported_error()

  defp control("server.runtime.services.start", service, service_id) do
    case run_phase(:start, service.name) do
      :ok -> {:ok, command_result(service_id, "running")}
      :failed -> apply_failed(%{"start" => "failed"})
    end
  end

  defp control("server.runtime.services.stop", service, service_id) do
    case run_phase(:stop, service.name) do
      :ok -> {:ok, command_result(service_id, "stopped")}
      :failed -> apply_failed(%{"stop" => "failed"})
    end
  end

  defp control("server.runtime.services.restart", service, service_id) do
    case run_phase(:stop, service.name) do
      :ok ->
        case run_phase(:start, service.name) do
          :ok -> {:ok, command_result(service_id, "running")}
          :failed -> apply_failed(%{"stop" => "ok", "start" => "failed"})
        end

      :failed ->
        apply_failed(%{"stop" => "failed", "start" => "not_run"})
    end
  end

  defp run_phase(phase, service) do
    function = if phase == :start, do: :start_service, else: :stop_service

    case apply(dependencies().service_manager, function, [service]) do
      :ok -> :ok
      _result -> :failed
    end
  rescue
    _exception -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp service_items do
    dependencies().service_registry
    |> apply(:all, [])
    |> Enum.map(fn service ->
      %{"service" => Atom.to_string(service.name), "state" => service_state(service)}
    end)
  end

  defp service_state(service) do
    case service_status(service.name) do
      {:ok, %{enabled: false}} -> "stopped"
      {:ok, %{enabled: true, running: true}} when service.available? -> "running"
      {:ok, %{enabled: true}} -> "failed"
      {:ok, _status} -> "stopped"
      :error -> "failed"
    end
  end

  defp service_status(service) do
    {:ok, apply(dependencies().service_manager, :get_service_status, [service])}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp service_error_count do
    service_items()
    |> Enum.count(fn %{"service" => service, "state" => state} ->
      state == "failed" or (state == "running" and service_stats_failed?(service))
    end)
  end

  defp service_stats_failed?(service_id) do
    with {:ok, service} <- resolve_service(service_id),
         stats when is_map(stats) <-
           apply(dependencies().service_manager, :get_service_stats, [service.name]) do
      Map.has_key?(stats, :error) or Map.has_key?(stats, "error")
    else
      _ -> true
    end
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
  end

  defp health_check(%{"service" => service, "state" => "running"}),
    do: %{"name" => service, "status" => "healthy"}

  defp health_check(%{"service" => service, "state" => "stopped"}),
    do: %{"name" => service, "status" => "degraded"}

  defp health_check(%{"service" => service}), do: %{"name" => service, "status" => "unhealthy"}

  defp overall_health(checks) do
    statuses = Enum.map(checks, & &1["status"])

    cond do
      statuses == [] -> "unhealthy"
      Enum.all?(statuses, &(&1 == "healthy")) -> "healthy"
      Enum.all?(statuses, &(&1 == "unhealthy")) -> "unhealthy"
      true -> "degraded"
    end
  end

  defp resolve_controllable_service(service_id) do
    with {:ok, service} <- resolve_service(service_id),
         true <- service.controllable?,
         true <- service.available? do
      {:ok, service}
    else
      _ -> unsupported_error()
    end
  end

  defp resolve_service(service_id) when is_binary(service_id) do
    case Enum.find(apply(dependencies().service_registry, :all, []), fn service ->
           Atom.to_string(service.name) == service_id
         end) do
      nil -> unsupported_error()
      service -> {:ok, service}
    end
  end

  defp resolve_service(_service_id), do: unsupported_error()

  defp command_result(service, state), do: %{"service" => service, "state" => state}

  defp apply_failed(details),
    do: {:error, Error.new(:apply_failed, "apply failed", details)}

  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  if @test_environment do
    defp dependencies do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      %{
        service_manager:
          Keyword.get(config, :service_manager, @production_dependencies.service_manager),
        service_registry:
          Keyword.get(config, :service_registry, @production_dependencies.service_registry)
      }
    end
  else
    defp dependencies, do: @production_dependencies
  end
end
