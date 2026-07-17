defmodule YellowDog.ServerAgent.DispatcherTestAdapter do
  @moduledoc false

  def dispatch(envelope) do
    count = Process.get({__MODULE__, :count}, 0)
    Process.put({__MODULE__, :count}, count + 1)
    Process.get({__MODULE__, :callback}).(envelope)
  end

  def configure(callback) when is_function(callback, 1) do
    Process.put({__MODULE__, :count}, 0)
    Process.put({__MODULE__, :callback}, callback)
  end

  def count, do: Process.get({__MODULE__, :count}, 0)
end

defmodule YellowDog.ServerAgent.DispatcherNoDispatchAdapter do
  @moduledoc false
end

defmodule YellowDog.ServerAgent.DispatcherJournalStub do
  @moduledoc false

  use GenServer

  def start_link(owner, replies) do
    GenServer.start_link(__MODULE__, {owner, replies})
  end

  @impl GenServer
  def init({owner, replies}), do: {:ok, %{owner: owner, replies: replies}}

  @impl GenServer
  def handle_call(message, _from, state) do
    send(state.owner, {:journal_call, message})
    {:reply, Map.fetch!(state.replies, elem(message, 0)), state}
  end
end
