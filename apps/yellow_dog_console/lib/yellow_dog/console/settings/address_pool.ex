defmodule YellowDog.Console.Settings.AddressPool do
  @moduledoc """
  Ecto embedded schema for DHCP address pools.

  Represents an IP address pool for DHCP services (DHCPv4 or DHCPv6).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias YellowDog.Console.Validators

  @primary_key false
  embedded_schema do
    field :id, :string  # UUID for client-side identification
    field :name, :string
    field :range_start, :string
    field :range_end, :string
    field :lease_time, :integer  # DHCPv4: seconds
    field :preferred_lifetime, :integer  # DHCPv6: seconds
    field :valid_lifetime, :integer  # DHCPv6: seconds
    field :gateway, :string  # DHCPv4 only
    field :dns_servers, {:array, :string}, default: []
    field :protocol, Ecto.Enum, values: [:ipv4, :ipv6]
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          range_start: String.t() | nil,
          range_end: String.t() | nil,
          lease_time: integer() | nil,
          preferred_lifetime: integer() | nil,
          valid_lifetime: integer() | nil,
          gateway: String.t() | nil,
          dns_servers: [String.t()],
          protocol: :ipv4 | :ipv6 | nil
        }

  @doc """
  Creates changeset for address pool with validation.

  ## Validation Rules
    - name, range_start, range_end, protocol are required
    - DHCPv4 pools require lease_time >= 60 seconds
    - DHCPv6 pools require preferred_lifetime and valid_lifetime >= 60 seconds
    - DHCPv6: preferred_lifetime <= valid_lifetime
    - IP addresses must match protocol
    - Range start must be less than range end
    - DNS servers must be valid IP addresses matching protocol
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [
      :id,
      :name,
      :range_start,
      :range_end,
      :lease_time,
      :preferred_lifetime,
      :valid_lifetime,
      :gateway,
      :dns_servers,
      :protocol
    ])
    |> validate_required([:name, :range_start, :range_end, :protocol])
    |> validate_protocol_specific()
    |> validate_range()
    |> validate_dns_servers()
  end

  # Private Functions

  defp validate_protocol_specific(changeset) do
    protocol = get_field(changeset, :protocol)

    case protocol do
      :ipv4 ->
        changeset
        |> validate_required([:lease_time])
        |> validate_number(:lease_time, greater_than: 60)
        |> validate_ipv4_addresses()

      :ipv6 ->
        changeset
        |> validate_required([:preferred_lifetime, :valid_lifetime])
        |> validate_number(:preferred_lifetime, greater_than: 60)
        |> validate_number(:valid_lifetime, greater_than: 60)
        |> validate_ipv6_addresses()
        |> validate_lifetime_relationship()

      _ ->
        add_error(changeset, :protocol, "must be ipv4 or ipv6")
    end
  end

  defp validate_range(changeset) do
    range_start = get_field(changeset, :range_start)
    range_end = get_field(changeset, :range_end)
    protocol = get_field(changeset, :protocol)

    if range_start && range_end && protocol do
      case Validators.validate_pool_range(range_start, range_end, protocol) do
        :ok -> changeset
        {:error, message} -> add_error(changeset, :range_start, message)
      end
    else
      changeset
    end
  end

  defp validate_ipv4_addresses(changeset) do
    changeset
    |> validate_ip_format(:range_start, :ipv4)
    |> validate_ip_format(:range_end, :ipv4)
    |> validate_ip_format(:gateway, :ipv4)
  end

  defp validate_ipv6_addresses(changeset) do
    changeset
    |> validate_ip_format(:range_start, :ipv6)
    |> validate_ip_format(:range_end, :ipv6)
  end

  defp validate_ip_format(changeset, field, protocol) do
    validate_change(changeset, field, fn _field, address ->
      if is_nil(address) do
        []
      else
        case Validators.validate_ip(address, protocol) do
          :ok -> []
          {:error, message} -> [{field, message}]
        end
      end
    end)
  end

  defp validate_dns_servers(changeset) do
    dns_servers = get_field(changeset, :dns_servers) || []
    protocol = get_field(changeset, :protocol)

    invalid_servers =
      dns_servers
      |> Enum.filter(fn server ->
        case Validators.validate_ip(server, protocol) do
          :ok -> false
          {:error, _} -> true
        end
      end)

    if Enum.empty?(invalid_servers) do
      changeset
    else
      add_error(
        changeset,
        :dns_servers,
        "contains invalid IP addresses: #{inspect(invalid_servers)}"
      )
    end
  end

  defp validate_lifetime_relationship(changeset) do
    preferred = get_field(changeset, :preferred_lifetime)
    valid = get_field(changeset, :valid_lifetime)

    if preferred && valid && preferred > valid do
      add_error(changeset, :preferred_lifetime, "must be less than or equal to valid lifetime")
    else
      changeset
    end
  end
end
