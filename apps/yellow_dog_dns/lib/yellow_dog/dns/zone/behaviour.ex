defmodule YellowDog.Dns.Zone.Behaviour do
  @moduledoc """
  Behaviour for DNS zone implementations.

  All zone types (Auth, Forward, Stub, Root, Cache) implement this behaviour
  to provide a consistent interface for query resolution.
  """

  alias YellowDog.Dns.TSI
  alias DNS.Message

  @doc """
  Returns the zone name.
  """
  @callback get_name(pid :: pid()) :: String.t()

  @doc """
  Resolves a DNS query within this zone.

  ## Parameters

  - `pid` - The zone process
  - `tsi` - The Telemetry Span Item with query context
  - `query` - The DNS query message

  ## Returns

  - `{:ok, response}` - Successfully resolved
  - `{:referral, ns_records}` - Referral to other nameservers
  - `{:error, rcode}` - Error with DNS response code
  """
  @callback resolve(pid :: pid(), tsi :: TSI.t(), query :: Message.t()) ::
              {:ok, Message.t()}
              | {:referral, [DNS.ResourceRecord.t()]}
              | {:error, atom()}

  @doc """
  Reloads the zone with new configuration.
  """
  @callback reload(pid :: pid(), config :: keyword()) :: :ok | {:error, term()}

  @doc """
  Returns zone statistics.
  """
  @callback stats(pid :: pid()) :: map()
end
