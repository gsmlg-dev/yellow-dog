defmodule YellowDog.Dns.Zone.Parser do
  @moduledoc """
  Parser for BIND-style DNS zone files.

  Supports standard BIND zone file syntax including:
  - $ORIGIN and $TTL directives
  - Comments (lines starting with ;)
  - Standard record types (A, AAAA, NS, SOA, MX, TXT, CNAME, PTR, SRV, CAA)
  - Multi-line SOA records
  - Relative and absolute domain names
  - Default owner (@)

  ## Example Zone File

      $ORIGIN example.com.
      $TTL 3600

      @  IN  SOA ns1.example.com. admin.example.com. (
                 2024102801  ; Serial
                 7200        ; Refresh
                 3600        ; Retry
                 1209600     ; Expire
                 3600 )      ; Minimum TTL

         IN  NS  ns1.example.com.
         IN  NS  ns2.example.com.

      ns1  IN  A    192.168.1.10
      ns2  IN  A    192.168.1.11
      www  IN  A    192.168.1.100
      mail IN  A    192.168.1.20

      @    IN  MX   10 mail.example.com.
      @    IN  TXT  "v=spf1 mx a -all"
  """

  require Logger
  alias YellowDog.Dns.Zone

  @type parse_result :: {:ok, Zone.t()} | {:error, term()}

  @doc """
  Parses a zone file from disk.

  ## Parameters
  - `file_path` - Path to the zone file
  - `opts` - Parse options

  ## Options
  - `:zone_name` - Zone name (required if not in $ORIGIN)
  - `:zone_type` - Zone type (default: :master)
  - `:default_ttl` - Default TTL (default: 3600)

  ## Returns
  - `{:ok, zone}` - Successfully parsed zone
  - `{:error, reason}` - Parse error

  ## Examples

      iex> Parser.parse_file("zones/example.com.zone", zone_name: "example.com")
      {:ok, %Zone{...}}
  """
  @spec parse_file(String.t(), keyword()) :: parse_result()
  def parse_file(file_path, opts \\ []) do
    case File.read(file_path) do
      {:ok, content} ->
        opts = Keyword.put(opts, :file, file_path)
        parse_string(content, opts)

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  @doc """
  Parses a zone from a string.

  ## Parameters
  - `content` - Zone file content as string
  - `opts` - Parse options (see parse_file/2)

  ## Returns
  - `{:ok, zone}` - Successfully parsed zone
  - `{:error, reason}` - Parse error
  """
  @spec parse_string(String.t(), keyword()) :: parse_result()
  def parse_string(content, opts \\ []) when is_binary(content) do
    zone_name = Keyword.get(opts, :zone_name)
    zone_type = Keyword.get(opts, :zone_type, :master)
    default_ttl = Keyword.get(opts, :default_ttl, 3600)

    unless zone_name do
      {:error, :zone_name_required}
    else
      initial_state = %{
        zone_name: zone_name,
        origin: ensure_trailing_dot(zone_name),
        default_ttl: default_ttl,
        last_owner: "@",
        line_number: 0,
        in_paren: false,
        buffer: ""
      }

      case parse_lines(content, initial_state) do
        {:ok, records, final_state} ->
          build_zone(zone_name, zone_type, records, final_state, opts)

        {:error, _} = error ->
          error
      end
    end
  end

  ## Private Functions

  defp parse_lines(content, state) do
    lines = String.split(content, "\n")

    result =
      Enum.reduce_while(lines, {:ok, [], state}, fn line, {:ok, records, state} ->
        state = Map.update!(state, :line_number, &(&1 + 1))

        case parse_line(line, state) do
          {:ok, nil, new_state} ->
            # Directive or comment, continue
            {:cont, {:ok, records, new_state}}

          {:ok, record, new_state} ->
            # Valid record parsed
            {:cont, {:ok, [record | records], new_state}}

          {:error, reason} ->
            # Parse error
            {:halt, {:error, {:parse_error, reason, state.line_number}}}

          {:continue, new_state} ->
            # Multi-line record (in parentheses)
            {:cont, {:ok, records, new_state}}
        end
      end)

    case result do
      {:ok, records, final_state} ->
        # Check if we're still in parentheses (unclosed)
        if final_state.in_paren do
          {:error, {:unclosed_parentheses, final_state.line_number}}
        else
          {:ok, Enum.reverse(records), final_state}
        end

      error ->
        error
    end
  end

  defp parse_line(line, state) do
    # Strip comments
    line = strip_comment(line)

    # Handle multi-line records (parentheses)
    {line, state} = handle_parentheses(line, state)

    # Skip empty lines
    if String.trim(line) == "" do
      {:ok, nil, state}
    else
      cond do
        # Still in multi-line record
        state.in_paren ->
          {:continue, state}

        # Directive
        String.starts_with?(line, "$") ->
          handle_directive(line, state)

        # Resource record
        true ->
          parse_record(line, state)
      end
    end
  end

  defp strip_comment(line) do
    case String.split(line, ";", parts: 2) do
      [content, _comment] -> content
      [content] -> content
    end
  end

  defp handle_parentheses(line, %{in_paren: false} = state) do
    if String.contains?(line, "(") do
      # Start multi-line record
      parts = String.split(line, "(", parts: 2)
      before = Enum.at(parts, 0, "")
      after_paren = Enum.at(parts, 1, "")

      # Check if closing paren on same line
      if String.contains?(after_paren, ")") do
        [inside, after_close] = String.split(after_paren, ")", parts: 2)
        full_line = before <> " " <> inside <> " " <> after_close
        {full_line, state}
      else
        # Start buffering
        new_state =
          state
          |> Map.put(:in_paren, true)
          |> Map.put(:buffer, before <> " " <> after_paren)

        {"", new_state}
      end
    else
      {line, state}
    end
  end

  defp handle_parentheses(line, %{in_paren: true} = state) do
    if String.contains?(line, ")") do
      # End multi-line record
      [inside, _after] = String.split(line, ")", parts: 2)
      full_line = state.buffer <> " " <> inside

      new_state =
        state
        |> Map.put(:in_paren, false)
        |> Map.put(:buffer, "")

      {full_line, new_state}
    else
      # Continue buffering
      new_state = Map.update!(state, :buffer, &(&1 <> " " <> line))
      {"", new_state}
    end
  end

  defp handle_directive(line, state) do
    parts = String.split(line, ~r/\s+/, parts: 2, trim: true)
    directive = Enum.at(parts, 0, "")
    value = Enum.at(parts, 1, "")

    case directive do
      "$ORIGIN" ->
        new_state = Map.put(state, :origin, ensure_trailing_dot(value))
        {:ok, nil, new_state}

      "$TTL" ->
        case parse_ttl(value) do
          {:ok, ttl} ->
            new_state = Map.put(state, :default_ttl, ttl)
            {:ok, nil, new_state}

          :error ->
            {:error, "Invalid TTL: #{value}"}
        end

      "$INCLUDE" ->
        # Not implemented yet
        Logger.warning("$INCLUDE directive not yet implemented")
        {:ok, nil, state}

      _ ->
        {:error, "Unknown directive: #{directive}"}
    end
  end

  defp parse_record(line, state) do
    # Tokenize the line
    tokens = String.split(line, ~r/\s+/, trim: true)

    case parse_record_tokens(tokens, state) do
      {:ok, record} ->
        # Update last owner for records without explicit owner
        new_state = Map.put(state, :last_owner, record.owner)
        {:ok, record, new_state}

      {:error, _} = error ->
        error
    end
  end

  defp parse_record_tokens(tokens, state) when length(tokens) >= 3 do
    # Parse: [owner] [ttl] [class] type rdata...
    # owner is optional (use last_owner)
    # ttl is optional (use default_ttl)
    # class is optional (default IN)

    {owner, rest} = parse_owner(tokens, state)
    {ttl, rest} = parse_optional_ttl(rest, state.default_ttl)
    {class, rest} = parse_optional_class(rest)
    {type, rdata_tokens} = parse_type_and_rdata(rest)

    case parse_rdata(type, rdata_tokens, state) do
      {:ok, rdata} ->
        # Make owner absolute if relative
        absolute_owner = make_absolute(owner, state.origin)

        record = %{
          owner: absolute_owner,
          ttl: ttl,
          class: class,
          type: type,
          rdata: rdata
        }

        {:ok, record}

      {:error, _} = error ->
        error
    end
  end

  defp parse_record_tokens(_tokens, _state) do
    {:error, "Invalid record format"}
  end

  defp parse_owner([first | rest], state) do
    cond do
      # Owner is @ (zone apex)
      first == "@" ->
        {"@", rest}

      # Owner is a domain name (starts with letter, digit, underscore, hyphen, or wildcard asterisk)
      String.match?(first, ~r/^[a-zA-Z0-9_\-\*]/) and not is_ttl?(first) and
          first not in ["IN", "CH", "HS"] and not is_record_type?(first) ->
        {first, rest}

      # No owner specified, use last_owner
      true ->
        {state.last_owner, [first | rest]}
    end
  end

  defp parse_optional_ttl([first | rest], default_ttl) do
    case parse_ttl(first) do
      {:ok, ttl} -> {ttl, rest}
      :error -> {default_ttl, [first | rest]}
    end
  end

  defp parse_optional_ttl([], default_ttl), do: {default_ttl, []}

  defp parse_optional_class([first | rest]) when first in ["IN", "CH", "HS"] do
    {String.to_atom(first), rest}
  end

  defp parse_optional_class(tokens), do: {:IN, tokens}

  defp parse_type_and_rdata([type | rdata]) do
    {String.to_atom(type), rdata}
  end

  defp parse_type_and_rdata([]) do
    {:error, "Missing record type"}
  end

  defp parse_rdata(:A, [ip], _state) do
    case parse_ipv4(ip) do
      {:ok, addr} -> {:ok, addr}
      :error -> {:error, "Invalid IPv4 address: #{ip}"}
    end
  end

  defp parse_rdata(:AAAA, [ip], _state) do
    case parse_ipv6(ip) do
      {:ok, addr} -> {:ok, addr}
      :error -> {:error, "Invalid IPv6 address: #{ip}"}
    end
  end

  defp parse_rdata(:NS, [nameserver], state) do
    {:ok, make_absolute(nameserver, state.origin)}
  end

  defp parse_rdata(:CNAME, [target], state) do
    {:ok, make_absolute(target, state.origin)}
  end

  defp parse_rdata(:PTR, [target], state) do
    {:ok, make_absolute(target, state.origin)}
  end

  defp parse_rdata(:MX, [priority, exchange], state) do
    case Integer.parse(priority) do
      {prio, ""} ->
        {:ok, {prio, make_absolute(exchange, state.origin)}}

      _ ->
        {:error, "Invalid MX priority: #{priority}"}
    end
  end

  defp parse_rdata(:TXT, tokens, _state) do
    # Combine all tokens and handle quoted strings
    text = Enum.join(tokens, " ")
    {:ok, parse_txt_string(text)}
  end

  defp parse_rdata(:SOA, tokens, state) do
    # SOA: mname rname serial refresh retry expire minimum
    case tokens do
      [mname, rname, serial, refresh, retry, expire, minimum] ->
        with {:ok, serial_int} <- parse_integer(serial),
             {:ok, refresh_int} <- parse_integer(refresh),
             {:ok, retry_int} <- parse_integer(retry),
             {:ok, expire_int} <- parse_integer(expire),
             {:ok, minimum_int} <- parse_integer(minimum) do
          soa = %Zone.SOA{
            mname: make_absolute(mname, state.origin),
            rname: make_absolute(rname, state.origin),
            serial: serial_int,
            refresh: refresh_int,
            retry: retry_int,
            expire: expire_int,
            minimum: minimum_int
          }

          {:ok, soa}
        else
          :error -> {:error, "Invalid SOA field values"}
        end

      _ ->
        {:error, "SOA requires 7 fields"}
    end
  end

  defp parse_rdata(:SRV, [priority, weight, port, target], state) do
    with {:ok, prio} <- parse_integer(priority),
         {:ok, wt} <- parse_integer(weight),
         {:ok, pt} <- parse_integer(port) do
      {:ok, {prio, wt, pt, make_absolute(target, state.origin)}}
    else
      :error -> {:error, "Invalid SRV field values"}
    end
  end

  defp parse_rdata(:CAA, [flags, tag | value_tokens], _state) do
    with {:ok, flags_int} <- parse_integer(flags) do
      value = Enum.join(value_tokens, " ")
      {:ok, {flags_int, tag, parse_txt_string(value)}}
    else
      :error -> {:error, "Invalid CAA flags"}
    end
  end

  defp parse_rdata(type, _tokens, _state) do
    {:error, "Unsupported record type: #{type}"}
  end

  # Helper functions

  defp is_ttl?(str) do
    case Integer.parse(str) do
      {_num, ""} -> true
      _ -> false
    end
  end

  defp is_record_type?(str) do
    type = String.to_atom(str)

    type in [
      :A,
      :AAAA,
      :NS,
      :SOA,
      :MX,
      :TXT,
      :CNAME,
      :PTR,
      :SRV,
      :CAA,
      :NAPTR,
      :TLSA
    ]
  rescue
    _ -> false
  end

  defp parse_ttl(str) do
    case Integer.parse(str) do
      {num, ""} when num >= 0 -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_ipv4(str) do
    charlist = String.to_charlist(str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  defp parse_ipv6(str) do
    charlist = String.to_charlist(str)

    case :inet.parse_ipv6_address(charlist) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  defp parse_txt_string(text) do
    # Remove surrounding quotes if present
    text
    |> String.trim()
    |> String.trim("\"")
  end

  defp make_absolute(name, origin) do
    cond do
      name == "@" ->
        "@"

      String.ends_with?(name, ".") ->
        name

      true ->
        name <> "." <> origin
    end
  end

  defp ensure_trailing_dot(name) do
    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end

  defp build_zone(zone_name, zone_type, records, final_state, opts) do
    zone = Zone.new(zone_name, zone_type,
      ttl: final_state.default_ttl,
      file: Keyword.get(opts, :file)
    )

    # Separate SOA from other records
    {soa_records, other_records} =
      Enum.split_with(records, fn record -> record.type == :SOA end)

    # Set SOA if present
    zone =
      case soa_records do
        [soa_rec | _] ->
          Zone.set_soa(zone, soa_rec.rdata)

        [] ->
          zone
      end

    # Add all other records
    zone =
      Enum.reduce(other_records, zone, fn record, acc ->
        dns_record =
          Zone.Record.new(
            record.owner,
            record.type,
            record.rdata,
            ttl: record.ttl,
            class: record.class
          )

        Zone.add_record(acc, dns_record)
      end)

    # Mark as loaded
    zone = Zone.mark_loaded(zone)

    {:ok, zone}
  end
end
