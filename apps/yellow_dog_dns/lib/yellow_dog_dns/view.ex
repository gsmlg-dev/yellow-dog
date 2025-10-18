defmodule YellowDogDns.View do
  @moduledoc """
  Start a GenServer as YellowDog DNS Name Resolver.
  """

  use Supervisor

  defstruct [
    :name,
    :acls,
    :options
  ]

  def child(pid, id) do
    pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn {child_id, pid, _, _} ->
      if child_id == id do
        pid
      else
        false
      end
    end)
  end

  def match?(pid, ip) do
    child(pid, "acl")
    |> YellowDogDns.View.ACL.match?(ip)
  end

  def resolve(pid, query) do
    child(pid, "resolver")
    |> YellowDogDns.View.Resolver.resolve(query)
  end

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config)
  end

  def init(%{recursive: recursive}) do
    [
      Supervisor.child_spec({YellowDogDns.View.ACL, [:any]},
        id: "acl"
      ),
      Supervisor.child_spec({YellowDogDns.View.Cache, %{}},
        id: "cache"
      ),
      Supervisor.child_spec({YellowDogDns.View.ZoneManager, %{recursive: recursive}},
        id: "zone_manager"
      ),
      Supervisor.child_spec({YellowDogDns.View.Resolver, %{view: self()}},
        id: "resolver"
      )
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
