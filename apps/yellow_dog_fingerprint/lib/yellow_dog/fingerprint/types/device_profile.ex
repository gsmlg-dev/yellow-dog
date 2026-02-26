defmodule YellowDog.Fingerprint.Types.DeviceProfile do
  @moduledoc """
  What a fingerprint resolves to — the device identity.
  """

  @type device_type ::
          :computer
          | :phone
          | :tablet
          | :printer
          | :voip_phone
          | :camera
          | :tv
          | :game_console
          | :iot
          | :network_equipment
          | :server
          | :virtual_machine
          | :container
          | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          os_family: String.t() | nil,
          os_version: String.t() | nil,
          device_type: device_type(),
          vendor: String.t() | nil,
          confidence: non_neg_integer(),
          source: :local | :fingerbank | :user_override
        }

  defstruct [
    :id,
    :name,
    :os_family,
    :os_version,
    :vendor,
    device_type: :unknown,
    confidence: 0,
    source: :local
  ]

  @valid_device_types ~w(computer phone tablet printer voip_phone camera tv game_console iot network_equipment server virtual_machine container unknown)a
  @valid_device_type_map Map.new(@valid_device_types, fn atom -> {to_string(atom), atom} end)

  @doc """
  Parses a device type string to atom, defaulting to :unknown.
  """
  @spec parse_device_type(String.t() | atom()) :: device_type()
  def parse_device_type(type) when type in @valid_device_types, do: type

  def parse_device_type(type) when is_binary(type) do
    Map.get(@valid_device_type_map, type, :unknown)
  end

  def parse_device_type(_), do: :unknown
end
