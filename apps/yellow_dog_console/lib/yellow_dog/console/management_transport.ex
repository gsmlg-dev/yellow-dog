defmodule YellowDog.Console.ManagementTransport do
  @moduledoc """
  Correlated management transport for active concrete Server control channels.
  """

  @behaviour YellowDog.Management.Transport

  alias YellowDog.Console.ServerChannel.SyncCodec
  alias YellowDog.Console.ServerConnections

  @error_module :"Elixir.YellowDog.Sync.Error"

  @impl true
  def connected?(:server, server_id) when is_binary(server_id) and server_id != "" do
    ServerConnections.connected?(server_id)
  end

  def connected?(_target_type, _target_id), do: false

  @impl true
  def request(envelope, timeout) when is_integer(timeout) and timeout > 0 do
    with {:ok, encoded, summary} <- SyncCodec.encode_request(envelope),
         reply <- ServerConnections.request(summary, encoded, timeout) do
      transport_reply(reply)
    else
      _invalid -> error(:invalid, "invalid management request")
    end
  end

  def request(_envelope, _timeout), do: error(:invalid, "invalid management request")

  @impl true
  def deliver_config(envelope) do
    with {:ok, encoded, summary} <- SyncCodec.encode_config_delivery(envelope),
         :ok <- ServerConnections.deliver(summary, encoded) do
      :ok
    else
      {:error, :not_connected} -> not_connected()
      {:error, :invalid} -> error(:invalid, "invalid config delivery")
      _failure -> error(:internal, "config delivery failed")
    end
  end

  defp transport_reply({:ok, value}) when is_map(value), do: {:ok, value}

  defp transport_reply({:error, result_error}) when is_map(result_error) do
    if Map.get(result_error, :__struct__) == @error_module,
      do: {:error, result_error},
      else: error(:internal, "management request failed")
  end

  defp transport_reply({:error, :timeout}), do: error(:timeout, "management request timed out")
  defp transport_reply({:error, :not_connected}), do: not_connected()
  defp transport_reply({:error, :invalid}), do: error(:invalid, "invalid management request")

  defp transport_reply({:error, :request_limit}),
    do: error(:internal, "management request capacity exceeded")

  defp transport_reply(_failure), do: error(:internal, "management request failed")

  defp not_connected, do: error(:not_connected, "runtime is not connected")

  defp error(code, message) do
    with true <- Code.ensure_loaded?(@error_module),
         result <- dynamic_apply(@error_module, :new, [code, message, %{}]),
         true <- is_map(result),
         true <- Map.get(result, :__struct__) == @error_module do
      {:error, result}
    else
      _failure -> {:error, :internal}
    end
  rescue
    _exception -> {:error, :internal}
  catch
    :exit, _reason -> {:error, :internal}
  end

  defp dynamic_apply(module, function, arguments), do: apply(module, function, arguments)
end
