defmodule YellowDog.Tasks do
  @moduledoc """
  Foundation entry point for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Config

  @doc """
  Loads the current task processing configuration.
  """
  @spec config() :: Config.t()
  def config, do: Config.load()
end
