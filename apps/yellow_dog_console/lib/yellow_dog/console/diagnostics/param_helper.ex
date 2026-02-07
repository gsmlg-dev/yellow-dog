defmodule YellowDog.Console.Diagnostics.ParamHelper do
  @moduledoc """
  Shared parameter parsing and error formatting helpers for diagnostics clients.

  Handles mixed atom/string key maps from LiveView form params,
  with type coercion for integers and booleans.
  """

  @doc "Gets a string value from params, checking both atom and string keys."
  def get_string(params, key) do
    Map.get(params, key) || Map.get(params, to_string(key)) || ""
  end

  @doc "Gets an integer value from params with type coercion and default."
  def get_integer(params, key, default) do
    value = Map.get(params, key) || Map.get(params, to_string(key)) || default

    case value do
      v when is_integer(v) ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  @doc "Gets a boolean value from params with type coercion and default."
  def get_boolean(params, key, default) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    case value do
      v when is_boolean(v) -> v
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  @doc "Formats common diagnostics error reasons into human-readable strings."
  def format_error(:timeout), do: "Query timed out"
  def format_error({:socket_error, reason}), do: "Socket error: #{inspect(reason)}"
  def format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  def format_error({:build_error, msg}), do: "Build error: #{msg}"
  def format_error(reason), do: inspect(reason)
end
