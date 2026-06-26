defmodule YellowDog.Tasks.RegionData.Provider do
  @moduledoc """
  Source behavior for region data synchronization.
  """

  @callback list_countries() :: {:ok, [map()]} | {:error, term()}
end
