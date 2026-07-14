defmodule YellowDog.Management.Server do
  @moduledoc """
  Concrete managed server instance.

  A server represents a `yellow_dog_server` runtime with a server profile such
  as `:cloud_dns`, `:local_network`, or `:custom`.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :last_seen_at,
    :registered_at,
    :updated_at,
    profile: :custom,
    status: :registered,
    services: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          profile: atom() | String.t(),
          status: atom() | String.t(),
          services: map(),
          metadata: map(),
          last_seen_at: DateTime.t() | nil,
          registered_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
