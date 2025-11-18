defmodule YellowDog.Console.Settings.ServiceConfiguration do
  @moduledoc """
  Ecto embedded schema for service configuration.

  Represents configuration for a single service (DNS, mDNS, DHCPv4, DHCPv6).
  Uses embedded schemas for validation without requiring a database.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias YellowDog.Console.Settings.AddressPool

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: true)
    field(:listen, :string)
    field(:port, :integer)
    field(:service_type, Ecto.Enum, values: [:dns, :mdns, :dhcpv4, :dhcpv6])

    # Service-specific fields
    # mDNS only
    field(:mode, Ecto.Enum, values: [:responder, :hybrid], virtual: true)
    # DHCP services
    field(:domain, :string, virtual: true)
    # DHCP services
    field(:dns_servers, {:array, :string}, virtual: true, default: [])
    # DHCPv4 only
    field(:gateway, :string, virtual: true)

    # Pool references (DHCP services only)
    embeds_many(:pools, AddressPool)
  end

  @type t :: %__MODULE__{
          enabled: boolean(),
          listen: String.t() | nil,
          port: integer() | nil,
          service_type: :dns | :mdns | :dhcpv4 | :dhcpv6 | nil,
          mode: :responder | :hybrid | nil,
          domain: String.t() | nil,
          dns_servers: [String.t()],
          gateway: String.t() | nil,
          pools: [AddressPool.t()]
        }

  @doc """
  Creates changeset for service configuration with validation.

  ## Validation Rules
    - enabled, listen, port, service_type are required
    - port must be 1-65535
    - listen must be valid IPv4 or IPv6 address
    - mDNS services require mode field
    - DHCP services must have at least one pool
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :enabled,
      :listen,
      :port,
      :service_type,
      :mode,
      :domain,
      :dns_servers,
      :gateway
    ])
    |> cast_embed(:pools, with: &AddressPool.changeset/2)
    |> validate_required([:enabled, :listen, :port, :service_type])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)
    |> validate_ip_address(:listen)
    |> validate_service_specific()
  end

  # Private Functions

  defp validate_service_specific(changeset) do
    service_type = get_field(changeset, :service_type)

    case service_type do
      :mdns ->
        changeset
        |> validate_required([:mode])
        |> validate_inclusion(:mode, [:responder, :hybrid])

      service when service in [:dhcpv4, :dhcpv6] ->
        changeset
        |> validate_pools()

      _ ->
        changeset
    end
  end

  defp validate_pools(changeset) do
    pools = get_field(changeset, :pools) || []

    if Enum.empty?(pools) do
      add_error(changeset, :pools, "must have at least one address pool")
    else
      changeset
    end
  end

  defp validate_ip_address(changeset, field) do
    validate_change(changeset, field, fn _field, address ->
      case :inet.parse_address(to_charlist(address)) do
        {:ok, _} -> []
        {:error, _} -> [{field, "must be a valid IP address"}]
      end
    end)
  end
end
