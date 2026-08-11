defmodule YellowDog.Console.ManagementResult do
  @moduledoc """
  Stable, presentation-ready result returned by console management gateways.

  Runtime errors are reduced to the public control-plane vocabulary before a
  LiveView sees them. Internal failures deliberately discard their original
  message and metadata.
  """

  alias YellowDog.Sync.Error

  @error_codes [
    :not_connected,
    :not_found,
    :invalid,
    :conflict,
    :unsupported,
    :timeout,
    :apply_failed,
    :rollback_failed,
    :internal
  ]
  @internal_message "The management request failed"
  @max_message_graphemes 512
  @fallback_messages %{
    not_connected: "The selected runtime is not connected",
    not_found: "The selected resource was not found",
    invalid: "The management request was invalid",
    conflict: "The management request conflicted with newer state",
    unsupported: "The selected runtime does not support this operation",
    timeout: "The management request timed out",
    apply_failed: "The configuration could not be applied",
    rollback_failed: "The configuration could not be rolled back",
    internal: @internal_message
  }

  @enforce_keys [:status]
  defstruct [
    :value,
    :source,
    :observed_at,
    :snapshot,
    :code,
    :message,
    status: :error,
    details: %{}
  ]

  @type source :: :runtime | :cache | :desired | nil
  @type t :: %__MODULE__{
          status: :ok | :error,
          value: term(),
          source: source(),
          observed_at: DateTime.t() | nil,
          snapshot: map() | nil,
          code: Error.code() | nil,
          message: String.t() | nil,
          details: map()
        }

  @spec normalize(term(), keyword()) :: t()
  def normalize(result, opts \\ [])

  def normalize({:ok, value}, opts) when is_list(opts) do
    %__MODULE__{
      status: :ok,
      value: value,
      source: Keyword.get(opts, :source),
      observed_at: Keyword.get(opts, :observed_at),
      snapshot: Keyword.get(opts, :snapshot)
    }
  end

  def normalize({:error, %Error{code: :internal}}, _opts), do: internal()

  def normalize({:error, %Error{code: code, message: message, details: details}}, _opts)
      when code in @error_codes do
    %__MODULE__{
      status: :error,
      code: code,
      message: safe_message(message, code),
      details: safe_details(details)
    }
  end

  def normalize(_result, _opts), do: internal()

  @doc "Returns the common assigns consumed by management-backed LiveViews."
  @spec assigns(t()) :: map()
  def assigns(%__MODULE__{status: :ok} = result) do
    %{
      management_status: :ok,
      management_value: result.value,
      management_source: result.source,
      management_observed_at: result.observed_at,
      management_error: nil
    }
  end

  def assigns(%__MODULE__{status: :error} = result) do
    %{
      management_status: :error,
      management_value: nil,
      management_source: nil,
      management_observed_at: nil,
      management_error: %{
        code: result.code,
        message: result.message,
        details: result.details
      }
    }
  end

  @doc "Returns a stable Phoenix flash tuple, or nil for successful results."
  @spec flash(t()) :: {:error, String.t()} | nil
  def flash(%__MODULE__{status: :ok}), do: nil
  def flash(%__MODULE__{status: :error, message: message}), do: {:error, message}

  defp internal do
    %__MODULE__{
      status: :error,
      code: :internal,
      message: @internal_message,
      details: %{}
    }
  end

  defp safe_message(message, code) when is_binary(message) do
    if String.valid?(message) and not local_diagnostic?(message) do
      String.slice(message, 0, @max_message_graphemes)
    else
      Map.fetch!(@fallback_messages, code)
    end
  end

  defp safe_message(_message, code), do: Map.fetch!(@fallback_messages, code)

  defp safe_details(details) when is_map(details) do
    details
    |> Enum.take(100)
    |> Enum.reduce(%{}, fn
      {key, value}, sanitized when is_binary(key) ->
        if sensitive_key?(key) do
          sanitized
        else
          case safe_detail(value, 7) do
            {:ok, value} -> Map.put(sanitized, key, value)
            :error -> sanitized
          end
        end

      _entry, sanitized ->
        sanitized
    end)
  end

  defp safe_details(_details), do: %{}

  defp safe_detail(value, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp safe_detail(value, _depth) when is_binary(value) do
    cond do
      not String.valid?(value) -> :error
      local_diagnostic?(value) -> {:ok, "[redacted]"}
      true -> {:ok, String.slice(value, 0, @max_message_graphemes)}
    end
  end

  defp safe_detail(value, depth) when is_map(value) and depth > 0,
    do: {:ok, safe_details_at_depth(value, depth - 1)}

  defp safe_detail(value, depth) when is_list(value) and depth > 0 do
    value
    |> Enum.take(100)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
      case safe_detail(item, depth - 1) do
        {:ok, item} -> {:cont, {:ok, [item | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp safe_detail(_value, _depth), do: :error

  defp safe_details_at_depth(details, depth) do
    details
    |> Enum.take(100)
    |> Enum.reduce(%{}, fn
      {key, value}, sanitized when is_binary(key) ->
        if sensitive_key?(key) do
          sanitized
        else
          case safe_detail(value, depth) do
            {:ok, value} -> Map.put(sanitized, key, value)
            :error -> sanitized
          end
        end

      _entry, sanitized ->
        sanitized
    end)
  end

  defp sensitive_key?(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
    |> then(&Regex.match?(~r/(?:path|file|stack|trace|exception|pid|reference|handle)/, &1))
  end

  defp local_diagnostic?(text) do
    Regex.match?(~r{(?:^|\s)/(?:[^\s]+)}, text) or
      Regex.match?(~r{\b[A-Za-z]:[\\/]}, text) or
      Regex.match?(~r{\.(?:ex|exs|erl):\d+\b}, text) or
      String.contains?(text, ["#PID<", "** (", "stacktrace:"])
  end
end
