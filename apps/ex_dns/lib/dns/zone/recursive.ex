defmodule DNS.Zone.Recursive do
  @moduledoc """
  DNS Zone Recursive

  """

  def root_ns_addrs(type \\ :a) when type in [:a, :aaaa] do
    for rr <- DNS.Zone.RootHint.root_hints(), rr[:type] == type do
      case :inet.parse_ipv4_address(~c"#{rr[:data]}") do
        {:ok, addr} -> addr
        {:error, _} -> rr[:data]
      end
    end
  end

  def resolve(name, type) do
    msg = create_query(name, type)
    data = DNS.Parameter.to_iodata(msg)
    servers = root_ns_addrs(:a) |> Enum.map(&{&1, 53})

    case recursive_query(servers, data) do
      {:ok, [%{type: %DNS.ResourceRecordType{value: <<0, 5>>}, data: data} = record]} ->
        case resolve(data.data.value, type) do
          {:ok, list} ->
            {:ok, [record | list]}

          _ ->
            {:ok, [record]}
        end

      {:ok, list} ->
        {:ok, list}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recursive_query(servers, data) do
    case query_first(servers, data) do
      {:awnsers, awnsers, _resp_message} ->
        {:ok, awnsers}

      {:nslist, name_servers, _resp_message} ->
        nslist = name_servers |> Enum.map(&{&1, 53})

        if nslist != [] do
          recursive_query(nslist, data)
        else
          {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_query(name, type) do
    message = DNS.Message.new()

    %{
      message
      | header: %{
          message.header
          | qdcount: 1
        },
        qdlist: [
          DNS.Message.Question.new(name, type, :in)
        ]
    }
  end

  defp query_first(list, message) do
    case Task.async_stream(
           list,
           fn {ip, port} ->
             {:ok, socket} = :gen_udp.open(0, active: false, mode: :binary)

             :ok = :gen_udp.send(socket, ip, port, message)

             case :gen_udp.recv(socket, 0, to_timeout(second: 3)) do
               {:ok, recv_data} ->
                 {_ip, _port, data} = recv_data
                 :gen_udp.close(socket)
                 resp_message = DNS.Message.from_iodata(data)
                 header = resp_message.header
                 rcode = header.rcode

                 if rcode == DNS.Message.RCode.no_error() do
                   if header.ancount > 0 do
                     awnsers = resp_message.anlist
                     {:ok, {:awnsers, awnsers, resp_message}}
                   else
                     nslist = resp_message.nslist
                     arlist = resp_message.arlist

                     if nslist != [] do
                       name_servers =
                         nslist
                         |> Enum.flat_map(fn rr ->
                           ns_server = rr.data.data
                           type = DNS.ResourceRecordType.new(:a)

                           for d <- arlist,
                               d.name.value == ns_server.value and d.type == type,
                               do: d.data.data
                         end)

                       {:ok, {:nslist, name_servers, resp_message}}
                     else
                       {:error, :no_nslist}
                     end
                   end
                 else
                   {:error, {rcode, data}}
                 end

               {:error, reason} ->
                 :gen_udp.close(socket)
                 {:error, reason}
             end
           end,
           on_timeout: :kill_task,
           timeout: to_timeout(second: 10),
           ordered: false,
           max_concurrency: length(list)
         )
         |> Stream.filter(fn
           {:ok, {:ok, _}} ->
             true

           _ ->
             false
         end)
         |> Enum.take(1) do
      [ok: {:ok, result}] -> result
      _ -> nil
    end
  end
end
