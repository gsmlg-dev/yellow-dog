defmodule YellowDogDns.View.Resolver do
  alias YellowDog.View

  use GenServer

  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query})
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(%{view: view}) do
    {:ok, %{view: view}}
  end

  def handle_call({:resolve, query}, _from, state) do
    %{header: header, qdlist: qdlist} = query

    resp =
      case header do
        %DNS.Message.Header{qdcount: 1} when length(qdlist) == 1 ->
          %{name: name, type: type} = qdlist |> List.first()

          cached =
            YellowDogDns.View.child(state.view, "cache")
            |> YellowDogDns.View.Cache.get({name, type})

          if is_nil(cached) do
            resp = DNS.Message.new()
            resp = %{resp | header: %{resp.header | id: header.id, qr: 1}, qdlist: qdlist}

            case YellowDogDns.View.child(state.view, "zone_manager")
                 |> YellowDog.YellowDogDns.View.ZoneManager.lookup(name, type) do
              {:nxdomain, _} ->
                %{resp | header: %{resp.header | rcode: DNS.Message.RCode.new(3)}}

              {:ok, answers} ->
                %{
                  resp
                  | header: %{resp.header | rcode: DNS.Message.RCode.new(0)},
                    anlist: answers
                }

              _ ->
                %{resp | header: %{resp.header | rcode: DNS.Message.RCode.new(2)}}
            end
          else
            %{cached | header: %{cached.header | id: header.id, qr: 1}}
          end

        _ ->
          resp = DNS.Message.new()

          resp = %{
            resp
            | header: %{resp.header | id: header.id, qr: 1, rcode: DNS.Message.RCode.new(1)},
              qdlist: qdlist
          }
      end

    {:reply, resp, state}
  end
end
