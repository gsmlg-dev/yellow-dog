defmodule YellowDog.NetmanAgent.Dispatcher do
  @moduledoc """
  Stateless durable dispatch boundary for local Netman commands.
  """

  alias YellowDog.NetmanAgent.CommandJournal
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @default_runtime_adapter :"Elixir.YellowDog.Netman.Control"
  @allowed_options [:netman_id, :capabilities, :command_journal, :runtime_adapter]
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

  @type dispatch_result ::
          {:ok, map()}
          | {:error, Error.t()}
          | {:unknown, String.t()}

  @spec dispatch(Envelope.t(), keyword()) :: dispatch_result()
  def dispatch(envelope, opts) do
    with {:ok, config} <- validate_options(opts),
         {:ok, operation} <- validate_command(envelope, config) do
      reserve(envelope, operation, config)
    end
  end

  defp validate_options(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, netman_id} <- netman_id(Keyword.get(opts, :netman_id)),
         {:ok, capabilities} <- capabilities(Keyword.get(opts, :capabilities)),
         {:ok, command_journal} <-
           command_journal(Keyword.get(opts, :command_journal, CommandJournal)),
         {:ok, runtime_adapter} <-
           runtime_adapter(Keyword.get(opts, :runtime_adapter, @default_runtime_adapter)) do
      {:ok,
       %{
         netman_id: netman_id,
         capabilities: MapSet.new(capabilities),
         command_journal: command_journal,
         runtime_adapter: runtime_adapter
       }}
    else
      _invalid -> invalid()
    end
  end

  defp validate_command(envelope, config) do
    with {:ok, %Envelope{} = envelope} <- Operation.validate_envelope(envelope, :command),
         true <- envelope.target_type == :netman,
         true <- envelope.target_id == config.netman_id,
         {:ok, %Operation{target_type: :netman, kind: :command} = operation} <-
           Operation.lookup(envelope.operation),
         true <- MapSet.member?(config.capabilities, operation.capability) do
      {:ok, operation}
    else
      _invalid -> invalid()
    end
  end

  defp reserve(envelope, operation, config) do
    case journal_call(fn ->
           CommandJournal.reserve(envelope, config.command_journal)
         end) do
      {:reserved, request_id} when request_id == envelope.request_id ->
        mark_running(envelope, operation, config)

      {:replay, outcome} ->
        replay(outcome)

      {:error, %Error{}} = error ->
        error

      _invalid ->
        internal()
    end
  end

  defp mark_running(envelope, operation, config) do
    case journal_call(fn ->
           CommandJournal.mark_running(envelope.request_id, config.command_journal)
         end) do
      :ok -> dispatch_new(envelope, operation, config)
      {:error, %Error{}} = error -> error
      _invalid -> internal()
    end
  end

  defp dispatch_new(envelope, operation, config) do
    if adapter_available?(config.runtime_adapter) do
      config.runtime_adapter
      |> invoke_adapter(envelope)
      |> persist_outcome(envelope.request_id, operation, config.command_journal)
    else
      persist_failure(envelope.request_id, unsupported_error(), config.command_journal)
    end
  end

  defp invoke_adapter(adapter, envelope) do
    {:adapter_return, apply(adapter, :dispatch, [envelope])}
  rescue
    _exception -> {:dispatcher_failure, internal_error()}
  catch
    _kind, _reason -> {:dispatcher_failure, internal_error()}
  end

  defp persist_outcome({:adapter_return, {:ok, result}}, request_id, operation, command_journal) do
    case Operation.validate_result(operation, result) do
      {:ok, validated} -> persist_success(request_id, validated, command_journal)
      {:error, %Error{}} -> persist_failure(request_id, internal_error(), command_journal)
    end
  end

  defp persist_outcome(
         {:adapter_return, {:error, %Error{} = error}},
         request_id,
         _operation,
         command_journal
       ) do
    persist_failure(request_id, sanitize_error(error), command_journal)
  end

  defp persist_outcome(
         {:dispatcher_failure, _error},
         request_id,
         _operation,
         command_journal
       ) do
    persist_failure(request_id, internal_error(), command_journal)
  end

  defp persist_outcome(_invalid, request_id, _operation, command_journal) do
    persist_failure(request_id, internal_error(), command_journal)
  end

  defp persist_success(request_id, result, command_journal) do
    case journal_call(fn ->
           CommandJournal.complete_success(request_id, result, command_journal)
         end) do
      {:ok, ^result} -> {:ok, result}
      {:error, %Error{}} = error -> error
      _invalid -> internal()
    end
  end

  defp persist_failure(request_id, error, command_journal) do
    case journal_call(fn ->
           CommandJournal.complete_failure(request_id, error, command_journal)
         end) do
      {:error, ^error} -> {:error, error}
      {:error, %Error{}} = journal_error -> journal_error
      _invalid -> internal()
    end
  end

  defp replay({:ok, result}) when is_map(result), do: {:ok, result}
  defp replay({:error, %Error{}} = error), do: error
  defp replay({:unknown, request_id}) when is_binary(request_id), do: {:unknown, request_id}
  defp replay(_invalid), do: internal()

  defp adapter_available?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :dispatch, 1)
  end

  defp journal_call(callback) do
    callback.()
  rescue
    _exception -> internal()
  catch
    :exit, _reason -> internal()
    _kind, _reason -> internal()
  end

  defp netman_id(value) do
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

  defp command_journal(value) when is_pid(value), do: {:ok, value}
  defp command_journal(value) when is_atom(value) and not is_nil(value), do: {:ok, value}

  defp command_journal({name, node} = value)
       when is_atom(name) and not is_nil(name) and is_atom(node) and not is_nil(node),
       do: {:ok, value}

  defp command_journal({:global, _term} = value), do: {:ok, value}

  defp command_journal({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp command_journal(_value), do: :error

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
