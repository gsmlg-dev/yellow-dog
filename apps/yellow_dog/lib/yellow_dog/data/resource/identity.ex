defmodule YellowDog.Data.Resource.Identity do
  @moduledoc """
  Person or group identity entity.

  Represents an owner or responsible party for hardware and network resources.
  Used for tracking who owns what, access control, and organizational structure.
  """

  use YellowDog.Data.Collection

  defcollection(:identities,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets,
    indexes: [:email, :type, :department, :status]
  )

  @valid_types ~w(person group service_account)
  @valid_statuses ~w(active inactive)

  defstruct [
    :id,
    :name,
    :email,
    type: "person",
    role: nil,
    department: nil,
    tags: [],
    properties: %{},
    status: "active",
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          email: String.t() | nil,
          type: String.t(),
          role: String.t() | nil,
          department: String.t() | nil,
          tags: [String.t()],
          properties: map(),
          status: String.t(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Create an identity struct from a map, validating required fields."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    identity = %__MODULE__{
      id: attrs[:id] || attrs["id"],
      name: attrs[:name] || attrs["name"],
      email: attrs[:email] || attrs["email"],
      type: attrs[:type] || attrs["type"] || "person",
      role: attrs[:role] || attrs["role"],
      department: attrs[:department] || attrs["department"],
      tags: attrs[:tags] || attrs["tags"] || [],
      properties: attrs[:properties] || attrs["properties"] || %{},
      status: attrs[:status] || attrs["status"] || "active",
      created_at: attrs[:created_at] || now,
      updated_at: now
    }

    validate(identity)
  end

  @doc "Validate an identity struct."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = identity) do
    cond do
      is_nil(identity.id) or identity.id == "" ->
        {:error, "id is required"}

      is_nil(identity.name) or identity.name == "" ->
        {:error, "name is required"}

      identity.email != nil and not valid_email?(identity.email) ->
        {:error, "invalid email format"}

      identity.type not in @valid_types ->
        {:error, "invalid type: #{identity.type}"}

      identity.status not in @valid_statuses ->
        {:error, "invalid status: #{identity.status}"}

      true ->
        {:ok, identity}
    end
  end

  @doc "Update an identity struct with new attributes."
  @spec update(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def update(%__MODULE__{} = identity, attrs) when is_map(attrs) do
    updated =
      %{identity | updated_at: DateTime.utc_now()}
      |> maybe_put(:name, attrs)
      |> maybe_put(:email, attrs)
      |> maybe_put(:type, attrs)
      |> maybe_put(:role, attrs)
      |> maybe_put(:department, attrs)
      |> maybe_put(:tags, attrs)
      |> maybe_put(:properties, attrs)
      |> maybe_put(:status, attrs)

    validate(updated)
  end

  defp maybe_put(struct, field, attrs) do
    case Map.get(attrs, field, Map.get(attrs, to_string(field))) do
      nil -> struct
      value -> Map.put(struct, field, value)
    end
  end

  defp valid_email?(email) when is_binary(email) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email)
  end

  defp valid_email?(_), do: false
end
