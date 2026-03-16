defmodule YellowDog.Data.Resource.Hardware do
  @moduledoc """
  Hardware inventory entity.

  Represents a physical or virtual device tracked by the system: servers,
  switches, workstations, IoT devices, etc. Links to DHCP leases via MAC
  address and to network resources via `id`.
  """

  use YellowDog.Data.Collection

  defcollection(:hw_inventory,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets,
    indexes: [:mac, :hostname, :device_type, :status]
  )

  @valid_device_types ~w(server workstation laptop switch router access_point
                         printer iot sensor gateway storage firewall other)

  @valid_statuses ~w(active decommissioned maintenance provisioning unknown)

  defstruct [
    :id,
    :mac,
    :hostname,
    :model,
    :serial,
    :vendor,
    :device_type,
    :location,
    tags: [],
    properties: %{},
    status: "active",
    notes: nil,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          mac: String.t() | nil,
          hostname: String.t() | nil,
          model: String.t() | nil,
          serial: String.t() | nil,
          vendor: String.t() | nil,
          device_type: String.t() | nil,
          location: String.t() | nil,
          tags: [String.t()],
          properties: map(),
          status: String.t(),
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Create a hardware struct from a map, validating required fields."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    hw = %__MODULE__{
      id: attrs[:id] || attrs["id"],
      mac: attrs[:mac] || attrs["mac"],
      hostname: attrs[:hostname] || attrs["hostname"],
      model: attrs[:model] || attrs["model"],
      serial: attrs[:serial] || attrs["serial"],
      vendor: attrs[:vendor] || attrs["vendor"],
      device_type: attrs[:device_type] || attrs["device_type"] || "other",
      location: attrs[:location] || attrs["location"],
      tags: attrs[:tags] || attrs["tags"] || [],
      properties: attrs[:properties] || attrs["properties"] || %{},
      status: attrs[:status] || attrs["status"] || "active",
      notes: attrs[:notes] || attrs["notes"],
      created_at: attrs[:created_at] || now,
      updated_at: now
    }

    validate(hw)
  end

  @doc "Validate a hardware struct."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = hw) do
    cond do
      is_nil(hw.id) or hw.id == "" ->
        {:error, "id is required"}

      hw.mac != nil and not valid_mac?(hw.mac) ->
        {:error, "invalid MAC address format (expected AA:BB:CC:DD:EE:FF)"}

      hw.device_type != nil and hw.device_type not in @valid_device_types ->
        {:error, "invalid device_type: #{hw.device_type}"}

      hw.status not in @valid_statuses ->
        {:error, "invalid status: #{hw.status}"}

      true ->
        {:ok, hw}
    end
  end

  @doc "Update a hardware struct with new attributes."
  @spec update(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def update(%__MODULE__{} = hw, attrs) when is_map(attrs) do
    updated =
      %{hw | updated_at: DateTime.utc_now()}
      |> maybe_put(:mac, attrs)
      |> maybe_put(:hostname, attrs)
      |> maybe_put(:model, attrs)
      |> maybe_put(:serial, attrs)
      |> maybe_put(:vendor, attrs)
      |> maybe_put(:device_type, attrs)
      |> maybe_put(:location, attrs)
      |> maybe_put(:tags, attrs)
      |> maybe_put(:properties, attrs)
      |> maybe_put(:status, attrs)
      |> maybe_put(:notes, attrs)

    validate(updated)
  end

  defp maybe_put(struct, field, attrs) do
    case Map.get(attrs, field, Map.get(attrs, to_string(field))) do
      nil -> struct
      value -> Map.put(struct, field, value)
    end
  end

  defp valid_mac?(mac) when is_binary(mac) do
    Regex.match?(~r/^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/, mac)
  end

  defp valid_mac?(_), do: false
end
