defmodule YellowDog.Management.Netman do
  @moduledoc """
  Concrete managed Netman instance.

  A Netman represents a `yellow_dog_netman` runtime with a profile such as
  `:cloud_server`, `:local_server`, `:vm`, or `:custom`.
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :apply_mode,
    :last_seen_at,
    :registered_at,
    :updated_at,
    profile: :custom,
    status: :registered,
    features: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          profile: atom() | String.t(),
          apply_mode: atom() | String.t() | nil,
          status: atom() | String.t(),
          features: map(),
          metadata: map(),
          last_seen_at: DateTime.t() | nil,
          registered_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
