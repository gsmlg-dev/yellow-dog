defmodule YellowDog.Netboot.Device.Persistence do
  @moduledoc """
  TOML-based persistence for device registry.

  Serializes device records to TOML for crash recovery.
  """

  alias YellowDog.Netboot.Device

  @doc "Save devices to a TOML file."
  @spec save(String.t(), [Device.t()]) :: :ok | {:error, term()}
  def save(path, devices) do
    content = serialize_devices(devices)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> File.write(path, content)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load devices from a TOML file."
  @spec load(String.t()) :: {:ok, [Device.t()]} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, data} -> {:ok, deserialize_devices(data)}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private ---

  defp serialize_devices(devices) do
    devices
    |> Enum.map(fn device ->
      mac_key = String.replace(device.mac, ":", "_")

      """
      [devices.#{mac_key}]
      mac = "#{device.mac}"
      state = "#{device.state}"
      install_attempts = #{device.install_attempts}
      tags = #{inspect(device.tags)}
      """ <>
        optional_field("uuid", device.uuid) <>
        optional_field("hostname", device.hostname) <>
        optional_field("arch", device.arch && to_string(device.arch)) <>
        optional_field("profile_id", device.profile_id) <>
        optional_field("last_error", device.last_error)
    end)
    |> Enum.join("\n")
  end

  defp optional_field(_key, nil), do: ""
  defp optional_field(key, value), do: "#{key} = \"#{value}\"\n"

  defp deserialize_devices(%{"devices" => devices}) when is_map(devices) do
    Enum.map(devices, fn {_key, attrs} ->
      mac = Map.get(attrs, "mac", "")

      %Device{
        mac: mac,
        uuid: Map.get(attrs, "uuid"),
        hostname: Map.get(attrs, "hostname"),
        arch: parse_atom(Map.get(attrs, "arch")),
        profile_id: Map.get(attrs, "profile_id"),
        state: parse_state(Map.get(attrs, "state", "discovered")),
        install_attempts: Map.get(attrs, "install_attempts", 0),
        last_error: Map.get(attrs, "last_error"),
        tags: Map.get(attrs, "tags", []),
        first_seen: DateTime.utc_now(),
        last_seen: DateTime.utc_now()
      }
    end)
  end

  defp deserialize_devices(_), do: []

  defp parse_state(state) when is_binary(state) do
    valid = Enum.map(Device.valid_states(), &to_string/1)

    if state in valid do
      String.to_existing_atom(state)
    else
      :discovered
    end
  end

  defp parse_state(_), do: :discovered

  defp parse_atom(nil), do: nil

  defp parse_atom(str) when is_binary(str) do
    valid = Enum.map(Device.valid_arches(), &to_string/1)

    if str in valid do
      String.to_existing_atom(str)
    else
      nil
    end
  end
end
