defmodule YellowDog.Management.NetmanProfile do
  @moduledoc """
  Concrete feature profile for a managed `yellow_dog_netman` runtime.
  """

  @enforce_keys [:name, :description, :features, :apply_mode]
  defstruct [:name, :description, :features, :apply_mode]

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          features: %{atom() => boolean()},
          apply_mode: atom()
        }
end
