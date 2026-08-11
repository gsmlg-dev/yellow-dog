defmodule YellowDog.ApplicationAgentFake do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    owner = Application.fetch_env!(:yellow_dog, :application_test_owner)
    result = Application.get_env(:yellow_dog, :application_test_agent_result, :ok)

    case result do
      :ok ->
        case GenServer.start_link(__MODULE__, opts) do
          {:ok, pid} = started ->
            send(owner, {:server_agent_started, pid, opts, Process.whereis(YellowDog.Supervisor)})
            started

          error ->
            error
        end

      {:error, reason} ->
        send(owner, {:server_agent_failed, opts, Process.whereis(YellowDog.Supervisor)})
        {:error, reason}
    end
  end

  @impl GenServer
  def init(opts), do: {:ok, opts}

  def refresh_identity(updates) do
    owner = Application.fetch_env!(:yellow_dog, :application_test_owner)

    case Application.get_env(:yellow_dog, :application_test_agent_result, :ok) do
      :ok ->
        send(owner, {:server_agent_identity_refreshed, updates})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
