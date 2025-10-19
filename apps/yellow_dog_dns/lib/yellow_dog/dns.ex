defmodule YellowDog.Dns do
  @moduledoc """
  DNS supervisor that manages DNS functionality including name resolution, zones, and views.
  """

  @doc """
  Starts the socket client supervisor.

  Delegates to `Phoenix.SocketClient.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Phoenix.SocketClient.Supervisor

  @doc """
  Returns a child specification for the socket client supervisor.

  Delegates to `Phoenix.SocketClient.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Phoenix.SocketClient.Supervisor

end
