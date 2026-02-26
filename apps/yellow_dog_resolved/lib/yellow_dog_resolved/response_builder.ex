defmodule YellowDog.Resolved.ResponseBuilder do
  @moduledoc """
  Constructs valid DNS response messages from intercept rules and error conditions.

  Uses the `ex_dns` library to build properly formatted DNS responses including:
  - Intercepted responses (A, AAAA, CNAME, TXT, MX, SRV)
  - NXDOMAIN responses for non-matching intercept types
  - SERVFAIL responses for upstream failures
  - FORMERR responses for malformed queries
  """

  @doc """
  Build a successful intercepted response for a matched rule.
  Copies the transaction ID from the query. Sets QR=1, AA=1, RD=1, RA=0.
  """
  @spec build_intercept_response(DNS.Message.t(), map()) :: DNS.Message.t()
  def build_intercept_response(query, rule) do
    case query.qdlist do
      [question | _] ->
        query_type = record_type_atom(question.type)

        if query_type == rule.type do
          # Types match — return answer
          record = build_record(question.name, rule.type, rule.value, rule.ttl)

          query
          |> set_response_flags()
          |> Map.put(:anlist, [record])
          |> update_counts(1, 0, 0)
        else
          # Types don't match — return empty answer (NOERROR, 0 answers)
          query
          |> set_response_flags()
          |> Map.put(:anlist, [])
          |> update_counts(0, 0, 0)
        end

      [] ->
        build_formerr(query)
    end
  end

  @doc "Build an NXDOMAIN response."
  @spec build_nxdomain(DNS.Message.t()) :: DNS.Message.t()
  def build_nxdomain(query) do
    query
    |> set_response_flags()
    |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(3))
    |> Map.put(:anlist, [])
    |> update_counts(0, 0, 0)
  end

  @doc "Build a SERVFAIL response (all upstreams failed)."
  @spec build_servfail(DNS.Message.t()) :: DNS.Message.t()
  def build_servfail(query) do
    query
    |> set_response_flags()
    |> DNS.Message.update_header_attr(:aa, 0)
    |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(2))
    |> Map.put(:anlist, [])
    |> update_counts(0, 0, 0)
  end

  @doc "Build a FORMERR response for malformed queries."
  @spec build_formerr(non_neg_integer()) :: DNS.Message.t()
  def build_formerr(txn_id) do
    DNS.Message.new()
    |> DNS.Message.update_header_attr(:id, txn_id)
    |> DNS.Message.update_header_attr(:qr, 1)
    |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(1))
  end

  @doc "Build a DNS response from a cached or forwarded response binary with rewritten txn_id."
  @spec rewrite_txn_id(binary(), non_neg_integer()) :: binary()
  def rewrite_txn_id(<<_old_id::16, rest::binary>>, new_id) do
    <<new_id::16, rest::binary>>
  end

  def rewrite_txn_id(short_binary, _new_id) when is_binary(short_binary) do
    short_binary
  end

  # Private functions

  defp set_response_flags(message) do
    message
    |> DNS.Message.update_header_attr(:qr, 1)
    |> DNS.Message.update_header_attr(:aa, 1)
    |> DNS.Message.update_header_attr(:rd, 1)
    |> DNS.Message.update_header_attr(:ra, 0)
    |> DNS.Message.update_header_attr(:rcode, DNS.Message.RCode.new(0))
  end

  defp update_counts(message, ancount, nscount, arcount) do
    message
    |> DNS.Message.update_header_attr(:ancount, ancount)
    |> DNS.Message.update_header_attr(:nscount, nscount)
    |> DNS.Message.update_header_attr(:arcount, arcount)
  end

  defp build_record(name, :a, value, ttl) do
    ip = parse_ip!(value)
    DNS.Message.Record.new(to_string(name), 1, 1, ttl, ip)
  end

  defp build_record(name, :aaaa, value, ttl) do
    ip = parse_ip!(value)
    DNS.Message.Record.new(to_string(name), 28, 1, ttl, ip)
  end

  defp build_record(name, :cname, value, ttl) do
    DNS.Message.Record.new(to_string(name), 5, 1, ttl, value)
  end

  defp build_record(name, :txt, value, ttl) do
    DNS.Message.Record.new(to_string(name), 16, 1, ttl, [value])
  end

  defp build_record(name, :mx, value, ttl) do
    # Value format: "10 mail.example.com"
    case String.split(value, " ", parts: 2) do
      [priority_str, target] ->
        priority = parse_integer!(priority_str, "MX priority")
        DNS.Message.Record.new(to_string(name), 15, 1, ttl, {priority, target})

      _ ->
        raise ArgumentError,
              "invalid MX value format: #{inspect(value)}, expected \"priority target\""
    end
  end

  defp build_record(name, :srv, value, ttl) do
    # Value format: "10 20 8080 target.example.com"
    case String.split(value, " ", parts: 4) do
      [pri_str, weight_str, port_str, target] ->
        DNS.Message.Record.new(to_string(name), 33, 1, ttl, {
          parse_integer!(pri_str, "SRV priority"),
          parse_integer!(weight_str, "SRV weight"),
          parse_integer!(port_str, "SRV port"),
          target
        })

      _ ->
        raise ArgumentError,
              "invalid SRV value format: #{inspect(value)}, expected \"priority weight port target\""
    end
  end

  defp parse_ip!(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, :einval} -> raise ArgumentError, "invalid IP address: #{inspect(value)}"
    end
  end

  defp parse_integer!(str, label) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> raise ArgumentError, "invalid #{label}: #{inspect(str)}, expected integer"
    end
  end

  defp record_type_atom(type) do
    type_str = to_string(type) |> String.downcase()

    case type_str do
      "a" -> :a
      "aaaa" -> :aaaa
      "cname" -> :cname
      "txt" -> :txt
      "mx" -> :mx
      "srv" -> :srv
      _ -> :unknown
    end
  end
end
