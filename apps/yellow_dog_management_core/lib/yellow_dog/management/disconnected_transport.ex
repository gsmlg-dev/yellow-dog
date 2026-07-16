defmodule YellowDog.Management.DisconnectedTransport do
  @moduledoc false

  @behaviour YellowDog.Management.Transport

  alias YellowDog.Sync.Error

  @impl true
  def connected?(_target_type, _target_id), do: false

  @impl true
  def request(_envelope, _timeout), do: not_connected()

  @impl true
  def deliver_config(_envelope), do: not_connected()

  defp not_connected do
    {:error, Error.new(:not_connected, "runtime is not connected", %{})}
  end
end
