defmodule YellowDog.Dns.View do
  @moduledoc """
  DNS Views for split-horizon DNS.

  Currently implements a default view that matches all clients.
  Full view implementation with ACLs is deferred to Phase 4.

  ## Future Implementation (Phase 4)

  The complete view system will support:
  - Multiple named views with ACL-based client matching
  - Per-view zone collections
  - Per-view recursion settings
  - Client IP matching against ACL rules
  - View priority and fallback handling
  """

  defstruct [:name, :match_clients, :zones, :recursion_enabled]

  @type t :: %__MODULE__{
          name: String.t(),
          match_clients: :all | list(),
          zones: list(),
          recursion_enabled: boolean()
        }

  @doc """
  Returns the default view that matches all clients.

  The default view has:
  - Name: "default"
  - Match clients: `:all` (matches any client IP)
  - Zones: `[]` (empty list, zones will be added later)
  - Recursion enabled: `true`

  ## Examples

      iex> view = YellowDog.Dns.View.default()
      iex> view.name
      "default"
      iex> view.match_clients
      :all
      iex> view.recursion_enabled
      true
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      name: "default",
      match_clients: :all,
      zones: [],
      recursion_enabled: true
    }
  end

  @doc """
  Match client IP to a view.

  Currently always returns the default view regardless of client IP.
  In Phase 4, this will implement ACL-based matching logic.

  ## Parameters

  - `client_ip` - Client IP address (ignored in current implementation)

  ## Returns

  - `{:ok, view}` - Always returns the default view

  ## Examples

      iex> {:ok, view} = YellowDog.Dns.View.match_view({192, 168, 1, 100})
      iex> view.name
      "default"
      iex> view.match_clients
      :all
  """
  @spec match_view(tuple() | binary()) :: {:ok, t()}
  def match_view(_client_ip) do
    {:ok, default()}
  end
end
