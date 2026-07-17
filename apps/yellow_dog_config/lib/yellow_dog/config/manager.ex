defmodule YellowDog.Config.Manager do
  @moduledoc """
  Stable Settings owner boundary for unsupported configuration operations.

  Exact Settings grammar and aggregate payload validation belong to the
  Settings adapter. This module checks only bounded service identifiers and
  operation-level container types, then returns typed unsupported without
  reading or traversing payload contents or runtime state.
  """

  @max_service_bytes 128
  @service_pattern ~r/\A[a-z][a-z0-9_]*\z/

  @type error :: {:error, :invalid | :unsupported}

  @spec effective(term()) :: error()
  def effective(service), do: service_operation(service)

  @spec source(term()) :: error()
  def source(service), do: service_operation(service)

  @spec revision(term()) :: error()
  def revision(service), do: service_operation(service)

  @spec validation(term()) :: error()
  def validation(service), do: service_operation(service)

  @spec update(term(), term()) :: error()
  def update(service, entries) when is_list(entries), do: service_operation(service)
  def update(_service, _entries), do: invalid()

  @spec apply(term()) :: error()
  def apply(service), do: service_operation(service)

  @spec reload(term()) :: error()
  def reload(service), do: service_operation(service)

  @spec rollback(term(), term()) :: error()
  def rollback(service, target_revision) when is_binary(target_revision),
    do: service_operation(service)

  def rollback(_service, _target_revision), do: invalid()

  defp service_operation(service) do
    if valid_service?(service), do: unsupported(), else: invalid()
  end

  defp valid_service?(service)
       when is_binary(service) and byte_size(service) >= 1 and
              byte_size(service) <= @max_service_bytes do
    String.valid?(service) and Regex.match?(@service_pattern, service)
  end

  defp valid_service?(_service), do: false

  defp invalid, do: {:error, :invalid}
  defp unsupported, do: {:error, :unsupported}
end
