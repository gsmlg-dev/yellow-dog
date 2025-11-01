defmodule YellowDog.Dns.View do
  @moduledoc """
  DNS Views for split-horizon DNS with ACL-based client matching.

  Views allow a DNS server to return different answers to different clients
  based on their IP addresses. This is commonly used for:
  - Split-horizon DNS (different answers for internal vs external clients)
  - Security policies (blocking queries from certain networks)
  - Geographic routing (different answers based on client location)
  - Testing and staging environments

  ## View Matching

  Views are evaluated in order until a match is found:
  1. Client IP is checked against each view's ACL
  2. First matching view is used for query resolution
  3. If no view matches, the default view is used

  ## Examples

      # Create a view for internal network and check matching
      iex> internal = View.new("internal", "localnets", ["corp.example.com"], true)
      iex> internal.name
      "internal"

      # Match client to the view
      iex> view = View.new("test", "localnets")
      iex> View.matches?(view, {192, 168, 1, 100})
      true
  """

  alias YellowDog.Dns.View.ACL

  defstruct [:name, :match_clients, :zones, :recursion_enabled]

  @type match_clients :: :all | String.t() | ACL.t()
  @type t :: %__MODULE__{
          name: String.t(),
          match_clients: match_clients(),
          zones: [String.t()],
          recursion_enabled: boolean()
        }

  @doc """
  Creates a new view with the given parameters.

  ## Parameters

  - `name` - View identifier
  - `match_clients` - ACL name, ACL struct, or `:all` to match all clients
  - `zones` - List of zone names available in this view
  - `recursion_enabled` - Whether recursion is allowed for this view

  ## Examples

      iex> view = View.new("internal", "localnets", ["corp.example.com"], true)
      iex> view.name
      "internal"

      iex> acl = ACL.new("custom", [{:allow, {10, 0, 0, 0}, 8}])
      iex> view = View.new("dmz", acl, ["dmz.example.com"], false)
      iex> view.match_clients.name
      "custom"
  """
  @spec new(String.t(), match_clients(), [String.t()], boolean()) :: t()
  def new(name, match_clients, zones \\ [], recursion_enabled \\ true) do
    %__MODULE__{
      name: name,
      match_clients: match_clients,
      zones: zones,
      recursion_enabled: recursion_enabled
    }
  end

  @doc """
  Returns the default view that matches all clients.

  The default view has:
  - Name: "default"
  - Match clients: `:all` (matches any client IP)
  - Zones: `[]` (empty list, zones will be added later)
  - Recursion enabled: `true`

  ## Examples

      iex> view = View.default()
      iex> view.name
      "default"
      iex> view.match_clients
      :all
      iex> view.recursion_enabled
      true
  """
  @spec default() :: t()
  def default do
    new("default", :all, [], true)
  end

  @doc """
  Checks if a client IP matches this view's ACL.

  ## Parameters

  - `view` - The view to check
  - `client_ip` - Client IP address tuple

  ## Returns

  - `true` if client matches the view's ACL
  - `false` otherwise

  ## Examples

      iex> internal = View.new("internal", "localnets", [], true)
      iex> View.matches?(internal, {192, 168, 1, 100})
      true

      iex> external_view = View.new("test", "localnets")
      iex> View.matches?(external_view, {8, 8, 8, 8})
      false
  """
  @spec matches?(t(), :inet.ip_address()) :: boolean()
  def matches?(%__MODULE__{match_clients: :all}, _client_ip), do: true

  def matches?(%__MODULE__{match_clients: acl_name}, client_ip) when is_binary(acl_name) do
    # ACL name (e.g., "localnets", "any", etc.)
    ACL.matches?(acl_name, client_ip)
  end

  def matches?(%__MODULE__{match_clients: %ACL{} = acl}, client_ip) do
    # ACL struct
    ACL.matches?(acl, client_ip)
  end

  def matches?(_view, _client_ip), do: false

  @doc """
  Finds the first view that matches the client IP from a list of views.

  Views are evaluated in order. The first matching view is returned.
  If no views match, returns `{:error, :no_match}`.

  ## Parameters

  - `client_ip` - Client IP address tuple
  - `views` - List of views to check (in priority order)

  ## Returns

  - `{:ok, view}` if a matching view is found
  - `{:error, :no_match}` if no views match

  ## Examples

      iex> v1 = View.new("internal", "localnets", [], true)
      iex> v2 = View.new("external", "any", [], false)
      iex> {:ok, matched} = View.match_client({192, 168, 1, 100}, [v1, v2])
      iex> matched.name
      "internal"
  """
  @spec match_client(:inet.ip_address(), [t()]) :: {:ok, t()} | {:error, :no_match}
  def match_client(client_ip, views) when is_list(views) do
    case Enum.find(views, &matches?(&1, client_ip)) do
      nil -> {:error, :no_match}
      view -> {:ok, view}
    end
  end

  @doc """
  Match client IP to a view (legacy function for backward compatibility).

  This function always returns the default view for backward compatibility.
  New code should use `match_client/2` with a list of configured views.

  ## Parameters

  - `client_ip` - Client IP address (ignored in current implementation)

  ## Returns

  - `{:ok, view}` - Always returns the default view

  ## Examples

      iex> {:ok, view} = View.match_view({192, 168, 1, 100})
      iex> view.name
      "default"
      iex> view.match_clients
      :all
  """
  @spec match_view(:inet.ip_address()) :: {:ok, t()}
  def match_view(_client_ip) do
    {:ok, default()}
  end

  @doc """
  Adds a zone to a view's zone list.

  ## Parameters

  - `view` - The view to update
  - `zone_name` - Name of the zone to add

  ## Returns

  - Updated view with the zone added

  ## Examples

      iex> view = View.new("internal", "localnets", [], true)
      iex> view = View.add_zone(view, "corp.example.com")
      iex> view.zones
      ["corp.example.com"]
  """
  @spec add_zone(t(), String.t()) :: t()
  def add_zone(%__MODULE__{zones: zones} = view, zone_name) do
    %{view | zones: [zone_name | zones] |> Enum.uniq()}
  end

  @doc """
  Removes a zone from a view's zone list.

  ## Parameters

  - `view` - The view to update
  - `zone_name` - Name of the zone to remove

  ## Returns

  - Updated view with the zone removed

  ## Examples

      iex> view = View.new("internal", "localnets", ["corp.example.com"], true)
      iex> view = View.remove_zone(view, "corp.example.com")
      iex> view.zones
      []
  """
  @spec remove_zone(t(), String.t()) :: t()
  def remove_zone(%__MODULE__{zones: zones} = view, zone_name) do
    %{view | zones: Enum.reject(zones, &(&1 == zone_name))}
  end

  @doc """
  Checks if a zone is available in this view.

  ## Parameters

  - `view` - The view to check
  - `zone_name` - Name of the zone to check

  ## Returns

  - `true` if the zone is in the view's zone list
  - `false` otherwise

  ## Examples

      iex> v = View.new("internal", "localnets", ["corp.example.com"], true)
      iex> View.has_zone?(v, "corp.example.com")
      true

      iex> v2 = View.new("test", "any", ["example.com"])
      iex> View.has_zone?(v2, "other.example.com")
      false
  """
  @spec has_zone?(t(), String.t()) :: boolean()
  def has_zone?(%__MODULE__{zones: zones}, zone_name) do
    zone_name in zones
  end
end
