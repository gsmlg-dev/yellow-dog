defmodule YellowDog.DhcpClient.Lease do
  @moduledoc """
  DHCP lease data structure.

  Holds all information obtained from a DHCP handshake including standard
  lease fields, Yellow Dog vendor-specific options (control URL, auth token),
  and the raw options map for forward compatibility.
  """

  @type t :: %__MODULE__{
          ip: :inet.ip4_address(),
          subnet_mask: :inet.ip4_address(),
          router: :inet.ip4_address() | nil,
          dns_servers: [:inet.ip4_address()],
          server_ip: :inet.ip4_address(),
          server_mac: binary() | nil,
          lease_time: pos_integer(),
          t1: pos_integer(),
          t2: pos_integer(),
          domain_name: String.t() | nil,
          ntp_servers: [:inet.ip4_address()],
          mtu: pos_integer() | nil,
          vendor_options: map(),
          control_url: String.t() | nil,
          control_url_fallback: String.t() | nil,
          auth_token: String.t() | nil,
          server_id: String.t() | nil,
          cluster_id: String.t() | nil,
          yellowdog_server: boolean(),
          yellowdog_vendor_class: boolean(),
          known_server: boolean(),
          obtained_at: DateTime.t(),
          xid: non_neg_integer(),
          raw_options: map()
        }

  defstruct [
    :ip,
    :subnet_mask,
    :router,
    :server_ip,
    :server_mac,
    :lease_time,
    :t1,
    :t2,
    :domain_name,
    :mtu,
    :obtained_at,
    :xid,
    :control_url,
    :control_url_fallback,
    :auth_token,
    :server_id,
    :cluster_id,
    dns_servers: [],
    ntp_servers: [],
    vendor_options: %{},
    yellowdog_server: false,
    yellowdog_vendor_class: false,
    known_server: false,
    raw_options: %{}
  ]

  @doc """
  Returns `true` if the lease has expired based on `obtained_at` and `lease_time`.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{obtained_at: %DateTime{} = obtained_at, lease_time: lease_time})
      when is_integer(lease_time) and lease_time > 0 do
    now = DateTime.utc_now()
    expires_at = DateTime.add(obtained_at, lease_time, :second)
    DateTime.compare(now, expires_at) != :lt
  end

  def expired?(%__MODULE__{}), do: true

  @doc """
  Returns `true` if the T1 renewal timer has elapsed.

  T1 defaults to 50% of lease time per RFC 2131.
  """
  @spec t1_elapsed?(t()) :: boolean()
  def t1_elapsed?(%__MODULE__{obtained_at: %DateTime{} = obtained_at, t1: t1})
      when is_integer(t1) and t1 > 0 do
    now = DateTime.utc_now()
    t1_at = DateTime.add(obtained_at, t1, :second)
    DateTime.compare(now, t1_at) != :lt
  end

  def t1_elapsed?(%__MODULE__{}), do: true

  @doc """
  Returns `true` if the T2 rebind timer has elapsed.

  T2 defaults to 87.5% of lease time per RFC 2131.
  """
  @spec t2_elapsed?(t()) :: boolean()
  def t2_elapsed?(%__MODULE__{obtained_at: %DateTime{} = obtained_at, t2: t2})
      when is_integer(t2) and t2 > 0 do
    now = DateTime.utc_now()
    t2_at = DateTime.add(obtained_at, t2, :second)
    DateTime.compare(now, t2_at) != :lt
  end

  def t2_elapsed?(%__MODULE__{}), do: true

  @doc """
  Returns `true` if the lease is usable: has a non-zero IP and has not expired.

  Combines the zero-IP check with `expired?/1` to provide a single validation
  predicate suitable for deciding whether a persisted lease can be reused.

  ## Examples

      iex> lease = %YellowDog.DhcpClient.Lease{ip: {192, 168, 1, 100}, obtained_at: ~U[2099-01-01 00:00:00Z], lease_time: 3600}
      iex> YellowDog.DhcpClient.Lease.valid?(lease)
      true

      iex> lease = %YellowDog.DhcpClient.Lease{ip: {0, 0, 0, 0}, obtained_at: ~U[2099-01-01 00:00:00Z], lease_time: 3600}
      iex> YellowDog.DhcpClient.Lease.valid?(lease)
      false
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{ip: {0, 0, 0, 0}}), do: false
  def valid?(%__MODULE__{} = lease), do: not expired?(lease)

  @doc """
  Returns the `DateTime` at which the lease expires.

  Returns `nil` if `obtained_at` or `lease_time` is missing/invalid.

  ## Examples

      iex> lease = %YellowDog.DhcpClient.Lease{obtained_at: ~U[2026-01-01 00:00:00Z], lease_time: 3600}
      iex> YellowDog.DhcpClient.Lease.expires_at(lease)
      ~U[2026-01-01 01:00:00Z]
  """
  @spec expires_at(t()) :: DateTime.t() | nil
  def expires_at(%__MODULE__{obtained_at: %DateTime{} = obtained_at, lease_time: lease_time})
      when is_integer(lease_time) and lease_time > 0 do
    DateTime.add(obtained_at, lease_time, :second)
  end

  def expires_at(%__MODULE__{}), do: nil

  @doc """
  Returns the number of seconds remaining until the lease expires.

  Returns `0` if the lease has already expired, `nil` if the lease data is incomplete.
  """
  @spec time_remaining(t()) :: non_neg_integer() | nil
  def time_remaining(%__MODULE__{} = lease) do
    case expires_at(lease) do
      nil -> nil
      expires -> max(DateTime.diff(expires, DateTime.utc_now(), :second), 0)
    end
  end

  @doc """
  Converts the subnet mask to a CIDR prefix length.

  ## Examples

      iex> lease = %YellowDog.DhcpClient.Lease{subnet_mask: {255, 255, 255, 0}}
      iex> YellowDog.DhcpClient.Lease.prefix_length(lease)
      24

      iex> lease = %YellowDog.DhcpClient.Lease{subnet_mask: {255, 255, 0, 0}}
      iex> YellowDog.DhcpClient.Lease.prefix_length(lease)
      16
  """
  @spec prefix_length(t()) :: 0..32
  def prefix_length(%__MODULE__{subnet_mask: {a, b, c, d}}) do
    <<mask::32>> = <<a, b, c, d>>
    count_leading_ones(mask, 0)
  end

  defp count_leading_ones(0, acc), do: acc

  defp count_leading_ones(mask, acc) when mask > 0 do
    if Bitwise.band(mask, 0x80000000) != 0 do
      count_leading_ones(Bitwise.bsl(Bitwise.band(mask, 0x7FFFFFFF), 1), acc + 1)
    else
      acc
    end
  end
end
