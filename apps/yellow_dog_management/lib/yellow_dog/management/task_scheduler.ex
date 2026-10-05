defmodule YellowDog.Management.TaskScheduler do
  use GenServer
  alias YellowDog.Management.Tasks

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Tasks.due()
    Process.send_after(self(), :tick, 60_000 - rem(System.system_time(:millisecond), 60_000))
    {:noreply, state}
  end
end
