defmodule YellowDog.Data.Resource.NetworkResource do
  @moduledoc """
  Network resource entity.

  Represents a network-layer resource: IP allocation, domain name, VLAN, or
  subnet. Links to hardware via `hardware_id` for tracking which device holds
  which network resources.
  """

  use YellowDog.Data.Collection

  defcollection(:network_resources,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets,
    indexes: [:type, :hardware_id, :pool_name, :status]
  )

  @valid_types ~w(ipv4 ipv6 domain vlan subnet prefix)
  @valid_sources ~w(dhcp static manual dns auto)
  @valid_statuses ~w(allocated available reserved deprecated)

  defstruct [
    :id,
    :type,
    :value,
    :hardware_id,
    :pool_name,
    source: "manual",
    status: "allocated",
    tags: [],
    properties: %{},
    notes: nil,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          value: String.t(),
          hardware_id: String.t() | nil,
          pool_name: String.t() | nil,
          source: String.t(),
          status: String.t(),
          tags: [String.t()],
          properties: map(),
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Create a network resource from a map, validating required fields."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    resource = %__MODULE__{
      id: attrs[:id] || attrs["id"],
      type: attrs[:type] || attrs["type"],
      value: attrs[:value] || attrs["value"],
      hardware_id: attrs[:hardware_id] || attrs["hardware_id"],
      pool_name: attrs[:pool_name] || attrs["pool_name"],
      source: attrs[:source] || attrs["source"] || "manual",
      status: attrs[:status] || attrs["status"] || "allocated",
      tags: attrs[:tags] || attrs["tags"] || [],
      properties: attrs[:properties] || attrs["properties"] || %{},
      notes: attrs[:notes] || attrs["notes"],
      created_at: attrs[:created_at] || now,
      updated_at: now
    }

    validate(resource)
  end

  @doc "Validate a network resource struct."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = resource) do
    cond do
      is_nil(resource.id) or resource.id == "" ->
        {:error, "id is required"}

      is_nil(resource.type) or resource.type == "" ->
        {:error, "type is required"}

      resource.type not in @valid_types ->
        {:error, "invalid type: #{resource.type}"}

      is_nil(resource.value) or resource.value == "" ->
        {:error, "value is required"}

      resource.source not in @valid_sources ->
        {:error, "invalid source: #{resource.source}"}

      resource.status not in @valid_statuses ->
        {:error, "invalid status: #{resource.status}"}

      true ->
        {:ok, resource}
    end
  end
end
