defmodule YellowDog.Dns.Query.Referral do
  @moduledoc """
  Tracks DNS referral chain during recursive resolution.

  This module maintains state as we follow referrals from root servers
  down to authoritative servers. It helps prevent infinite loops and
  tracks the path taken during resolution.

  ## Referral Chain Example

      root servers (.)
        → .com servers
          → example.com servers
            → final answer

  The referral state tracks:
  - Current depth in the referral chain
  - Nameservers queried at each level
  - Glue records collected along the way
  - Detection of referral loops
  """

  @type t :: %__MODULE__{
          query_name: String.t(),
          query_type: atom(),
          path: [path_entry()],
          depth: non_neg_integer(),
          glue: %{String.t() => [:inet.ip_address()]},
          visited_ns: MapSet.t()
        }

  @type path_entry :: %{
          level: non_neg_integer(),
          zone: String.t(),
          nameservers: [String.t()],
          queried_ip: :inet.ip_address() | nil
        }

  defstruct [
    :query_name,
    :query_type,
    path: [],
    depth: 0,
    glue: %{},
    visited_ns: MapSet.new()
  ]

  @doc """
  Creates a new referral tracking state.

  ## Parameters
  - `query_name` - The domain name being resolved
  - `query_type` - The record type being queried

  ## Examples

      iex> Referral.new("www.example.com.", :A)
      %Referral{query_name: "www.example.com.", query_type: :A, depth: 0, ...}
  """
  @spec new(String.t(), atom()) :: t()
  def new(query_name, query_type) do
    %__MODULE__{
      query_name: normalize_domain_name(query_name),
      query_type: query_type,
      path: [],
      depth: 0,
      glue: %{},
      visited_ns: MapSet.new()
    }
  end

  @doc """
  Adds a referral level to the tracking state.

  ## Parameters
  - `state` - Current referral state
  - `zone` - Zone name for this referral level (e.g., "com.", "example.com.")
  - `ns_records` - NS records from the referral
  - `glue_records` - Glue records (NS name -> IP addresses)
  - `queried_ip` - The IP address that was queried (optional)

  ## Returns
  - `{:ok, new_state}` - Successfully added referral
  - `{:error, reason}` - Failed to add (e.g., loop detected)
  """
  @spec add_referral(t(), String.t(), [any()], map(), :inet.ip_address() | nil) ::
          {:ok, t()} | {:error, atom()}
  def add_referral(state, zone, ns_records, glue_records, queried_ip \\ nil) do
    # Extract NS names from records
    ns_names = extract_ns_names(ns_records)

    # Check for loops
    if detect_loop?(state, ns_names) do
      :telemetry.execute(
        [:yellow_dog, :dns, :query, :error],
        %{count: 1},
        %{
          source: __MODULE__,
          reason: :loop_detected,
          path: format_path(state),
          ns_names: ns_names,
          severity: :warning
        }
      )

      {:error, :loop_detected}
    else
      # Create path entry
      entry = %{
        level: state.depth,
        zone: normalize_domain_name(zone),
        nameservers: ns_names,
        queried_ip: queried_ip
      }

      # Update state
      new_state = %{
        state
        | path: state.path ++ [entry],
          depth: state.depth + 1,
          glue: Map.merge(state.glue, glue_records),
          visited_ns: MapSet.union(state.visited_ns, MapSet.new(ns_names))
      }

      {:ok, new_state}
    end
  end

  @doc """
  Checks if maximum recursion depth has been exceeded.

  ## Parameters
  - `state` - Current referral state
  - `max_depth` - Maximum allowed depth

  ## Returns
  - `true` if depth is exceeded
  - `false` otherwise
  """
  @spec max_depth_exceeded?(t(), non_neg_integer()) :: boolean()
  def max_depth_exceeded?(state, max_depth) do
    state.depth >= max_depth
  end

  @doc """
  Gets glue records for a specific nameserver.

  ## Parameters
  - `state` - Current referral state
  - `ns_name` - Nameserver domain name

  ## Returns
  - `{:ok, [ip_addresses]}` - Found glue records
  - `{:error, :no_glue}` - No glue records available
  """
  @spec get_glue(t(), String.t()) :: {:ok, [:inet.ip_address()]} | {:error, :no_glue}
  def get_glue(state, ns_name) do
    normalized_name = normalize_domain_name(ns_name)

    case Map.get(state.glue, normalized_name) do
      nil -> {:error, :no_glue}
      addresses when is_list(addresses) -> {:ok, addresses}
    end
  end

  @doc """
  Formats the referral path for logging/debugging.

  ## Examples

      iex> format_path(state)
      "root (.) → com. → example.com."
  """
  @spec format_path(t()) :: String.t()
  def format_path(state) do
    if length(state.path) == 0 do
      "root (.)"
    else
      path_str =
        state.path
        |> Enum.map(fn entry -> entry.zone end)
        |> Enum.join(" → ")

      "root (.) → " <> path_str
    end
  end

  @doc """
  Gets statistics about the referral chain.

  ## Returns
  A map with:
  - `:depth` - Current depth
  - `:zones_visited` - Number of zones traversed
  - `:ns_count` - Total nameservers encountered
  - `:glue_count` - Number of glue records collected
  """
  @spec stats(t()) :: map()
  def stats(state) do
    %{
      depth: state.depth,
      zones_visited: length(state.path),
      ns_count: MapSet.size(state.visited_ns),
      glue_count: map_size(state.glue)
    }
  end

  # Private functions

  defp extract_ns_names(ns_records) do
    ns_records
    |> Enum.map(fn record ->
      # Extract the nameserver name from the NS record data
      case record.data do
        %{data: %{value: name}} -> normalize_domain_name(name)
        %{data: name} when is_binary(name) -> normalize_domain_name(name)
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp detect_loop?(state, new_ns_names) do
    # Check if any of the new nameservers have already been visited
    new_ns_set = MapSet.new(new_ns_names)
    not MapSet.disjoint?(state.visited_ns, new_ns_set)
  end

  defp normalize_domain_name(name) when is_binary(name) do
    name = String.downcase(name)

    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end
end
