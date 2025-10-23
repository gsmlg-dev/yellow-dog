defmodule DNS.Error do
  @moduledoc """
  Centralized error handling for DNS operations to prevent information disclosure.

  This module provides standardized error messages that don't expose internal
  buffer contents or sensitive information that could be used by attackers.
  """

  @type error_type ::
          :format_error | :parse_error | :validation_error | :compression_error | :security_error

  @doc """
  Create a standardized error message that doesn't expose sensitive information.
  """
  @spec new(error_type(), module(), term(), map()) :: {String.t(), map()}
  def new(type, module, reason, context \\ %{}) do
    error_message = format_error_message(type, module)
    {error_message, Map.put(context, :internal_reason, reason)}
  end

  @spec format_error_message(error_type(), module()) :: String.t()
  defp format_error_message(:format_error, module) do
    case module do
      DNS.Message.Domain -> "DNS.Message.Domain Format Error"
      DNS.Message.Record -> "DNS.Message.Record Format Error"
      DNS.Message.Question -> "DNS.Message.Question Format Error"
      DNS.Message.Header -> "DNS.Message.Header Format Error"
      _ -> "DNS Message Format Error"
    end
  end

  defp format_error_message(:parse_error, module) do
    case module do
      DNS.Message.Domain -> "DNS.Message.Domain Parse Error"
      DNS.Message.Record -> "DNS.Message.Record Parse Error"
      DNS.Zone.FileParser -> "DNS Zone File Parse Error"
      _ -> "DNS Parse Error"
    end
  end

  defp format_error_message(:validation_error, module) do
    case module do
      DNS.Message.Record -> "DNS.Message.Record Validation Error"
      DNS.Zone.FileParser -> "DNS Zone File Validation Error"
      _ -> "DNS Validation Error"
    end
  end

  defp format_error_message(:compression_error, DNS.Message.Domain) do
    "DNS.Message.Domain Compression Error"
  end

  defp format_error_message(:compression_error, _module) do
    "DNS Compression Error"
  end

  defp format_error_message(:security_error, module) do
    case module do
      DNS.Message.Domain -> "DNS.Message.Domain Security Error"
      DNS.Message.Record -> "DNS.Message.Record Security Error"
      DNS.Zone.FileParser -> "DNS Zone File Security Error"
      _ -> "DNS Security Error"
    end
  end

  defp format_error_message(_type, _module) do
    "DNS Error"
  end

  @doc """
  Log detailed errors internally for debugging while returning generic messages to clients.
  """
  @spec log_detailed_error(error_type(), module(), term(), map()) :: :ok
  def log_detailed_error(type, module, reason, context \\ %{}) do
    if Application.get_env(:dns, :detailed_errors, false) do
      require Logger

      Logger.error(
        "DNS Detailed Error: #{inspect(type)} in #{module}: #{inspect(reason)} context: #{inspect(context)}"
      )
    end

    :ok
  end
end
