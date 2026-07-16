defmodule YellowDog.Management.Transport do
  @moduledoc """
  Boundary between management state and runtime transport adapters.
  """

  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @callback connected?(:server | :netman, String.t()) :: boolean()
  @callback request(Envelope.t(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  @callback deliver_config(Envelope.t()) :: :ok | {:error, Error.t()}
end
