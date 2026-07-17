defmodule YellowDog.ApplicationServiceFake do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    owner = Application.fetch_env!(:yellow_dog, :application_test_owner)

    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} = started ->
        send(owner, {:application_service_started, pid, opts})
        started

      error ->
        error
    end
  end

  @impl GenServer
  def init(opts), do: {:ok, opts}
end
