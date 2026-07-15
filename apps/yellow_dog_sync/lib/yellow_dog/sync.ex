defmodule YellowDog.Sync do
  alias YellowDog.Sync.Envelope

  def encode(%Envelope{} = envelope), do: Envelope.encode(envelope)
  def decode(payload), do: Envelope.decode(payload)
end
