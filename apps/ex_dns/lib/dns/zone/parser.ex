defmodule DNS.Zone.Parser do
  @moduledoc """
  A parser that converts DNS zone file tokens into an Abstract Syntax Tree (AST).

  Works with DNSZoneLexer to parse complete DNS zone files into structured data.
  """

  # AST node types
  defmodule ZoneFile do
    defstruct [:origin, :ttl, :records, :comments]

    @type t :: %__MODULE__{
            origin: String.t() | nil,
            # Changed to integer after conversion
            ttl: integer() | nil,
            records: [DNS.Zone.Parser.ResourceRecord.t()],
            comments: [String.t()]
          }
  end

  defmodule ResourceRecord do
    defstruct [:name, :ttl, :class, :type, :rdata, :line, :column]

    @type t :: %__MODULE__{
            name: String.t(),
            # Changed to integer after conversion
            ttl: integer() | nil,
            class: String.t(),
            type: String.t(),
            rdata: any(),
            line: integer(),
            column: integer()
          }
  end

  defmodule SOARecord do
    defstruct [:primary_ns, :admin_email, :serial, :refresh, :retry, :expire, :minimum]

    @type t :: %__MODULE__{
            primary_ns: String.t(),
            admin_email: String.t(),
            serial: integer(),
            # Changed to integer
            refresh: integer(),
            # Changed to integer
            retry: integer(),
            # Changed to integer
            expire: integer(),
            # Changed to integer
            minimum: integer()
          }
  end

  defmodule MXRecord do
    defstruct [:priority, :exchange]

    @type t :: %__MODULE__{
            priority: integer(),
            exchange: String.t()
          }
  end

  defmodule SRVRecord do
    defstruct [:priority, :weight, :port, :target]

    @type t :: %__MODULE__{
            priority: integer(),
            weight: integer(),
            port: integer(),
            target: String.t()
          }
  end

  # Parser state
  defstruct [:tokens, :position, :current_token, :zone_file]

  @doc """
  Parses a DNS zone file string into an AST.
  """
  def parse(input) when is_binary(input) do
    tokens = tokenize(input)
    parse_tokens(tokens)
  end

  @doc """
  Tokenizes the input string into tokens (embedded lexer).
  """
  def tokenize(input) when is_binary(input) do
    lexer = %{
      input: input,
      position: 0,
      current_char: String.at(input, 0),
      line: 1,
      column: 1
    }

    do_tokenize(lexer, [])
    |> Enum.reverse()
  end

  # Main tokenization loop
  defp do_tokenize(%{current_char: nil} = lexer, tokens) do
    [{:eof, nil, {lexer.line, lexer.column}} | tokens]
  end

  defp do_tokenize(lexer, tokens) do
    case next_token(lexer) do
      {token, new_lexer} ->
        do_tokenize(new_lexer, [token | tokens])
    end
  end

  # Lexer functions (embedded from DNSZoneLexer)
  defp next_token(%{current_char: nil} = lexer) do
    {{:eof, nil, {lexer.line, lexer.column}}, lexer}
  end

  defp next_token(lexer) do
    # Capture initial position for token location
    start_line = lexer.line
    start_column = lexer.column

    lexer
    |> skip_whitespace()
    |> case do
      %{current_char: nil} = l ->
        {{:eof, nil, {l.line, l.column}}, l}

      %{current_char: ";"} = l ->
        read_comment(l)

      %{current_char: "("} = l ->
        token = {:lparen, "(", {start_line, start_column}}
        {token, advance_lexer(l)}

      %{current_char: ")"} = l ->
        token = {:rparen, ")", {start_line, start_column}}
        {token, advance_lexer(l)}

      %{current_char: "\n"} = l ->
        token = {:newline, "\n", {start_line, start_column}}
        {token, advance_lexer(l)}

      %{current_char: "$"} = l ->
        read_directive(l)

      %{current_char: "\""} = l ->
        read_quoted_string(l)

      %{current_char: c} = l when c in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] ->
        read_number_or_time(l)

      l ->
        read_identifier(l)
    end
  end

  # Skip whitespace (except newlines)
  defp skip_whitespace(%{current_char: char} = lexer) when char in [" ", "\t", "\r"] do
    lexer
    |> advance_lexer()
    |> skip_whitespace()
  end

  defp skip_whitespace(lexer), do: lexer

  # Read a comment (from ; to end of line)
  defp read_comment(lexer) do
    start_line = lexer.line
    start_column = lexer.column
    {comment, new_lexer} = read_until_newline(lexer, "")
    # Remove leading semicolon from comment text
    comment_text = String.trim_leading(comment, ";")
    token = {:comment, comment_text, {start_line, start_column}}
    {token, new_lexer}
  end

  defp read_until_newline(%{current_char: "\n"} = lexer, acc), do: {acc, lexer}
  defp read_until_newline(%{current_char: nil} = lexer, acc), do: {acc, lexer}

  defp read_until_newline(lexer, acc) do
    read_until_newline(advance_lexer(lexer), acc <> lexer.current_char)
  end

  # Read a directive ($ORIGIN, $TTL, etc.)
  defp read_directive(lexer) do
    start_line = lexer.line
    start_column = lexer.column
    {directive, new_lexer} = read_while_alphanumeric(advance_lexer(lexer), "$")
    token = {:directive, directive, {start_line, start_column}}
    {token, new_lexer}
  end

  # Read a quoted string
  defp read_quoted_string(lexer) do
    start_line = lexer.line
    start_column = lexer.column
    # skip opening quote
    lexer = advance_lexer(lexer)
    {content, new_lexer} = read_until_quote(lexer, "")
    # skip closing quote
    new_lexer = advance_lexer(new_lexer)
    token = {:string, content, {start_line, start_column}}
    {token, new_lexer}
  end

  defp read_until_quote(%{current_char: "\""} = lexer, acc), do: {acc, lexer}
  defp read_until_quote(%{current_char: nil} = lexer, acc), do: {acc, lexer}

  defp read_until_quote(%{current_char: "\\"} = lexer, acc) do
    # Handle escaped characters
    lexer = advance_lexer(lexer)

    case lexer.current_char do
      nil -> {acc, lexer}
      char -> read_until_quote(advance_lexer(lexer), acc <> char)
    end
  end

  defp read_until_quote(lexer, acc) do
    read_until_quote(advance_lexer(lexer), acc <> lexer.current_char)
  end

  # Read a number or time value (like "3600" or "1h") or IP address
  defp read_number_or_time(lexer) do
    start_line = lexer.line
    start_column = lexer.column

    {initial_segment, after_initial_segment_lexer} = read_while_numeric(lexer, "")

    case after_initial_segment_lexer.current_char do
      "." ->
        # It could be an IPv4 address. We've already read the first numeric segment.
        # Now read the rest of the IPv4 characters (dots and numbers).
        {rest_of_ip_str, final_lexer} = read_while_ipv4_char(after_initial_segment_lexer, "")
        ip_str = initial_segment <> rest_of_ip_str
        token = {:ipv4, ip_str, {start_line, start_column}}
        {token, final_lexer}

      ":" ->
        # It's an IPv6 address. We've read the first numeric segment (which might be hex).
        # Now read the rest of the IPv6 characters (colons and hex digits).
        {rest_of_ip_str, final_lexer} = read_while_ipv6_char(after_initial_segment_lexer, "")
        ipv6_str = initial_segment <> rest_of_ip_str
        token = {:ipv6, ipv6_str, {start_line, start_column}}
        {token, final_lexer}

      unit when unit in ["s", "m", "h", "d", "w"] ->
        # It's a time value
        time_str = initial_segment <> unit
        token = {:time_value, time_str, {start_line, start_column}}
        {token, advance_lexer(after_initial_segment_lexer)}

      _ ->
        # It's just a number
        {number, _} = Integer.parse(initial_segment)
        token = {:number, number, {start_line, start_column}}
        {token, after_initial_segment_lexer}
    end
  end

  # Read IPv4 address characters (digits and dots)
  defp read_while_ipv4_char(%{current_char: char} = lexer, acc)
       when char != nil and
              (char in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] or char == ".") do
    read_while_ipv4_char(advance_lexer(lexer), acc <> char)
  end

  defp read_while_ipv4_char(lexer, acc), do: {acc, lexer}

  # Read IPv6 address characters (hex digits, colons)
  defp read_while_ipv6_char(%{current_char: char} = lexer, acc)
       when char != nil and
              ((char >= "0" and char <= "9") or
                 (char >= "a" and char <= "f") or
                 (char >= "A" and char <= "F") or
                 char == ":") do
    read_while_ipv6_char(advance_lexer(lexer), acc <> char)
  end

  defp read_while_ipv6_char(lexer, acc), do: {acc, lexer}

  defp read_while_numeric(%{current_char: char} = lexer, acc)
       when char in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] do
    read_while_numeric(advance_lexer(lexer), acc <> char)
  end

  defp read_while_numeric(lexer, acc), do: {acc, lexer}

  # Read an identifier (domain names, record types, etc.)
  defp read_identifier(lexer) do
    start_line = lexer.line
    start_column = lexer.column
    {identifier, new_lexer} = read_while_identifier_char(lexer, "")
    token_type = classify_identifier(identifier)
    token = {token_type, identifier, {start_line, start_column}}
    {token, new_lexer}
  end

  defp read_while_identifier_char(%{current_char: char} = lexer, acc)
       when char != nil and char not in [" ", "\t", "\n", "\r", "(", ")", ";", "\""] do
    read_while_identifier_char(advance_lexer(lexer), acc <> char)
  end

  defp read_while_identifier_char(lexer, acc), do: {acc, lexer}

  defp read_while_alphanumeric(%{current_char: char} = lexer, acc)
       when char != nil and
              ((char >= "a" and char <= "z") or
                 (char >= "A" and char <= "Z") or
                 (char >= "0" and char <= "9") or
                 char == "_") do
    read_while_alphanumeric(advance_lexer(lexer), acc <> char)
  end

  defp read_while_alphanumeric(lexer, acc), do: {acc, lexer}

  # Classify identifiers into appropriate token types
  defp classify_identifier(identifier) do
    cond do
      identifier == "@" ->
        :name

      identifier in ["IN", "CH", "HS"] ->
        :class

      identifier in ["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SOA", "PTR", "SRV", "NAPTR"] ->
        :type

      # Fully qualified domain name
      String.ends_with?(identifier, ".") ->
        :domain

      # Could be domain or partial name
      String.contains?(identifier, ".") ->
        :name

      true ->
        :name
    end
  end

  # Advance to the next character (lexer version)
  defp advance_lexer(%{position: pos, input: input, line: line, column: col} = lexer) do
    new_pos = pos + 1
    new_char = String.at(input, new_pos)

    {new_line, new_col} =
      if lexer.current_char == "\n" do
        {line + 1, 1}
      else
        {line, col + 1}
      end

    %{lexer | position: new_pos, current_char: new_char, line: new_line, column: new_col}
  end

  @doc """
  Parses a list of tokens into an AST.
  """
  def parse_tokens(tokens) do
    parser = %__MODULE__{
      tokens: tokens,
      position: 0,
      current_token: List.first(tokens),
      zone_file: %ZoneFile{origin: nil, ttl: nil, records: [], comments: []}
    }

    case parse_zone_file(parser) do
      {:ok, zone_file, _parser} -> {:ok, zone_file}
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse the entire zone file
  defp parse_zone_file(parser) do
    try do
      {zone_file, final_parser} = do_parse_zone_file(parser)
      {:ok, zone_file, final_parser}
    rescue
      e -> {:error, "Parse error: #{inspect(e)}"}
    end
  end

  defp do_parse_zone_file(%{current_token: {:eof, _, _}} = parser) do
    {parser.zone_file, parser}
  end

  defp do_parse_zone_file(parser) do
    case parser.current_token do
      {:directive, directive, _} ->
        {updated_zone, new_parser} = parse_directive(parser, directive)
        parser = %{new_parser | zone_file: updated_zone}
        do_parse_zone_file(parser)

      {:comment, comment, _} ->
        # Comments are collected in the order they appear
        # Correctly update the comments list within the existing ZoneFile struct
        updated_zone = %{parser.zone_file | comments: parser.zone_file.comments ++ [comment]}
        parser = %{advance(parser) | zone_file: updated_zone}
        do_parse_zone_file(parser)

      {:newline, _, _} ->
        do_parse_zone_file(advance(parser))

      # A name token can start a resource record or be a standalone name
      {:name, _, _} ->
        {record, new_parser} = parse_resource_record(parser)
        # Records are collected in the order they appear
        # Correctly update the records list within the existing ZoneFile struct
        updated_zone = %{parser.zone_file | records: parser.zone_file.records ++ [record]}
        parser = %{new_parser | zone_file: updated_zone}
        do_parse_zone_file(parser)

      # A domain token can also start a resource record implicitly
      {:domain, _, _} ->
        {record, new_parser} = parse_resource_record(parser)
        # Correctly update the records list within the existing ZoneFile struct
        updated_zone = %{parser.zone_file | records: parser.zone_file.records ++ [record]}
        parser = %{new_parser | zone_file: updated_zone}
        do_parse_zone_file(parser)

      {:eof, _, _} ->
        {parser.zone_file, parser}

      _ ->
        # Skip unexpected tokens, but raise an error if it's not a known starting token
        raise "Unexpected token #{inspect(parser.current_token)} at #{format_location(parser.current_token)}"
    end
  end

  # Parse directives like $ORIGIN and $TTL
  defp parse_directive(parser, "$ORIGIN") do
    # skip directive token
    parser = advance(parser)

    case parser.current_token do
      {:domain, origin, _} ->
        updated_zone = %{parser.zone_file | origin: origin}
        {updated_zone, advance(parser)}

      # Allow :name for origin if it's a relative name
      {:name, origin, _} ->
        updated_zone = %{parser.zone_file | origin: origin}
        {updated_zone, advance(parser)}

      _ ->
        raise "Expected domain name after $ORIGIN at #{format_location(parser.current_token)}"
    end
  end

  defp parse_directive(parser, "$TTL") do
    # skip directive token
    parser = advance(parser)

    case parser.current_token do
      {:number, ttl, _} ->
        updated_zone = %{parser.zone_file | ttl: ttl}
        {updated_zone, advance(parser)}

      {:time_value, ttl_str, _} ->
        ttl_seconds = convert_time_value(ttl_str)
        updated_zone = %{parser.zone_file | ttl: ttl_seconds}
        {updated_zone, advance(parser)}

      _ ->
        raise "Expected TTL value after $TTL at #{format_location(parser.current_token)}"
    end
  end

  defp parse_directive(parser, _directive) do
    # Skip unknown directives
    {parser.zone_file, advance(parser)}
  end

  # Parse a resource record
  defp parse_resource_record(parser) do
    # Parse name (can be :name or :domain)
    {name_token_type, name, {line, col}} = parser.current_token

    unless name_token_type in [:name, :domain] do
      raise "Expected record name (type :name or :domain) at #{format_location(parser.current_token)}"
    end

    parser = advance(parser)

    # Optional TTL
    # Skip newlines/comments before TTL
    parser = skip_insignificant_tokens(parser)

    {ttl, parser} =
      case parser.current_token do
        {:number, ttl_val, _} -> {ttl_val, advance(parser)}
        {:time_value, ttl_val_str, _} -> {convert_time_value(ttl_val_str), advance(parser)}
        # If no TTL, current_token remains, could be class or type
        _ -> {nil, parser}
      end

    # Parse class (optional, defaults to IN)
    # Skip newlines/comments before Class
    parser = skip_insignificant_tokens(parser)

    {class, parser} =
      case parser.current_token do
        {:class, class_val, _} -> {class_val, advance(parser)}
        _ -> {"IN", parser}
      end

    # Parse type
    # Skip newlines/comments before Type
    parser = skip_insignificant_tokens(parser)

    case parser.current_token do
      {:type, type, _} ->
        parser = advance(parser)
        {rdata, final_parser} = parse_rdata(parser, type)

        record = %ResourceRecord{
          name: name,
          ttl: ttl,
          class: class,
          type: type,
          rdata: rdata,
          line: line,
          column: col
        }

        {record, final_parser}

      _ ->
        raise "Expected record type after name/TTL/class at #{format_location(parser.current_token)}"
    end
  end

  # Parse resource data based on record type
  defp parse_rdata(parser, "SOA") do
    # SOA format: primary-ns admin-email serial refresh retry expire minimum
    {:domain, primary_ns, _} = expect_token(parser, :domain, "primary NS for SOA record")
    parser = advance(parser)

    {:domain, admin_email, _} = expect_token(parser, :domain, "admin email for SOA record")
    parser = advance(parser)

    # Handle multi-line SOA with parentheses - NOW SKIPS INTERVENING WHITESPACE/NEWLINES/COMMENTS
    parser = expect_lparen(parser)

    # Parse SOA fields, skipping insignificant tokens before each
    # Skip newlines/comments before serial
    parser = skip_insignificant_tokens(parser)
    {serial, parser} = parse_number_or_time(parser)

    # Skip newlines/comments before refresh
    parser = skip_insignificant_tokens(parser)
    {refresh, parser} = parse_number_or_time(parser)

    # Skip newlines/comments before retry
    parser = skip_insignificant_tokens(parser)
    {retry, parser} = parse_number_or_time(parser)

    # Skip newlines/comments before expire
    parser = skip_insignificant_tokens(parser)
    {expire, parser} = parse_number_or_time(parser)

    # Skip newlines/comments before minimum
    parser = skip_insignificant_tokens(parser)
    {minimum, parser} = parse_number_or_time(parser)

    # This handles the final ) and any whitespace/comments before it
    parser = expect_rparen(parser)

    soa = %SOARecord{
      primary_ns: primary_ns,
      admin_email: admin_email,
      serial: serial,
      refresh: refresh,
      retry: retry,
      expire: expire,
      minimum: minimum
    }

    {soa, parser}
  end

  defp parse_rdata(parser, "MX") do
    # MX format: priority exchange
    {:number, priority, _} = expect_token(parser, :number, "priority for MX record")
    parser = advance(parser)

    {:domain, exchange, _} = expect_token(parser, :domain, "exchange for MX record")
    parser = advance(parser)

    mx = %MXRecord{priority: priority, exchange: exchange}
    {mx, parser}
  end

  defp parse_rdata(parser, "SRV") do
    # SRV format: priority weight port target
    {:number, priority, _} = expect_token(parser, :number, "priority for SRV record")
    parser = advance(parser)

    {:number, weight, _} = expect_token(parser, :number, "weight for SRV record")
    parser = advance(parser)

    {:number, port, _} = expect_token(parser, :number, "port for SRV record")
    parser = advance(parser)

    {:domain, target, _} = expect_token(parser, :domain, "target for SRV record")
    parser = advance(parser)

    srv = %SRVRecord{priority: priority, weight: weight, port: port, target: target}
    {srv, parser}
  end

  defp parse_rdata(parser, "A") do
    # A record: IPv4 address
    case parser.current_token do
      {:ipv4, ip, _} ->
        {ip, advance(parser)}

      _ ->
        raise "Expected IPv4 address for A record at #{format_location(parser.current_token)}"
    end
  end

  defp parse_rdata(parser, "AAAA") do
    # AAAA record: IPv6 address
    case parser.current_token do
      {:ipv6, ip, _} ->
        {ip, advance(parser)}

      _ ->
        raise "Expected IPv6 address for AAAA record at #{format_location(parser.current_token)}"
    end
  end

  defp parse_rdata(parser, "CNAME") do
    # CNAME record: canonical name
    case parser.current_token do
      {:domain, cname, _} ->
        {cname, advance(parser)}

      # Allow :name for CNAME if it's a relative name
      {:name, cname, _} ->
        {cname, advance(parser)}

      _ ->
        raise "Expected domain name for CNAME record at #{format_location(parser.current_token)}"
    end
  end

  defp parse_rdata(parser, "NS") do
    # NS record: name server
    case parser.current_token do
      {:domain, ns, _} ->
        {ns, advance(parser)}

      # Allow :name for NS if it's a relative name
      {:name, ns, _} ->
        {ns, advance(parser)}

      _ ->
        raise "Expected domain name for NS record at #{format_location(parser.current_token)}"
    end
  end

  defp parse_rdata(parser, "TXT") do
    # TXT record: one or more quoted strings or unquoted text
    collect_txt_rdata(parser, [])
  end

  defp parse_rdata(parser, _type) do
    # Generic rdata parsing - collect tokens until newline or EOF
    collect_generic_rdata(parser, [])
  end

  # Helper functions
  defp collect_txt_rdata(%{current_token: {:string, text, _}} = parser, acc) do
    collect_txt_rdata(advance(parser), [text | acc])
  end

  defp collect_txt_rdata(%{current_token: {:rdata, text, _}} = parser, acc) do
    # This case handles unquoted text that might be part of a TXT record,
    # though quoted strings are more common and preferred.
    collect_txt_rdata(advance(parser), [text | acc])
  end

  defp collect_txt_rdata(parser, acc) do
    # Stop collecting when a non-TXT RDATA token is encountered (like newline, comment, directive, or another record's name)
    # Join the collected strings into a single string for the TXT record's value.
    {Enum.reverse(acc) |> Enum.join(""), parser}
  end

  defp collect_generic_rdata(%{current_token: {:newline, _, _}} = parser, acc) do
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(%{current_token: {:eof, _, _}} = parser, acc) do
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(%{current_token: {:comment, _, _}} = parser, acc) do
    # Stop at comments, they are handled separately
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(%{current_token: {:directive, _, _}} = parser, acc) do
    # Stop at directives
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(%{current_token: {:name, _, _}} = parser, acc) do
    # Stop at the start of a new record
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(%{current_token: {:domain, _, _}} = parser, acc) do
    # Stop at the start of a new record
    {Enum.reverse(acc), parser}
  end

  defp collect_generic_rdata(parser, acc) do
    {_, value, _} = parser.current_token
    collect_generic_rdata(advance(parser), [value | acc])
  end

  defp parse_number_or_time(parser) do
    case parser.current_token do
      {:number, val, _} -> {val, advance(parser)}
      {:time_value, val_str, _} -> {convert_time_value(val_str), advance(parser)}
      _ -> raise "Expected number or time value at #{format_location(parser.current_token)}"
    end
  end

  defp convert_time_value(value) when is_integer(value), do: value

  defp convert_time_value(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([smhdw])$/, value) do
      [_, num_str, unit] ->
        num = String.to_integer(num_str)

        case unit do
          "s" -> num
          "m" -> num * 60
          "h" -> num * 60 * 60
          "d" -> num * 24 * 60 * 60
          "w" -> num * 7 * 24 * 60 * 60
          _ -> raise "Unknown time unit: #{unit}"
        end

      _ ->
        # If it's a string but doesn't match a time format, it's an error for time_value token
        raise "Invalid time value format: #{value}"
    end
  end

  # New helper to skip newlines and comments
  defp skip_insignificant_tokens(parser) do
    case parser.current_token do
      {:newline, _, _} ->
        skip_insignificant_tokens(advance(parser))

      {:comment, _, _} ->
        skip_insignificant_tokens(advance(parser))

      _ ->
        parser
    end
  end

  # Updated to use skip_insignificant_tokens and expect the token
  defp expect_lparen(parser) do
    parser = skip_insignificant_tokens(parser)

    case parser.current_token do
      {:lparen, _, _} -> advance(parser)
      _ -> raise "Expected '(' for multi-line record at #{format_location(parser.current_token)}"
    end
  end

  # Updated to use skip_insignificant_tokens and expect the token
  defp expect_rparen(parser) do
    parser = skip_insignificant_tokens(parser)

    case parser.current_token do
      {:rparen, _, _} -> advance(parser)
      _ -> raise "Expected ')' for multi-line record at #{format_location(parser.current_token)}"
    end
  end

  # Helper to ensure a specific token type is found
  defp expect_token(parser, expected_type, context_message) do
    case parser.current_token do
      {^expected_type, value, _} ->
        # Return the full token tuple
        {expected_type, value, parser.current_token |> elem(2)}

      _ ->
        raise "Expected #{expected_type} for #{context_message} at #{format_location(parser.current_token)}"
    end
  end

  defp advance(%{tokens: tokens, position: pos} = parser) do
    new_pos = pos + 1
    new_token = Enum.at(tokens, new_pos)
    %{parser | position: new_pos, current_token: new_token}
  end

  # Helper for formatting error locations
  defp format_location({_type, _value, {line, col}}), do: "line #{line}, column #{col}"

  @doc """
  Pretty prints the AST for debugging.
  """
  def print_ast(%ZoneFile{} = zone_file) do
    IO.puts("=== DNS Zone File AST ===")

    if zone_file.origin do
      IO.puts("Origin: #{zone_file.origin}")
    end

    if zone_file.ttl do
      IO.puts("Default TTL: #{zone_file.ttl} seconds")
    end

    IO.puts("\nRecords:")
    # Records are now stored in order, no need to reverse
    zone_file.records
    |> Enum.each(&print_record/1)

    if length(zone_file.comments) > 0 do
      IO.puts("\nComments:")
      # Comments are now stored in order, no need to reverse
      zone_file.comments
      |> Enum.each(&IO.puts("  ; #{&1}"))
    end
  end

  defp print_record(%ResourceRecord{} = record) do
    ttl_str = if record.ttl, do: "#{record.ttl}s", else: ""
    IO.puts("  #{record.name} #{ttl_str} #{record.class} #{record.type}")
    print_rdata(record.rdata, "    ")
  end

  defp print_rdata(%SOARecord{} = soa, indent) do
    IO.puts("#{indent}Primary NS: #{soa.primary_ns}")
    IO.puts("#{indent}Admin Email: #{soa.admin_email}")
    IO.puts("#{indent}Serial: #{soa.serial}")
    IO.puts("#{indent}Refresh: #{soa.refresh}s")
    IO.puts("#{indent}Retry: #{soa.retry}s")
    IO.puts("#{indent}Expire: #{soa.expire}s")
    IO.puts("#{indent}Minimum: #{soa.minimum}s")
  end

  defp print_rdata(%MXRecord{} = mx, indent) do
    IO.puts("#{indent}Priority: #{mx.priority}, Exchange: #{mx.exchange}")
  end

  defp print_rdata(%SRVRecord{} = srv, indent) do
    IO.puts(
      "#{indent}Priority: #{srv.priority}, Weight: #{srv.weight}, Port: #{srv.port}, Target: #{srv.target}"
    )
  end

  defp print_rdata(rdata, indent) do
    IO.puts("#{indent}#{inspect(rdata)}")
  end

  @doc """
  Example usage with a sample DNS zone file.
  """
  def example do
    zone_content = """
    ; Example zone file
    $ORIGIN example.com.
    $TTL 3600

    @        IN  SOA ns1.example.com. admin.example.com. (
                 2023010101  ; serial
                 1h          ; refresh
                 15m         ; retry
                 1w          ; expire
                 1d          ; minimum
             )

    @        IN  NS  ns1.example.com.
    @        IN  NS  ns2.example.com.
    @        IN  A   192.168.1.1
    www      IN  A   192.168.1.2
    mail     IN  A   192.168.1.3
    @        IN  MX  10 mail.example.com.
    test.txt IN  TXT "This is a test" " of concatenated" " strings."
    ipv6     IN  AAAA 2001:0db8:85a3:0000:0000:8a2e:0370:7334
    """

    case parse(zone_content) do
      {:ok, ast} ->
        print_ast(ast)
        ast

      {:error, reason} ->
        IO.puts("Parse error: #{reason}")
        nil
    end
  end
end
