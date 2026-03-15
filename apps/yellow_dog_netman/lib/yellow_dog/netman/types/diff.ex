defmodule YellowDog.Netman.Types.Diff do
  @moduledoc """
  Represents a single reconciliation diff action.
  """

  @type action ::
          :add_address
          | :remove_address
          | :add_route
          | :remove_route
          | :activate_connection
          | :deactivate_connection
          | :update_dns
          | :set_mtu
          | :set_link_up
          | :set_link_down
          | :update_profile

  @type t :: %__MODULE__{
          action: action(),
          interface: String.t() | nil,
          params: map()
        }

  @valid_actions [
    :add_address,
    :remove_address,
    :add_route,
    :remove_route,
    :activate_connection,
    :deactivate_connection,
    :update_dns,
    :set_mtu,
    :set_link_up,
    :set_link_down,
    :update_profile
  ]

  @enforce_keys [:action]
  defstruct [:action, :interface, params: %{}]

  @doc "Creates a new diff."
  @spec new(action(), String.t() | nil, map()) :: t()
  def new(action, interface \\ nil, params \\ %{})
      when action in @valid_actions do
    %__MODULE__{action: action, interface: interface, params: params}
  end
end
