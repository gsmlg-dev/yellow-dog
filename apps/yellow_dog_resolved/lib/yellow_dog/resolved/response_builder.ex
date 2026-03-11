defmodule YellowDog.Resolved.ResponseBuilder do
  @moduledoc """
  DNS response construction helpers using ex_dns.
  """

  @doc """
  Build a DNS response from an intercepted rule match.
  """
  @spec intercept_response(DNS.Message.t(), map()) :: DNS.Message.t()
  def intercept_response(query, rule) do
    case query.qdlist do
      [] ->
        build_response(query, [], DNS.Message.RCode.serv_fail())

      [question | _] ->
        query_type = question_type(question)

        if query_type == rule.type do
          case build_record(to_string(question.name), rule.type, rule.value, rule.ttl) do
            {:ok, record} ->
              build_response(query, [record], DNS.Message.RCode.no_error())

            :error ->
              # Malformed rule value — return SERVFAIL rather than crash
              build_response(query, [], DNS.Message.RCode.serv_fail())
          end
        else
          # Query type doesn't match rule type — NOERROR with 0 answers
          build_response(query, [], DNS.Message.RCode.no_error())
        end
    end
  end

  @doc """
  Build a SERVFAIL response.
  """
  @spec servfail_response(DNS.Message.t()) :: DNS.Message.t()
  def servfail_response(query) do
    build_response(query, [], DNS.Message.RCode.serv_fail())
  end

  @doc """
  Build a NXDOMAIN response.
  """
  @spec nxdomain_response(DNS.Message.t()) :: DNS.Message.t()
  def nxdomain_response(query) do
    build_response(query, [], DNS.Message.RCode.nx_domain())
  end

  @doc """
  Build a generic response with the given answers and rcode.
  """
  @spec build_response(DNS.Message.t(), [DNS.Message.Record.t()], integer()) :: DNS.Message.t()
  def build_response(query, answers, rcode) do
    %DNS.Message{
      header: %DNS.Message.Header{
        id: query.header.id,
        qr: 1,
        aa: 1,
        tc: 0,
        rd: query.header.rd,
        ra: 0,
        z: 0,
        ad: 0,
        cd: 0,
        opcode: query.header.opcode,
        rcode: rcode,
        qdcount: length(query.qdlist),
        ancount: length(answers),
        nscount: 0,
        arcount: 0
      },
      qdlist: query.qdlist,
      anlist: answers,
      nslist: [],
      arlist: []
    }
  end

  @doc """
  Build a DNS resource record for the given type and value.
  """
  @spec build_record(String.t(), atom(), String.t(), pos_integer()) ::
          {:ok, DNS.Message.Record.t()} | :error
  def build_record(name, :a, value, ttl) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _} = ip} -> {:ok, DNS.Message.Record.new(name, :a, :in, ttl, ip)}
      _ -> :error
    end
  end

  def build_record(name, :aaaa, value, ttl) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _} = ip} ->
        {:ok, DNS.Message.Record.new(name, :aaaa, :in, ttl, ip)}

      _ ->
        :error
    end
  end

  def build_record(name, :cname, value, ttl) do
    {:ok, DNS.Message.Record.new(name, :cname, :in, ttl, value)}
  end

  def build_record(name, :txt, value, ttl) do
    {:ok, DNS.Message.Record.new(name, :txt, :in, ttl, [value])}
  end

  def build_record(name, :mx, value, ttl) do
    # value format: "10 mail.example.com"
    case String.split(value, " ", parts: 2) do
      [priority_str, exchange] ->
        case Integer.parse(priority_str) do
          {priority, ""} ->
            {:ok, DNS.Message.Record.new(name, :mx, :in, ttl, {priority, exchange})}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  def build_record(name, :srv, value, ttl) do
    # value format: "10 20 5060 sip.example.com"
    case String.split(value, " ", parts: 4) do
      [pri_s, weight_s, port_s, target] ->
        with {pri, ""} <- Integer.parse(pri_s),
             {weight, ""} <- Integer.parse(weight_s),
             {port, ""} <- Integer.parse(port_s) do
          {:ok, DNS.Message.Record.new(name, :srv, :in, ttl, {pri, weight, port, target})}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def build_record(name, :ns, value, ttl) do
    {:ok, DNS.Message.Record.new(name, :ns, :in, ttl, value)}
  end

  def build_record(name, :ptr, value, ttl) do
    {:ok, DNS.Message.Record.new(name, :ptr, :in, ttl, value)}
  end

  def build_record(_name, _type, _value, _ttl), do: :error

  # Private

  @type_map %{
    "A" => :a,
    "AAAA" => :aaaa,
    "CNAME" => :cname,
    "TXT" => :txt,
    "MX" => :mx,
    "SRV" => :srv,
    "NS" => :ns,
    "PTR" => :ptr,
    "SOA" => :soa
  }

  defp question_type(%{type: type}) when is_atom(type), do: type

  defp question_type(%{type: type}) do
    type_str = to_string(type)
    Map.get(@type_map, type_str, :unknown)
  end
end
