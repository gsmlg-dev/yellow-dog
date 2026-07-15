defmodule YellowDog.Sync do
  alias YellowDog.Sync.Envelope

  # Envelope is introduced by Task 2; dynamic dispatch keeps this facade compile-safe meanwhile.
  def encode(envelope), do: apply(Envelope, :encode, [envelope])
  def decode(payload), do: apply(Envelope, :decode, [payload])
end
