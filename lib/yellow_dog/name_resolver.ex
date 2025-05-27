defmodule YellowDog.NameResolver do
  @moduledoc """
  Start a GenServer as YellowDog DNS Name Resolver.

  """
  use GenServer

  def resolve(query) do
    client_ip = query |> DNS.Message.get_option(:client_ip)
    view = YellowDog.ViewManager.find_view(client_ip)

    case view do
      {:ok, pid} ->
        YellowDog.View.resolve(pid, query)

      {:error, _reason} ->
        {:error, :no_view}
    end
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def init(_config) do
    {:ok, %{}}
  end
end
