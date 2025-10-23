defmodule NameResolver do
  @root_hints """
  ;       This file holds the information on root name servers needed to
  ;       initialize cache of Internet domain name servers
  ;       (e.g. reference this file in the "cache  .  <file>"
  ;       configuration file of BIND domain name servers).
  ;
  ;       This file is made available by InterNIC
  ;       under anonymous FTP as
  ;           file                /domain/named.cache
  ;           on server           FTP.INTERNIC.NET
  ;       -OR-                    RS.INTERNIC.NET
  ;
  ;       last update:     March 26, 2025
  ;       related version of root zone:     2025032601
  ;
  ; FORMERLY NS.INTERNIC.NET
  ;
  .                        3600000      NS    A.ROOT-SERVERS.NET.
  A.ROOT-SERVERS.NET.      3600000      A     198.41.0.4
  A.ROOT-SERVERS.NET.      3600000      AAAA  2001:503:ba3e::2:30
  ;
  ; FORMERLY NS1.ISI.EDU
  ;
  .                        3600000      NS    B.ROOT-SERVERS.NET.
  B.ROOT-SERVERS.NET.      3600000      A     170.247.170.2
  B.ROOT-SERVERS.NET.      3600000      AAAA  2801:1b8:10::b
  ;
  ; FORMERLY C.PSI.NET
  ;
  .                        3600000      NS    C.ROOT-SERVERS.NET.
  C.ROOT-SERVERS.NET.      3600000      A     192.33.4.12
  C.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2::c
  ;
  ; FORMERLY TERP.UMD.EDU
  ;
  .                        3600000      NS    D.ROOT-SERVERS.NET.
  D.ROOT-SERVERS.NET.      3600000      A     199.7.91.13
  D.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2d::d
  ;
  ; FORMERLY NS.NASA.GOV
  ;
  .                        3600000      NS    E.ROOT-SERVERS.NET.
  E.ROOT-SERVERS.NET.      3600000      A     192.203.230.10
  E.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:a8::e
  ;
  ; FORMERLY NS.ISC.ORG
  ;
  .                        3600000      NS    F.ROOT-SERVERS.NET.
  F.ROOT-SERVERS.NET.      3600000      A     192.5.5.241
  F.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:2f::f
  ;
  ; FORMERLY NS.NIC.DDN.MIL
  ;
  .                        3600000      NS    G.ROOT-SERVERS.NET.
  G.ROOT-SERVERS.NET.      3600000      A     192.112.36.4
  G.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:12::d0d
  ;
  ; FORMERLY AOS.ARL.ARMY.MIL
  ;
  .                        3600000      NS    H.ROOT-SERVERS.NET.
  H.ROOT-SERVERS.NET.      3600000      A     198.97.190.53
  H.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:1::53
  ;
  ; FORMERLY NIC.NORDU.NET
  ;
  .                        3600000      NS    I.ROOT-SERVERS.NET.
  I.ROOT-SERVERS.NET.      3600000      A     192.36.148.17
  I.ROOT-SERVERS.NET.      3600000      AAAA  2001:7fe::53
  ;
  ; OPERATED BY VERISIGN, INC.
  ;
  .                        3600000      NS    J.ROOT-SERVERS.NET.
  J.ROOT-SERVERS.NET.      3600000      A     192.58.128.30
  J.ROOT-SERVERS.NET.      3600000      AAAA  2001:503:c27::2:30
  ;
  ; OPERATED BY RIPE NCC
  ;
  .                        3600000      NS    K.ROOT-SERVERS.NET.
  K.ROOT-SERVERS.NET.      3600000      A     193.0.14.129
  K.ROOT-SERVERS.NET.      3600000      AAAA  2001:7fd::1
  ;
  ; OPERATED BY ICANN
  ;
  .                        3600000      NS    L.ROOT-SERVERS.NET.
  L.ROOT-SERVERS.NET.      3600000      A     199.7.83.42
  L.ROOT-SERVERS.NET.      3600000      AAAA  2001:500:9f::42
  ;
  ; OPERATED BY WIDE
  ;
  .                        3600000      NS    M.ROOT-SERVERS.NET.
  M.ROOT-SERVERS.NET.      3600000      A     202.12.27.33
  M.ROOT-SERVERS.NET.      3600000      AAAA  2001:dc3::35
  ; End of file
  """

  def root_hints() do
    @root_hints
    |> String.split("\n")
    |> Enum.filter(&(!String.starts_with?(&1, ";")))
    |> Enum.filter(&(String.length(&1) > 0))
    |> Enum.map(fn line ->
      type_map = %{"A" => :a, "AAAA" => :aaaa, "NS" => :ns}
      [name, ttl, type, data] = line |> String.split(~r[\s+])
      rtype = Map.get(type_map, type)

      rdata =
        case rtype do
          :a ->
            {:ok, addr} = :inet.parse_ipv4_address(String.to_charlist(data))
            addr

          :aaaa ->
            {:ok, addr} = :inet.parse_ipv6_address(String.to_charlist(data))
            addr

          :ns ->
            data
        end

      [name: name, ttl: String.to_integer(ttl), type: rtype, data: data, rdata: rdata]
    end)
  end

  def root_ns_addrs(type \\ :a) when type in [:a, :aaaa] do
    root_hints()
    |> Enum.filter(fn rr ->
      rr[:type] == type
    end)
    |> Enum.map(fn rr ->
      data = rr[:data]

      case :inet.parse_ipv4_address(~c"#{data}") do
        {:ok, addr} -> addr
        {:error, _} -> data
      end
    end)
  end

  def resolve(question) do
    type = question.type.value
    msg = create_query(question)
    data = DNS.to_iodata(msg)
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

  def resolve(name, type) do
    msg = create_query(name, type)
    data = DNS.to_iodata(msg)
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

        if length(nslist) > 0 do
          recursive_query(nslist, data)
        else
          {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_query(question) do
    message = DNS.Message.new()

    %{
      message
      | header: %{
          message.header
          | qdcount: 1
        },
        qdlist: [
          question
        ]
    }
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

  defp query_first([], message) do
    nil
  end

  defp query_first(list, message) do
    case Task.async_stream(
           list,
           fn {ip, port} ->
             {:ok, socket} = :gen_udp.open(0, active: false, mode: :binary)

             :ok = :gen_udp.send(socket, ip, port, message)
             # IO.inspect({:query_ns, ip, port, DNS.Message.from_iodata(message)})
             %{qdlist: [question | _]} = DNS.Message.from_iodata(message)
             IO.puts("Query nameserver #{:inet.ntoa(ip)}:#{port} <= #{question}")

             case :gen_udp.recv(socket, 0, to_timeout(second: 3)) do
               {:ok, recv_data} ->
                 {_ip, _port, data} = recv_data
                 :gen_udp.close(socket)
                 resp_message = DNS.Message.from_iodata(data)
                 header = resp_message.header
                 rcode = header.rcode

                 if to_string(rcode) == "NoError" do
                   if header.ancount > 0 do
                     awnsers = resp_message.anlist
                     {:ok, {:awnsers, awnsers, resp_message}}
                   else
                     nslist = resp_message.nslist
                     arlist = resp_message.arlist

                     if length(nslist) > 0 do
                       name_servers =
                         nslist
                         |> Enum.flat_map(fn rr ->
                           ns_server = rr.data.data
                           type = DNS.ResourceRecordType.new(:a)

                           arlist
                           |> Enum.filter(fn d ->
                             d.name.value == ns_server.value and
                               d.type == type
                           end)
                           |> Enum.map(& &1.data.data)
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
      [ok: {:ok, result}] ->
        result

      _ ->
        nil
    end
  end
end

defmodule HandleDNS do
  use Abyss.Handler
  alias DNS.Message.EDNS0

  def handle_data(recv_data, state) do
    {ip, port, data} = recv_data
    IO.puts("📩 Received UDP message from #{:inet.ntoa(ip)}:#{port} ->")
    dns_message = DNS.Message.from_iodata(data)
    IO.puts(to_string(dns_message))

    header = %{dns_message.header | qr: 1, ancount: 0, nscount: 0, arcount: 0}
    qdlist = dns_message.qdlist

    [question | _] = qdlist

    anlist =
      case NameResolver.resolve(question) do
        {:ok, list} ->
          list

        error ->
          IO.inspect(error)
          []
      end

    new_msg = %{
      DNS.Message.new()
      | header: %{
          header
          | id: dns_message.header.id,
            qr: 1,
            rd: 1,
            qdcount: length(qdlist),
            ancount: length(anlist)
        },
        qdlist: qdlist,
        anlist: anlist,
        nslist: [],
        arlist: []
    }

    iodata = DNS.to_iodata(new_msg)
    :gen_udp.send(state.socket, ip, port, iodata)
    IO.puts(to_string(new_msg))
    {:close, state}
  end
end
