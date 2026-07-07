defmodule YellowDog.Management.ServerProfile do
  @moduledoc """
  Concrete service profile for a managed `yellow_dog_server` runtime.
  """

  @enforce_keys [:name, :description, :services]
  defstruct [:name, :description, :services]

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          services: %{atom() => boolean()}
        }
end
