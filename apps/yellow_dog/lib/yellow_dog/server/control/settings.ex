defmodule YellowDog.Server.Control.Settings do
  @moduledoc false

  alias YellowDog.Config.Manager
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @production_dependencies %{manager: Manager}
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.settings.effective.get" = operation, payload),
    do: read(operation, payload, :effective)

  def dispatch("server.settings.source.get" = operation, payload),
    do: read(operation, payload, :source)

  def dispatch("server.settings.revision.get" = operation, payload),
    do: read(operation, payload, :revision)

  def dispatch("server.settings.validation.get" = operation, payload),
    do: read(operation, payload, :validation)

  def dispatch("server.settings.update" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload) do
      manager_call(:update, [payload["service"], payload["entries"]])
    end
  end

  def dispatch("server.settings.apply" = operation, payload),
    do: service_mutation(operation, payload, :apply)

  def dispatch("server.settings.reload" = operation, payload),
    do: service_mutation(operation, payload, :reload)

  def dispatch("server.settings.rollback" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload) do
      manager_call(:rollback, [payload["service"], payload["target_revision"]])
    end
  end

  def dispatch(_operation, _payload), do: invalid_error()

  @spec current(String.t(), map()) :: {:error, Error.t()}
  def current(operation, payload) do
    with {:ok, _payload} <- validate_payload(operation, payload) do
      unsupported_error()
    end
  end

  defp read(operation, payload, function) do
    with {:ok, payload} <- validate_payload(operation, payload) do
      manager_call(function, [payload["service"]])
    end
  end

  defp service_mutation(operation, payload, function) do
    with {:ok, payload} <- validate_payload(operation, payload) do
      manager_call(function, [payload["service"]])
    end
  end

  defp validate_payload(operation_name, payload) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, payload} <- Operation.validate_payload(operation, payload) do
      {:ok, payload}
    else
      _other -> invalid_error()
    end
  end

  defp manager_call(function, arguments) do
    with {:ok, manager} <- manager(),
         true <- Code.ensure_loaded?(manager),
         true <- function_exported?(manager, function, length(arguments)) do
      manager
      |> apply(function, arguments)
      |> manager_result()
    else
      false -> not_found_error()
      {:error, %Error{}} = error -> error
      _other -> internal_error()
    end
  rescue
    _exception -> apply_failed_error()
  catch
    :exit, :noproc -> not_found_error()
    :exit, {:noproc, _details} -> not_found_error()
    _kind, _reason -> apply_failed_error()
  end

  defp manager_result({:ok, value}) when is_map(value), do: {:ok, value}
  defp manager_result({:error, reason}), do: manager_error(reason)
  defp manager_result(_result), do: apply_failed_error()

  defp manager_error(:invalid), do: invalid_error()
  defp manager_error(:not_found), do: not_found_error()
  defp manager_error(:conflict), do: conflict_error()
  defp manager_error(:unsupported), do: unsupported_error()
  defp manager_error(:apply_failed), do: apply_failed_error()
  defp manager_error(:rollback_failed), do: rollback_failed_error()
  defp manager_error(_reason), do: apply_failed_error()

  if @test_environment do
    defp manager do
      case Application.get_env(:yellow_dog, __MODULE__, []) do
        [] -> {:ok, @production_dependencies.manager}
        [manager: manager] when is_atom(manager) and not is_nil(manager) -> {:ok, manager}
        _config -> internal_error()
      end
    end
  else
    defp manager, do: {:ok, @production_dependencies.manager}
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}
  defp rollback_failed_error, do: {:error, Error.new(:rollback_failed, "rollback failed", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
