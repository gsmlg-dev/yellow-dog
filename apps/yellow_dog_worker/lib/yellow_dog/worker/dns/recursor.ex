defmodule YellowDog.Worker.Dns.Recursor do
  @moduledoc """
  Iterative recursive resolution starting from root hints.

  Every upstream query is sent with RD=0 through `Upstream.query/4`. Referrals
  are followed using only in-bailiwick glue; glueless NS names are resolved from
  the closest known servers within the same step budget. CNAME chains are
  followed up to `max_cname` links, and answer records that are neither the
  query name nor part of its chain (or lie outside the answering server's zone)
  are dropped.

  Options: `root_hints` (`[{ip, port}]`, default the IPv4 `RootHints` on `port`;
  IPv6 roots and AAAA glue are used only with `ipv6: true`), `port` (53),
  `cache` (`Cache.t()`: results under `{name, type}`, referral NS sets and glue
  under the separate `{name, type + 0x10000}` infrastructure keys), `max_steps`
  (64 upstream queries per resolution), `max_cname` (8), `deadline_ms` (5000).
  Exceeding any limit is `{:error, :servfail}`.
  """

  alias DNS.Message
  alias YellowDog.Worker.Dns.{Cache, RootHints, Upstream}

  @query_timeout 1_500
  @a 1
  @ns 2
  @cname 5
  @soa 6
  @aaaa 28
  # Delegation NS sets and glue are cached under type + @infra, a key space
  # (> 0xFFFF) that no client query type can reach, so they are never served
  # as answers and never overwrite authoritative data (RFC 2181 §5.4.1).
  @infra 0x10000

  @type result :: %{rcode: 0 | 3, answers: [DNS.Message.Record.t()], authority: [term()]}

  @spec resolve(String.t(), non_neg_integer(), keyword()) :: {:ok, result()} | {:error, :servfail}
  def resolve(name, type, opts \\ []) do
    port = Keyword.get(opts, :port, 53)
    ipv6 = Keyword.get(opts, :ipv6, false)

    st = %{
      roots: Keyword.get_lazy(opts, :root_hints, fn -> default_roots(port, ipv6) end),
      port: port,
      ipv6: ipv6,
      cache: Keyword.get(opts, :cache),
      max_steps: Keyword.get(opts, :max_steps, 64),
      max_cname: Keyword.get(opts, :max_cname, 8),
      steps: :counters.new(1, []),
      deadline: now() + Keyword.get(opts, :deadline_ms, 5_000)
    }

    case lookup(norm(name), type, st.max_cname, st) do
      {:ok, result} -> {:ok, result}
      _ -> {:error, :servfail}
    end
  catch
    :budget -> {:error, :servfail}
  end

  defp default_roots(port, ipv6) do
    Enum.flat_map(RootHints.servers(), fn {_name, v4, v6} ->
      if ipv6, do: [{v4, port}, {v6, port}], else: [{v4, port}]
    end)
  end

  defp lookup(name, type, cnames, st) do
    case cache_get(st.cache, name, type) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        {zone, servers} = closest(name, st)

        with {:ok, result} <- iterate(name, type, zone, servers, cnames, st) do
          cache_put(st.cache, name, type, result)
          {:ok, result}
        end
    end
  end

  # Deepest ancestor whose NS set and at least one server address are cached.
  defp closest(_name, %{cache: nil} = st), do: {"", st.roots}

  defp closest(name, st) do
    name
    |> ancestors()
    |> Enum.find_value({"", st.roots}, fn zone ->
      with {:ok, %{answers: [_ | _] = ns}} <- cache_get(st.cache, zone, @infra + @ns),
           [_ | _] = servers <-
             Enum.flat_map(ns, &cached_addresses(norm(&1.data.data), st)) do
        {zone, servers}
      else
        _ -> nil
      end
    end)
  end

  # Glue first, then an authoritative answer for the host.
  defp cached_addresses(host, st) do
    for type <- address_types(st), key <- [@infra + type, type] do
      case cache_get(st.cache, host, key) do
        {:ok, %{answers: answers}} -> addresses(answers, host, type, st.port)
        :miss -> []
      end
    end
    |> Enum.find([], &(&1 != []))
  end

  defp iterate(name, type, zone, servers, cnames, st) do
    outcome =
      Enum.reduce_while(servers, :lame, fn server, :lame ->
        with {:ok, msg} <- query(server, name, type, st),
             outcome when outcome != :lame <- classify(msg, name, type, zone, cnames) do
          {:halt, outcome}
        else
          _ -> {:cont, :lame}
        end
      end)

    case outcome do
      {:answer, records} ->
        {:ok, %{rcode: 0, answers: records, authority: []}}

      {:negative, rcode, soa} ->
        {:ok, %{rcode: rcode, answers: [], authority: soa}}

      {:cname, chain, target, left} ->
        with {:ok, result} <- lookup(target, type, left, st) do
          {:ok, %{result | answers: chain ++ result.answers}}
        end

      {:referral, child, hosts, glue} ->
        cache_referral(st, child, hosts, glue)

        case glue_servers(glue, st) do
          [] -> iterate(name, type, child, resolve_hosts(hosts, st), cnames, st)
          servers -> iterate(name, type, child, servers, cnames, st)
        end

      _ ->
        {:error, :servfail}
    end
  end

  defp query({ip, port}, name, type, st) do
    remaining = st.deadline - now()
    if remaining <= 0 or :counters.get(st.steps, 1) >= st.max_steps, do: throw(:budget)
    :counters.add(st.steps, 1, 1)
    Upstream.query({ip, port}, name, type, rd: false, timeout: min(remaining, @query_timeout))
  end

  defp classify(%Message{} = msg, name, type, zone, cnames) do
    <<rcode::4>> = msg.header.rcode.value

    case walk(msg.anlist, name, type, zone, cnames, []) do
      :cname_limit -> :cname_limit
      _ when rcode not in [0, 3] -> :lame
      {:done, records} -> {:answer, records}
      {:open, [_ | _] = chain, target, left} -> {:cname, chain, target, left}
      {:open, [], _, _} -> classify_empty(msg, rcode, name, zone)
    end
  end

  defp classify_empty(msg, rcode, name, zone) do
    soa =
      Enum.filter(msg.nslist, fn r ->
        owner = norm(r.name)
        r.type.value == <<@soa::16>> and in_zone?(owner, zone) and in_zone?(name, owner)
      end)

    cond do
      rcode == 3 ->
        {:negative, 3, soa}

      referral = referral(msg, name, zone) ->
        referral

      soa != [] or msg.header.aa == 1 ->
        {:negative, 0, soa}

      true ->
        :lame
    end
  end

  # Follows the query name through CNAMEs inside one answer section. Records
  # outside the chain, or outside the answering server's zone, are ignored.
  defp walk(anlist, cur, type, zone, cnames, chain) do
    owned = if in_zone?(cur, zone), do: Enum.filter(anlist, &(norm(&1.name) == cur)), else: []

    case Enum.filter(owned, &(&1.type.value == <<type::16>>)) do
      [_ | _] = records ->
        {:done, chain ++ records}

      [] ->
        case Enum.find(owned, &(&1.type.value == <<@cname::16>>)) do
          nil -> {:open, chain, cur, cnames}
          _ when cnames <= 0 -> :cname_limit
          cname -> walk(anlist, norm(cname.data.data), type, zone, cnames - 1, chain ++ [cname])
        end
    end
  end

  # A referral must delegate a zone strictly below the current one that still
  # contains the query name; otherwise the server is treated as lame.
  defp referral(msg, name, zone) do
    ns =
      Enum.filter(msg.nslist, fn r ->
        owner = norm(r.name)

        r.type.value == <<@ns::16>> and owner != zone and in_zone?(owner, zone) and
          in_zone?(name, owner)
      end)

    case ns do
      [] ->
        nil

      _ ->
        child = ns |> Enum.map(&norm(&1.name)) |> Enum.max_by(&byte_size/1)
        ns = Enum.filter(ns, &(norm(&1.name) == child))
        hosts = Enum.map(ns, &norm(&1.data.data))

        glue =
          Enum.filter(msg.arlist, fn r ->
            host = norm(r.name)
            host in hosts and in_zone?(host, child)
          end)

        {:referral, child, {ns, hosts}, glue}
    end
  end

  defp glue_servers(glue, st) do
    Enum.flat_map(address_types(st), fn type ->
      Enum.flat_map(glue, &addresses([&1], norm(&1.name), type, st.port))
    end)
  end

  defp resolve_hosts({_ns, hosts}, st) do
    Enum.find_value(hosts, [], fn host ->
      case lookup(host, @a, st.max_cname, st) do
        # The answers are the validated chain, so every A record is the host's.
        {:ok, %{rcode: 0, answers: answers}} ->
          case for(r <- answers, r.type.value == <<@a::16>>, do: {r.data.data, st.port}) do
            [] -> nil
            servers -> servers
          end

        _ ->
          nil
      end
    end)
  end

  defp addresses(records, host, type, port) do
    for r <- records, norm(r.name) == host, r.type.value == <<type::16>>, do: {r.data.data, port}
  end

  defp cache_referral(%{cache: nil}, _, _, _), do: :ok

  defp cache_referral(st, child, {ns, _hosts}, glue) do
    cache_put(st.cache, child, @infra + @ns, %{rcode: 0, answers: ns, authority: []})

    glue
    |> Enum.filter(&(&1.type.value in Enum.map(address_types(st), fn t -> <<t::16>> end)))
    |> Enum.group_by(&{norm(&1.name), &1.type.value})
    |> Enum.each(fn {{host, <<type::16>>}, records} ->
      cache_put(st.cache, host, @infra + type, %{rcode: 0, answers: records, authority: []})
    end)
  end

  defp address_types(%{ipv6: true}), do: [@a, @aaaa]
  defp address_types(_), do: [@a]

  defp ancestors(name) do
    labels = String.split(name, ".", trim: true)
    for i <- 0..(length(labels) - 1)//1, do: labels |> Enum.drop(i) |> Enum.join(".")
  end

  defp in_zone?(_name, ""), do: true
  defp in_zone?(name, zone), do: name == zone or String.ends_with?(name, "." <> zone)

  defp norm(name), do: name |> to_string() |> String.downcase() |> String.trim_trailing(".")

  defp now, do: System.monotonic_time(:millisecond)

  # The cache table may be deleted by an adapter update mid-resolution.
  defp cache_get(nil, _name, _type), do: :miss

  defp cache_get(cache, name, type) do
    Cache.get(cache, name, type)
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(nil, _name, _type, _result), do: :ok

  defp cache_put(cache, name, type, result) do
    Cache.put(cache, name, type, result)
  rescue
    ArgumentError -> :ok
  end
end
