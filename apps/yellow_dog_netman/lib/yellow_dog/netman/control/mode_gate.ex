defmodule YellowDog.Netman.Control.ModeGate do
  @moduledoc false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @spec check(Operation.t(), :managed | :observe_first | :observe, map()) ::
          :ok | {:error, Error.t()}
  def check(%Operation{kind: :query}, _mode, _payload), do: :ok
  def check(%Operation{name: "netman.profiles.validate"}, _mode, _payload), do: :ok
  def check(%Operation{}, :managed, _payload), do: :ok
  def check(%Operation{}, _mode, _payload), do: unsupported_error()
  def check(_operation, _mode, _payload), do: unsupported_error()

  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
end
