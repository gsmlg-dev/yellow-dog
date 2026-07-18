defmodule YellowDog.Netman.Control do
  @moduledoc """
  Typed dispatch boundary for Netman remote-management operations.
  """

  alias YellowDog.Netman.Control.Dispatcher
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @spec dispatch(Envelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(envelope), do: Dispatcher.dispatch(envelope)
end
