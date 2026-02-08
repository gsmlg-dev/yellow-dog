defmodule YellowDog.Dhcpv6.Lease do
  @moduledoc """
  DHCPv6 lease structure.

  Represents an active, offered, or declined lease binding
  a DUID+IAID to an IPv6 address with timestamps.
  """

  import YellowDog.ConfigHelpers

  alias YellowDog.Dhcpv6.Ipv6Util

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}
  @type duid :: binary()
  @type iaid :: non_neg_integer()
  @type lease_state :: :active | :offered | :declined | :released | :expired

  @type t :: %__MODULE__{
          ip: ipv6_address(),
          duid: duid(),
          iaid: iaid(),
          pool_name: String.t(),
          hostname: String.t() | nil,
          starts_at: DateTime.t(),
          preferred_until: DateTime.t(),
          valid_until: DateTime.t(),
          state: lease_state()
        }

  defstruct [
    :ip,
    :duid,
    :iaid,
    :pool_name,
    :hostname,
    :starts_at,
    :preferred_until,
    :valid_until,
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
    with {:ok, ip} <- parse_ipv6(get_value(config, :ip)),
         {:ok, duid} <- parse_duid(get_value(config, :duid)),
         {:ok, iaid} <- parse_iaid(get_value(config, :iaid)),
         {:ok, starts_at} <- parse_datetime(get_value(config, :starts_at)),
         {:ok, preferred_until} <- parse_datetime(get_value(config, :preferred_until)),
         {:ok, valid_until} <- parse_datetime(get_value(config, :valid_until)) do
      lease = %__MODULE__{
        ip: ip,
        duid: duid,
        iaid: iaid,
        pool_name: get_value(config, :pool_name, "default"),
        hostname: get_value(config, :hostname),
        starts_at: starts_at,
        preferred_until: preferred_until,
        valid_until: valid_until,
        state: parse_state(get_value(config, :state, :active))
      }

      {:ok, lease}
    end
  end

  @doc """
  Creates a new lease for allocation.

  ## Parameters
  - `ip` - IPv6 address to assign
  - `duid` - Client DUID
  - `iaid` - Identity Association ID
  - `pool_name` - Pool the lease belongs to
  - `lifetimes` - %{preferred: seconds, valid: seconds}
  - `opts` - Optional fields (hostname)
  """
  @spec create(ipv6_address(), duid(), iaid(), String.t(), map(), keyword()) :: t()
  def create(ip, duid, iaid, pool_name, lifetimes, opts \\ []) do
    now = DateTime.utc_now()
    preferred = Map.get(lifetimes, :preferred, 3600)
    valid = Map.get(lifetimes, :valid, 7200)

    %__MODULE__{
      ip: ip,
      duid: normalize_duid(duid),
      iaid: iaid,
      pool_name: pool_name,
      hostname: Keyword.get(opts, :hostname),
      starts_at: now,
      preferred_until: DateTime.add(now, preferred, :second),
      valid_until: DateTime.add(now, valid, :second),
      state: :active
    }
  end

  @doc """
  Converts a Lease struct to a TOML-serializable map.
  """
  @spec to_toml_map(t()) :: map()
  def to_toml_map(%__MODULE__{} = lease) do
    base = %{
      "ip" => Ipv6Util.format(lease.ip),
      "duid" => format_duid_string(lease.duid),
      "iaid" => lease.iaid,
      "pool_name" => lease.pool_name,
      "starts_at" => DateTime.to_iso8601(lease.starts_at),
      "preferred_until" => DateTime.to_iso8601(lease.preferred_until),
      "valid_until" => DateTime.to_iso8601(lease.valid_until),
      "state" => Atom.to_string(lease.state)
    }

    maybe_put(base, "hostname", lease.hostname)
  end

  @doc """
  Parses a lease from a TOML map.
  """
  @spec from_toml_map(map()) :: {:ok, t()} | {:error, term()}
  def from_toml_map(map) when is_map(map) do
    config = %{
      ip: Map.get(map, "ip"),
      duid: Map.get(map, "duid"),
      iaid: Map.get(map, "iaid"),
      pool_name: Map.get(map, "pool_name", "default"),
      hostname: Map.get(map, "hostname"),
      starts_at: Map.get(map, "starts_at"),
      preferred_until: Map.get(map, "preferred_until"),
      valid_until: Map.get(map, "valid_until"),
      state: Map.get(map, "state", "active")
    }

    new(config)
  end

  @doc """
  Checks if a lease has expired (valid_until has passed).
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{valid_until: valid_until}) do
    DateTime.after?(DateTime.utc_now(), valid_until)
  end

  @doc """
  Checks if a lease is in deprecated state (preferred_until has passed but still valid).
  """
  @spec deprecated?(t()) :: boolean()
  def deprecated?(%__MODULE__{preferred_until: pref, valid_until: valid}) do
    now = DateTime.utc_now()
    DateTime.after?(now, pref) and not DateTime.after?(now, valid)
  end

  @doc """
  Checks if a lease is active (not expired and in active state).
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: :active} = lease), do: not expired?(lease)
  def active?(_), do: false

  @doc """
  Renews a lease with new lifetimes.
  """
  @spec renew(t(), map()) :: t()
  def renew(%__MODULE__{} = lease, lifetimes) do
    now = DateTime.utc_now()
    preferred = Map.get(lifetimes, :preferred, 3600)
    valid = Map.get(lifetimes, :valid, 7200)

    %{
      lease
      | preferred_until: DateTime.add(now, preferred, :second),
        valid_until: DateTime.add(now, valid, :second),
        state: :active
    }
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
  def validate(%__MODULE__{ip: ip, duid: duid, iaid: iaid, starts_at: starts, valid_until: valid}) do
    with :ok <- validate_ipv6(ip),
         :ok <- validate_duid(duid),
         :ok <- validate_iaid(iaid),
         :ok <- validate_timestamps(starts, valid) do
      :ok
    end
  end

  @doc """
  Generates a unique key for this lease (DUID + IAID).
  """
  @spec lease_key(t()) :: {duid(), iaid()}
  def lease_key(%__MODULE__{duid: duid, iaid: iaid}), do: {duid, iaid}

  # Parsing helpers

  defp parse_ipv6(nil), do: {:error, "IPv6 address is required"}
  defp parse_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: {:ok, ip}

  defp parse_ipv6(ip) when is_binary(ip) do
    case :inet.parse_ipv6_address(String.to_charlist(ip)) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> {:error, "Invalid IPv6 address format"}
    end
  end

  defp parse_ipv6(_), do: {:error, "Invalid IPv6 address"}

  defp parse_duid(nil), do: {:error, "DUID is required"}

  defp parse_duid(duid) when is_binary(duid) and byte_size(duid) >= 2,
    do: {:ok, normalize_duid(duid)}

  defp parse_duid(_), do: {:error, "Invalid DUID"}

  defp parse_iaid(nil), do: {:error, "IAID is required"}
  defp parse_iaid(iaid) when is_integer(iaid) and iaid >= 0, do: {:ok, iaid}

  defp parse_iaid(iaid) when is_binary(iaid) do
    case Integer.parse(iaid) do
      {val, ""} when val >= 0 -> {:ok, val}
      _ -> {:error, "Invalid IAID"}
    end
  end

  defp parse_iaid(_), do: {:error, "Invalid IAID"}

  # Formatting helpers

  defp format_duid_string(duid) when is_binary(duid) do
    # If it's already hex-encoded (contains colons or all hex chars), return as-is
    if String.contains?(duid, ":") or duid =~ ~r/^[0-9a-fA-F]+$/ do
      duid
    else
      YellowDog.Dhcpv6.DuidFormat.format(duid, separator: "", case: :lower) || duid
    end
  end

  defp normalize_duid(duid) when is_binary(duid) do
    # Remove any separators and convert to uppercase hex string
    duid
    |> String.replace([":", "-", " "], "")
    |> String.upcase()
  end

  # Validation helpers

  defp validate_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: :ok
  defp validate_ipv6(_), do: {:error, "Invalid IPv6 address"}

  defp validate_duid(duid) when is_binary(duid) and byte_size(duid) >= 2, do: :ok
  defp validate_duid(_), do: {:error, "Invalid DUID"}

  defp validate_iaid(iaid) when is_integer(iaid) and iaid >= 0, do: :ok
  defp validate_iaid(_), do: {:error, "Invalid IAID"}

  defp validate_timestamps(%DateTime{} = start, %DateTime{} = valid) do
    if DateTime.after?(start, valid) do
      {:error, "Start time must be before or equal to valid_until time"}
    else
      :ok
    end
  end

  defp validate_timestamps(_, _), do: {:error, "Invalid timestamps"}
end
