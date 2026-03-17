defmodule YellowDog.Data.Resource.Ownership do
  @moduledoc """
  Ownership link between an identity and a hardware resource.

  Models the relationship "identity X owns/manages hardware Y" with metadata
  such as assignment date, role, and notes.
  """

  use YellowDog.Data.Collection

  defcollection(:ownership_links,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets,
    indexes: [:identity_id, :hardware_id]
  )

  @valid_roles ~w(owner user manager)

  defstruct [
    :id,
    :identity_id,
    :hardware_id,
    role: "owner",
    assigned_at: nil,
    notes: nil,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          identity_id: String.t(),
          hardware_id: String.t(),
          role: String.t(),
          assigned_at: DateTime.t() | nil,
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Create an ownership link from a map, validating required fields."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    identity_id = attrs[:identity_id] || attrs["identity_id"]
    hardware_id = attrs[:hardware_id] || attrs["hardware_id"]

    link = %__MODULE__{
      id: attrs[:id] || attrs["id"] || "#{identity_id}:#{hardware_id}",
      identity_id: identity_id,
      hardware_id: hardware_id,
      role: attrs[:role] || attrs["role"] || "owner",
      assigned_at: attrs[:assigned_at] || now,
      notes: attrs[:notes] || attrs["notes"],
      created_at: attrs[:created_at] || now,
      updated_at: now
    }

    validate(link)
  end

  @doc "Validate an ownership struct."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = link) do
    cond do
      is_nil(link.identity_id) or link.identity_id == "" ->
        {:error, "identity_id is required"}

      is_nil(link.hardware_id) or link.hardware_id == "" ->
        {:error, "hardware_id is required"}

      link.role not in @valid_roles ->
        {:error, "invalid role: #{link.role}"}

      true ->
        {:ok, link}
    end
  end
end
