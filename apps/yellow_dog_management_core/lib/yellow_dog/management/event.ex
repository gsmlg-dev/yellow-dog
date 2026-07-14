defmodule YellowDog.Management.Event do
  @moduledoc """
  Concrete management event emitted by server and Netman registries.
  """

  @enforce_keys [:id, :source, :source_id, :type, :occurred_at, :sequence]
  defstruct [
    :id,
    :source,
    :source_id,
    :type,
    :message,
    :occurred_at,
    :sequence,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source: :server | :netman,
          source_id: String.t(),
          type: atom(),
          message: String.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t(),
          sequence: pos_integer()
        }

  @doc false
  def new(attrs) do
    # Per-node monotonic sequence numbers are only for local in-memory ordering.
    # Persistent or distributed storage must not treat them as a global clock.
    sequence = System.unique_integer([:positive, :monotonic])

    %__MODULE__{
      id: "evt-#{sequence}",
      source: Map.fetch!(attrs, :source),
      source_id: Map.fetch!(attrs, :source_id),
      type: Map.fetch!(attrs, :type),
      message: Map.get(attrs, :message),
      metadata: Map.get(attrs, :metadata, %{}),
      occurred_at: DateTime.utc_now(:second),
      sequence: sequence
    }
  end
end
