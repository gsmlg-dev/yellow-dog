defmodule YellowDog.ServerAgent.RuntimeAdapter do
  @moduledoc """
  Runtime-owned validation, installation, activation, and restoration boundary.
  """

  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback install_config(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback activate_config(String.t()) :: :ok | {:error, term()}
  @callback restore_config(String.t()) :: :ok | {:error, term()}
end
