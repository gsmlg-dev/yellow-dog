defmodule YellowDog.View.Resolver do
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
            View.child(state.view, "cache")
            |> View.Cache.get({name, type})

          if is_nil(cached) do
            resp =
              DNS.Message.new()
              |> DNS.Message.update_header_attr(:id, header.id)
              |> DNS.Message.update_header_attr(:qr, 1)
              |> DNS.Message.add_question(qdlist |> List.first())

            resp = %{resp | qdlist: qdlist}

            case View.child(state.view, "zone_manager")
                 |> YellowDog.View.ZoneManager.lookup(name, type) do
              {:nxdomain, _} ->
                resp
                |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.nx_domain())

              {:ok, answers} ->
                resp
                |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.no_error())
                |> Map.put(:anlist, answers)

              _ ->
                DNS.Message.update_header_attr(resp, :rcode, DNS.Message.RCode.serv_fail())
            end
          else
            %{cached | header: %{cached.header | id: header.id, qr: 1}}
          end

        _ ->
          resp =
            DNS.Message.new()
            |> DNS.Message.update_header_attr(:id, header.id)
            |> DNS.Message.update_header_attr(:qr, 1)
            |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(1))
            |> DNS.Message.add_question(qdlist |> List.first())

          %{resp | qdlist: qdlist}
      end

    {:reply, resp, state}
  end
end
