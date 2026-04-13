defmodule YellowDog.DnsProvider.Provider do
  @moduledoc """
  Behaviour for DNS zone data providers.

  Each provider implements callbacks for listing zones, reading records,
  applying changesets, and checking SOA serials. State is threaded through
  all callbacks for auth tokens, cursors, and rate limiting.

  ## Read-only providers

  Providers that only support pulling (e.g., IANA root zone) should return
  `{:error, :read_only, state}` from `apply_changeset/3`. The SyncEngine
  skips the push phase for such providers.
  """

  @type zone_ref :: %{name: String.t(), id: String.t() | nil}

  @type record_entry :: %{
          owner: String.t(),
          type: String.t(),
          ttl: non_neg_integer(),
          rdata: term()
        }

  @type changeset :: %{
          additions: [record_entry()],
          deletions: [record_entry()]
        }

  @type state :: term()

  @doc "Initialize provider state from config credentials and options."
  @callback init(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc "List all zones available from this provider."
  @callback list_zones(state()) :: {:ok, [zone_ref()], state()} | {:error, term(), state()}

  @doc "Get all records for a zone."
  @callback get_records(zone_ref(), state()) ::
              {:ok, [record_entry()], state()} | {:error, term(), state()}

  @doc """
  Apply a changeset (additions + deletions) to a remote zone.

  Return `{:error, :read_only, state}` if the provider is read-only.
  """
  @callback apply_changeset(zone_ref(), changeset(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc "Get the SOA serial number for a zone (for conflict comparison)."
  @callback zone_serial(zone_ref(), state()) ::
              {:ok, non_neg_integer(), state()} | {:error, term(), state()}
end
