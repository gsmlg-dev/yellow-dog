defmodule YellowDog.Dhcpv4.Lease do
  @moduledoc """
  DHCPv4 lease structure.

  Represents an active, offered, or declined lease binding
  a MAC address to an IP address with timestamps.
  """

  alias YellowDog.Dhcpv4.Ipv4Util
  import YellowDog.ConfigHelpers

  @type ip_address :: {0..255, 0..255, 0..255, 0..255}
  @type mac_address :: binary()
  @type lease_state :: :active | :offered | :declined | :released | :expired

  @type t :: %__MODULE__{
          ip: ip_address(),
          mac: mac_address(),
          pool_name: String.t(),
          hostname: String.t() | nil,
          client_id: binary() | nil,
          starts_at: DateTime.t(),
          expires_at: DateTime.t(),
          state: lease_state()
        }

  defstruct [
    :ip,
    :mac,
    :pool_name,
    :hostname,
    :client_id,
    :starts_at,
    :expires_at,
    state: :active
  ]

  @doc """
  Creates a new Lease from a configuration map.

  ## Parameters
  - `config` - Map with lease data

  ## Returns
  - `{:ok, lease}` on success
  - `{:error, reason}` on validation failure
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(config) when is_map(config) do
    with {:ok, ip} <- Ipv4Util.parse(get_value(config, :ip)),
         {:ok, mac} <- parse_mac(get_value(config, :mac)),
         {:ok, starts_at} <- parse_datetime(get_value(config, :starts_at)),
         {:ok, expires_at} <- parse_datetime(get_value(config, :expires_at)) do
      lease = %__MODULE__{
        ip: ip,
        mac: mac,
        pool_name: get_value(config, :pool_name, "default"),
        hostname: get_value(config, :hostname),
        client_id: get_value(config, :client_id),
        starts_at: starts_at,
        expires_at: expires_at,
        state: parse_state(get_value(config, :state, :active))
      }

      {:ok, lease}
    end
  end

  @doc """
  Creates a new lease for allocation.

  ## Parameters
  - `ip` - IP address to assign
  - `mac` - Client MAC address
  - `pool_name` - Pool the lease belongs to
  - `lease_time` - Lease duration in seconds
  - `opts` - Optional fields (hostname, client_id)
  """
  @spec create(ip_address(), mac_address(), String.t(), pos_integer(), keyword()) :: t()
  def create(ip, mac, pool_name, lease_time, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      ip: ip,
      mac: normalize_mac(mac),
      pool_name: pool_name,
      hostname: Keyword.get(opts, :hostname),
      client_id: Keyword.get(opts, :client_id),
      starts_at: now,
      expires_at: DateTime.add(now, lease_time, :second),
      state: :active
    }
  end

  @doc """
  Converts a Lease struct to a TOML-serializable map.
  """
  @spec to_toml_map(t()) :: map()
  def to_toml_map(%__MODULE__{} = lease) do
    base = %{
      "ip" => Ipv4Util.format(lease.ip),
      "mac" => format_mac_string(lease.mac),
      "pool_name" => lease.pool_name,
      "starts_at" => DateTime.to_iso8601(lease.starts_at),
      "expires_at" => DateTime.to_iso8601(lease.expires_at),
      "state" => Atom.to_string(lease.state)
    }

    base
    |> maybe_put("hostname", lease.hostname)
    |> maybe_put("client_id", format_client_id(lease.client_id))
  end

  @doc """
  Parses a lease from a TOML map.
  """
  @spec from_toml_map(map()) :: {:ok, t()} | {:error, term()}
  def from_toml_map(map) when is_map(map) do
    config = %{
      ip: Map.get(map, "ip"),
      mac: Map.get(map, "mac"),
      pool_name: Map.get(map, "pool_name", "default"),
      hostname: Map.get(map, "hostname"),
      client_id: parse_client_id(Map.get(map, "client_id")),
      starts_at: Map.get(map, "starts_at"),
      expires_at: Map.get(map, "expires_at"),
      state: Map.get(map, "state", "active")
    }

    new(config)
  end

  @doc """
  Checks if a lease has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.after?(DateTime.utc_now(), expires_at)
  end

  @doc """
  Checks if a lease is active (not expired and in active state).
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: :active} = lease), do: not expired?(lease)
  def active?(_), do: false

  @doc """
  Renews a lease with a new expiration time.
  """
  @spec renew(t(), pos_integer()) :: t()
  def renew(%__MODULE__{} = lease, lease_time) do
    %{lease | expires_at: DateTime.add(DateTime.utc_now(), lease_time, :second), state: :active}
  end

  @doc """
  Marks a lease as released.
  """
  @spec release(t()) :: t()
  def release(%__MODULE__{} = lease), do: %{lease | state: :released}

  @doc """
  Marks a lease as declined.
  """
  @spec decline(t()) :: t()
  def decline(%__MODULE__{} = lease), do: %{lease | state: :declined}

  @doc """
  Validates a Lease struct.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{ip: ip, mac: mac, starts_at: starts, expires_at: expires}) do
    with :ok <- validate_ip(ip),
         :ok <- validate_mac(mac),
         :ok <- validate_timestamps(starts, expires) do
      :ok
    end
  end

  # Parsing helpers

  defp parse_mac(nil), do: {:error, "MAC address is required"}
  defp parse_mac(mac) when is_binary(mac) and byte_size(mac) == 6, do: {:ok, mac}

  defp parse_mac(mac) when is_binary(mac) do
    # Try parsing colon-separated format
    case parse_mac_string(mac) do
      {:ok, _} = result -> result
      _ -> {:ok, mac}
    end
  end

  defp parse_mac(_), do: {:error, "Invalid MAC address"}

  defp parse_mac_string(mac_str) when is_binary(mac_str) do
    case mac_str |> String.replace(["-", "."], ":") |> String.split(":") do
      [_, _, _, _, _, _] = parts ->
        hex = parts |> Enum.map_join(&String.pad_leading(&1, 2, "0")) |> String.upcase()

        case Base.decode16(hex) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Invalid MAC address format"}
        end

      _ ->
        {:error, "Invalid MAC address format"}
    end
  end

  defp parse_client_id(nil), do: nil

  defp parse_client_id(str) when is_binary(str) do
    # Try hex decode, otherwise use as-is
    case Base.decode16(str, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> str
    end
  end

  defp format_mac_string(mac) when is_binary(mac) do
    YellowDog.Dhcpv4.MacFormat.format(mac, case: :lower) || mac
  end

  defp format_mac_string(_), do: "00:00:00:00:00:00"

  defp format_client_id(nil), do: nil
  defp format_client_id(bytes) when is_binary(bytes), do: Base.encode16(bytes, case: :lower)

  defp normalize_mac(mac) when is_binary(mac) and byte_size(mac) == 6, do: mac

  defp normalize_mac(mac) when is_binary(mac) do
    case parse_mac_string(mac) do
      {:ok, bytes} -> bytes
      _ -> mac
    end
  end

  defp normalize_mac(mac), do: mac

  # Validation helpers

  defp validate_ip({a, b, c, d})
       when a >= 0 and a <= 255 and b >= 0 and b <= 255 and c >= 0 and c <= 255 and d >= 0 and
              d <= 255,
       do: :ok

  defp validate_ip(_), do: {:error, "Invalid IP address"}

  defp validate_mac(mac) when is_binary(mac) and byte_size(mac) >= 6, do: :ok
  defp validate_mac(_), do: {:error, "Invalid MAC address"}

  defp validate_timestamps(%DateTime{} = start, %DateTime{} = expires) do
    if DateTime.after?(start, expires) do
      {:error, "Start time must be before or equal to expiration time"}
    else
      :ok
    end
  end

  defp validate_timestamps(_, _), do: {:error, "Invalid timestamps"}
end
