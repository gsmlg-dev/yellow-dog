defmodule YellowDog.Fingerprint do
  @moduledoc """
  Passive device identification for YellowDog DHCP servers.

  Identifies device type, OS, and vendor by analyzing DHCP option patterns
  without active probing. DHCP servers emit telemetry events; this app
  subscribes and builds a real-time device inventory.
  """

  alias YellowDog.Fingerprint.{Database, DeviceRegistry, Matcher, OUI}

  @doc """
  Looks up the device profile for a fingerprint hash.
  """
  @spec lookup(binary()) :: {:ok, YellowDog.Fingerprint.Types.DeviceProfile.t()} | :unknown
  def lookup(fingerprint_id) do
    Matcher.match_by_hash(fingerprint_id)
  end

  @doc """
  Returns the device entry for a given MAC address.
  """
  @spec get_device(String.t()) :: {:ok, YellowDog.Fingerprint.Types.Device.t()} | :not_found
  def get_device(mac) do
    DeviceRegistry.get(mac)
  end

  @doc """
  Lists all observed devices.
  """
  @spec list_devices() :: [YellowDog.Fingerprint.Types.Device.t()]
  def list_devices do
    DeviceRegistry.list()
  end

  @doc """
  Returns device registry statistics.
  """
  @spec stats() :: map()
  def stats do
    DeviceRegistry.stats()
  end

  @doc """
  Looks up OUI vendor for a MAC address.
  """
  @spec oui_vendor(String.t()) :: {:ok, String.t()} | :not_found
  def oui_vendor(mac) do
    OUI.lookup(mac)
  end

  @doc """
  Lists all known fingerprints from the database.
  """
  @spec list_fingerprints() :: [YellowDog.Fingerprint.Types.Fingerprint.t()]
  def list_fingerprints do
    Database.list_fingerprints()
  end

  @doc """
  Lists unknown (unmatched) fingerprints, ranked by hit count.
  """
  @spec list_unknown_fingerprints() :: [YellowDog.Fingerprint.Types.Fingerprint.t()]
  def list_unknown_fingerprints do
    Database.list_unknown_fingerprints()
  end

  @doc """
  Creates a user override mapping a fingerprint hash to a profile.
  """
  @spec create_override(binary(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def create_override(fingerprint_hash, profile_id, note \\ nil) do
    Database.add_override(fingerprint_hash, profile_id, note)
  end

  @doc """
  Lists all device profiles (bundled + custom).
  """
  @spec list_profiles() :: [YellowDog.Fingerprint.Types.DeviceProfile.t()]
  def list_profiles do
    Database.list_profiles()
  end

  @doc """
  Returns database statistics.
  """
  @spec database_stats() :: map()
  def database_stats do
    Database.stats()
  end
end
