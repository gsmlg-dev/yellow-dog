defmodule YellowDog.ServerAgent.QueryDispatcher do
  @moduledoc """
  Stateless query-only dispatch boundary for local Server reads.
  """

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @default_runtime_adapter YellowDog.Server.Control
  @allowed_options [:server_id, :capabilities, :runtime_adapter]
  @error_messages %{
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

  @type dispatch_result :: {:ok, map()} | {:error, Error.t()}

  @spec dispatch(Envelope.t(), keyword()) :: dispatch_result()
  def dispatch(envelope, opts) do
    with {:ok, config} <- validate_options(opts),
         {:ok, operation} <- validate_query(envelope, config) do
      dispatch_query(envelope, operation, config.runtime_adapter)
    end
  end

  defp validate_options(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, server_id} <- server_id(Keyword.get(opts, :server_id)),
         {:ok, capabilities} <- capabilities(Keyword.get(opts, :capabilities)),
         {:ok, runtime_adapter} <-
           runtime_adapter(Keyword.get(opts, :runtime_adapter, @default_runtime_adapter)) do
      {:ok,
       %{
         server_id: server_id,
         capabilities: MapSet.new(capabilities),
         runtime_adapter: runtime_adapter
       }}
    else
      _invalid -> invalid()
    end
  end

  defp validate_query(envelope, config) do
    with {:ok, %Envelope{} = envelope} <- Operation.validate_envelope(envelope, :query),
         true <- envelope.target_type == :server,
         true <- envelope.target_id == config.server_id,
         {:ok, %Operation{target_type: :server, kind: :query} = operation} <-
           Operation.lookup(envelope.operation),
         true <- MapSet.member?(config.capabilities, operation.capability) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  end

  defp dispatch_query(envelope, operation, runtime_adapter) do
    if adapter_available?(runtime_adapter) do
      runtime_adapter
      |> invoke_adapter(envelope)
      |> validate_outcome(operation)
    else
      {:error, unsupported_error()}
    end
  end

  defp invoke_adapter(adapter, envelope) do
    {:adapter_return, apply(adapter, :dispatch, [envelope])}
  rescue
    _exception -> :dispatcher_failure
  catch
    _kind, _reason -> :dispatcher_failure
  end

  defp validate_outcome({:adapter_return, {:ok, result}}, operation) do
    case Operation.validate_result(operation, result) do
      {:ok, validated} -> {:ok, validated}
      {:error, %Error{}} -> internal()
    end
  end

  defp validate_outcome({:adapter_return, {:error, %Error{} = error}}, _operation),
    do: {:error, sanitize_error(error)}

  defp validate_outcome(_invalid, _operation), do: internal()

  defp adapter_available?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 1)
  end

  defp server_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "",
         true <- value not in [".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp capabilities(values) do
    with {:ok, values} <- Bounds.list(values),
         true <- Enum.all?(values, &valid_capability?/1),
         true <- length(values) == length(Enum.uniq(values)) do
      {:ok, values}
    else
      _invalid -> :error
    end
  end

  defp valid_capability?(value) do
    match?({:ok, capability} when capability != "", Bounds.message(value))
  end

  defp runtime_adapter(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp runtime_adapter(_value), do: :error

  defp sanitize_error(%Error{code: code}) do
    case Map.fetch(@error_messages, code) do
      {:ok, message} -> Error.new(code, message, %{})
      :error -> internal_error()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp unsupported_error, do: Error.new(:unsupported, "unsupported operation", %{})
  defp internal, do: {:error, internal_error()}
  defp internal_error, do: Error.new(:internal, "internal error", %{})
end
