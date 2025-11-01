defmodule YellowDog.Dns.Query.Cache.Entry do
  @moduledoc """
  Represents a cached DNS query response.

  Each cache entry stores the query parameters (name, type, class),
  the response type (answer, nxdomain, nodata), the records returned,
  and TTL information for expiration management.

  ## Examples

      iex> entry = Entry.new("www.example.com.", :A, records, [], 300)
      iex> Entry.expired?(entry)
      false

      iex> Entry.remaining_ttl(entry)
      298
  """

  alias YellowDog.Dns.Zone

  defstruct [
    :query_name,
    :query_type,
    :query_class,
    :response_type,
    :records,
    :authority,
    :ttl,
    :inserted_at,
    :expires_at,
    hit_count: 0
  ]

  @type response_type :: :answer | :nxdomain | :nodata

  @type t :: %__MODULE__{
          query_name: String.t(),
          query_type: atom(),
          query_class: atom(),
          response_type: response_type(),
          records: [Zone.Record.t()],
          authority: [Zone.Record.t() | Zone.SOA.t()],
          ttl: non_neg_integer(),
          inserted_at: integer(),
          expires_at: integer(),
          hit_count: non_neg_integer()
        }

  @doc """
  Creates a new cache entry.

  ## Parameters
  - `query_name` - The query name (e.g., "www.example.com.")
  - `query_type` - The query type (e.g., :A, :AAAA, :MX)
  - `records` - List of answer records
  - `authority` - List of authority records
  - `ttl` - Time to live in seconds
  - `opts` - Optional parameters:
    - `:query_class` - Query class (default: :IN)
    - `:response_type` - Response type (default: :answer)
    - `:inserted_at` - Insertion timestamp (default: current time)

  ## Returns
  A new `Entry` struct

  ## Examples

      iex> records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      iex> Entry.new("www.example.com.", :A, records, [], 300)
      %Entry{query_name: "www.example.com.", query_type: :A, ...}
  """
  @spec new(String.t(), atom(), [Zone.Record.t()], [any()], non_neg_integer(), keyword()) ::
          t()
  def new(query_name, query_type, records, authority, ttl, opts \\ []) do
    query_class = Keyword.get(opts, :query_class, :IN)
    response_type = determine_response_type(records, Keyword.get(opts, :response_type))
    now = Keyword.get(opts, :inserted_at, System.monotonic_time(:second))

    %__MODULE__{
      query_name: normalize_name(query_name),
      query_type: query_type,
      query_class: query_class,
      response_type: response_type,
      records: records,
      authority: authority,
      ttl: ttl,
      inserted_at: now,
      expires_at: now + ttl,
      hit_count: 0
    }
  end

  @doc """
  Checks if the cache entry has expired.

  ## Parameters
  - `entry` - The cache entry to check

  ## Returns
  `true` if expired, `false` otherwise

  ## Examples

      iex> entry = Entry.new("example.com.", :A, [], [], 300)
      iex> Entry.expired?(entry)
      false
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    System.monotonic_time(:second) >= expires_at
  end

  @doc """
  Gets the remaining TTL for the cache entry.

  Returns 0 if the entry has expired.

  ## Parameters
  - `entry` - The cache entry

  ## Returns
  Remaining TTL in seconds (non-negative integer)

  ## Examples

      iex> entry = Entry.new("example.com.", :A, [], [], 300)
      iex> Entry.remaining_ttl(entry) > 0
      true
  """
  @spec remaining_ttl(t()) :: non_neg_integer()
  def remaining_ttl(%__MODULE__{expires_at: expires_at}) do
    remaining = expires_at - System.monotonic_time(:second)
    max(0, remaining)
  end

  @doc """
  Records a cache hit by incrementing the hit count.

  ## Parameters
  - `entry` - The cache entry

  ## Returns
  Updated entry with incremented hit count

  ## Examples

      iex> entry = Entry.new("example.com.", :A, [], [], 300)
      iex> updated = Entry.record_hit(entry)
      iex> updated.hit_count
      1
  """
  @spec record_hit(t()) :: t()
  def record_hit(%__MODULE__{hit_count: count} = entry) do
    %{entry | hit_count: count + 1}
  end

  @doc """
  Updates the TTL values in the cached records to reflect remaining time.

  This is important for DNS responses - the TTL in the response should
  be the remaining TTL, not the original cached TTL.

  ## Parameters
  - `entry` - The cache entry

  ## Returns
  Entry with updated record TTLs

  ## Examples

      iex> records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]
      iex> entry = Entry.new("www.example.com.", :A, records, [], 300)
      iex> updated = Entry.update_ttls(entry)
      iex> hd(updated.records).ttl <= 300
      true
  """
  @spec update_ttls(t()) :: t()
  def update_ttls(%__MODULE__{records: records, authority: authority} = entry) do
    remaining_ttl = remaining_ttl(entry)

    updated_records = Enum.map(records, &update_record_ttl(&1, remaining_ttl))
    updated_authority = Enum.map(authority, &update_record_ttl(&1, remaining_ttl))

    %{entry | records: updated_records, authority: updated_authority}
  end

  @doc """
  Creates a cache key from query parameters.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `query_class` - The query class (default: :IN)

  ## Returns
  A tuple that can be used as an ETS key

  ## Examples

      iex> Entry.cache_key("www.example.com.", :A)
      {"www.example.com.", :A, :IN}
  """
  @spec cache_key(String.t(), atom(), atom()) :: {String.t(), atom(), atom()}
  def cache_key(query_name, query_type, query_class \\ :IN) do
    {normalize_name(query_name), query_type, query_class}
  end

  # Private functions

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> ensure_trailing_dot()
  end

  defp ensure_trailing_dot(name) do
    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end

  defp determine_response_type([], nil), do: :nxdomain
  defp determine_response_type([], :nodata), do: :nodata
  defp determine_response_type([], :nxdomain), do: :nxdomain
  defp determine_response_type(_records, nil), do: :answer
  defp determine_response_type(_records, type), do: type

  defp update_record_ttl(%Zone.Record{} = record, ttl) do
    %{record | ttl: ttl}
  end

  defp update_record_ttl(%Zone.SOA{} = soa, _ttl) do
    # SOA records don't have a TTL field in their struct
    soa
  end

  defp update_record_ttl(other, _ttl) do
    # For any other type, return as-is
    other
  end
end
