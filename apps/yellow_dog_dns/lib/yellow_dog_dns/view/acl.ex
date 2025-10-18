defmodule YellowDogDns.View.ACL do
  @moduledoc """
  Start a GenServer as YellowDog DNS Name Resolver.

  """
  use GenServer

  def match?(pid, ip) do
    GenServer.call(pid, {:match?, ip})
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(list) do
    {:ok, list}
  end

  def handle_call({:match?, ip}, _from, state) do
    is_match =
      state
      |> Enum.find_value(fn acl ->
        case acl do
          :any ->
            IO.inspect({:acl, :any, :match, ip})
            true

          _net ->
            false
        end
      end)

    {:reply, is_match, state}
  end
end
