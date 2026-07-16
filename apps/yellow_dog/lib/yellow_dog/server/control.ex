defmodule YellowDog.Server.Control do
  @moduledoc """
  Typed dispatch boundary for Server remote-management operations.
  """

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @spec dispatch(Envelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(envelope), do: Dispatcher.dispatch(envelope)
end
