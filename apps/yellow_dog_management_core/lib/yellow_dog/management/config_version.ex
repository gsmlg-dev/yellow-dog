defmodule YellowDog.Management.ConfigVersion do
  @moduledoc """
  Published configuration version placeholder for managed servers and Netman.

  This struct intentionally contains only metadata for the foundation PR. A
  later persistent backend can store full config payloads and applied status.
  """

  @enforce_keys [:id, :target_type, :target_id, :version]
  defstruct [
    :id,
    :target_type,
    :target_id,
    :version,
    :profile,
    :config,
    :published_at,
    :applied_at,
    status: :draft
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          target_type: :server | :netman,
          target_id: String.t(),
          version: non_neg_integer(),
          profile: atom() | String.t() | nil,
          config: map() | nil,
          status: atom(),
          published_at: DateTime.t() | nil,
          applied_at: DateTime.t() | nil
        }
end
