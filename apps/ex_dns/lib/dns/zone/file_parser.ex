defmodule DNS.Zone.FileParser do
  @moduledoc """
  DNS Zone file parser and generator for standard BIND format zone files.

  Supports parsing and generation of DNS record types including:
  - Standard records: SOA, NS, A, AAAA, CNAME, MX, TXT, SRV, PTR
  - DNSSEC records: DNSKEY, DS, RRSIG, NSEC, NSEC3, NSEC3PARAM
  - Security records: CAA, TLSA
  - Modern records: HTTPS, SVCB

  Handles:
  - Comments (starting with ;)
  - Line continuations
  - Zone directives: $ORIGIN, $TTL, $INCLUDE, $GENERATE
  - Class specifications (IN, CH, HS, NONE, ANY)
  - TTL specifications and defaults
  - Zone validation and error reporting
  """

  require Logger

  alias DNS.Zone.RRSet

  @type zone_data :: %{
          origin: String.t() | nil,
          ttl: integer(),
          soa: map() | nil,
          records: list(RRSet.t()),
          includes: list(String.t()),
          directives: list(map()),
          errors: list(map()),
          warnings: list(map())
        }

  @type parse_error :: %{
          line: integer(),
          message: String.t(),
          context: String.t()
        }

  @type parse_warning :: %{
          line: integer(),
          message: String.t(),
          context: String.t()
        }

  @doc """
  Parse a zone file from a string with enhanced error handling and validation.

  ## Examples

      iex> zone_content = \"""
      ...> $ORIGIN example.com.
      ...> $TTL 3600
      ...> @       IN  SOA ns1.example.com. admin.example.com. (
      ...>                     2024010101  ; Serial
      ...>                     3600        ; Refresh
      ...>                     1800        ; Retry
      ...>                     604800      ; Expire
      ...>                     86400 )     ; Minimum TTL
      ...> @       IN  NS  ns1.example.com.
      ...> @       IN  NS  ns2.example.com.
      ...> ns1     IN  A   192.0.2.1
      ...> ns2     IN  A   192.0.2.2
      ...> www     IN  A   192.0.2.100
      ...> \"""
      iex> {:ok, zone} = DNS.Zone.FileParser.parse(zone_content)
      iex> length(zone.records)
      5
      iex> zone.origin
      "example.com"
  """
  @spec parse(String.t()) :: {:ok, zone_data()} | {:error, String.t()}
  def parse(content) do
    parse_with_context(content, %{file: "string", line: 0})
  end

  @doc """
  Parse a zone file from a string with detailed error reporting.
  """
  @spec parse_with_context(String.t(), map()) :: {:ok, zone_data()} | {:error, String.t()}
  def parse_with_context(content, context) do
    try do
      zone = parse_zone(content, context)
      validate_zone(zone)
    rescue
      e in RuntimeError -> {:error, e.message}
      e -> {:error, "Parse error: #{inspect(e)}"}
    end
  end

  @doc """
  Parse a zone file from a file path with enhanced error handling and path validation.
  """
  @spec parse_file(String.t()) :: {:ok, zone_data()} | {:error, String.t()}
  def parse_file(file_path) do
    normalized_path = Path.expand(file_path)
    allowed_base = Path.expand(Application.get_env(:dns, :zone_directory, "/var/lib/dns/zones"))

    if String.starts_with?(normalized_path, allowed_base) do
      case File.read(normalized_path) do
        {:ok, content} -> parse_with_context(content, %{file: normalized_path, line: 0})
        {:error, reason} -> {:error, "Failed to read file: #{reason}"}
      end
    else
      {:error, "Path traversal detected - access denied"}
    end
  end

  @doc """
  Generate a zone file string from zone data.
  """
  @spec generate(zone_data()) :: String.t()
  def generate(zone) do
    lines = []

    # Add directives
    lines = if zone.origin, do: ["$ORIGIN #{zone.origin}." | lines], else: lines
    lines = ["$TTL #{zone.ttl}" | lines]

    # Add SOA record if present
    lines =
      if zone.soa do
        soa_lines = generate_soa_record(zone.soa)
        [soa_lines | lines]
      else
        lines
      end

    # Add other records
    record_lines =
      zone.records
      |> Enum.sort_by(fn rr -> {rr.name, rr.type} end)
      |> Enum.map(&generate_record/1)

    lines = Enum.reverse(lines) ++ record_lines
    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Validate zone data for common issues.
  """
  @spec validate_zone(zone_data()) :: {:ok, zone_data()} | {:error, String.t()}
  def validate_zone(zone) do
    errors = []

    # Check for duplicate records
    errors = validate_duplicate_records(zone.records, errors)

    zone = %{zone | errors: Enum.reverse(errors), warnings: []}

    if Enum.empty?(errors) do
      {:ok, zone}
    else
      {:error, format_errors(errors)}
    end
  end

  defp parse_zone(content, context) do
    lines = preprocess_content(content)

    {zone, _} =
      Enum.reduce(
        Enum.with_index(lines),
        {%{
           origin: nil,
           ttl: 3600,
           soa: nil,
           records: [],
           includes: [],
           directives: [],
           errors: [],
           warnings: []
         }, nil},
        fn {line, line_num}, {zone, prev_name} ->
          parse_line_with_context(line, zone, prev_name, line_num + 1, context)
        end
      )

    zone
  end

  defp preprocess_content(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&remove_comments/1)
    |> Enum.reject(&(&1 == ""))
    |> handle_continuations()
  end

  defp remove_comments(line) do
    case String.split(line, ";", parts: 2) do
      [content, _comment] -> String.trim(content)
      [content] -> content
    end
  end

  defp handle_continuations(lines) do
    lines
    |> Enum.reduce({[], ""}, fn line, {acc, continuation} ->
      full_line = continuation <> line

      if String.ends_with?(full_line, "(") or String.ends_with?(full_line, "\\") do
        {[full_line | acc], ""}
      else
        {[full_line | acc], ""}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_line_with_context(line, zone, prev_name, line_num, context) do
    try do
      cond do
        String.starts_with?(line, "$ORIGIN") ->
          origin = String.trim(String.replace(line, "$ORIGIN", ""))
          directive = %{type: :origin, value: normalize_origin(origin), line: line_num}

          {%{zone | origin: normalize_origin(origin), directives: [directive | zone.directives]},
           prev_name}

        String.starts_with?(line, "$TTL") ->
          ttl_str = String.trim(String.replace(line, "$TTL", ""))

          case Integer.parse(ttl_str) do
            {ttl_value, _} ->
              directive = %{type: :ttl, value: ttl_value, line: line_num}
              {%{zone | ttl: ttl_value, directives: [directive | zone.directives]}, prev_name}

            _ ->
              error = %{line: line_num, message: "Invalid TTL value: #{ttl_str}", context: line}
              {%{zone | errors: [error | zone.errors]}, prev_name}
          end

        String.starts_with?(line, "$INCLUDE") ->
          include_file = String.trim(String.replace(line, "$INCLUDE", ""))
          directive = %{type: :include, value: include_file, line: line_num}

          {%{
             zone
             | includes: [include_file | zone.includes],
               directives: [directive | zone.directives]
           }, prev_name}

        String.starts_with?(line, "$GENERATE") ->
          directive = %{
            type: :generate,
            value: String.trim(String.replace(line, "$GENERATE", "")),
            line: line_num
          }

          {%{zone | directives: [directive | zone.directives]}, prev_name}

        String.starts_with?(line, "$") ->
          warning = %{line: line_num, message: "Unknown directive: #{line}", context: line}
          {%{zone | warnings: [warning | zone.warnings]}, prev_name}

        true ->
          parse_record_line_with_context(line, zone, prev_name, line_num, context)
      end
    rescue
      e ->
        error = %{line: line_num, message: "Parse error: #{inspect(e)}", context: line}
        {%{zone | errors: [error | zone.errors]}, prev_name}
    end
  end

  defp parse_record_line_with_context(line, zone, prev_name, line_num, _context) do
    parts = String.split(line, ~r/\s+/, trim: true)

    case parts do
      [] ->
        {zone, prev_name}

      [name | rest] ->
        name =
          if name == "@" do
            zone.origin || "@"
          else
            name
          end

        case rest do
          [ttl_str, class, type | data] ->
            case Integer.parse(ttl_str) do
              {ttl, _} ->
                parse_record(zone, name, ttl, class, type, Enum.join(data, " "), name)

              _ ->
                # ttl_str is not a number, treat as class
                parse_record(
                  zone,
                  name,
                  zone.ttl,
                  ttl_str,
                  class,
                  Enum.join([type | data], " "),
                  name
                )
            end

          [class, type | data] when class in ["IN", "CH", "HS", "NONE", "ANY"] ->
            parse_record(zone, name, zone.ttl, class, type, Enum.join(data, " "), name)

          [type | data] ->
            parse_record(
              zone,
              name,
              zone.ttl,
              "IN",
              type,
              Enum.join(data, " "),
              name
            )

          _ ->
            error = %{line: line_num, message: "Invalid record format", context: line}
            {%{zone | errors: [error | zone.errors]}, prev_name}
        end
    end
  end

  defp parse_record(zone, name, ttl_str, _class, type_str, data_str, prev_name) do
    {ttl, _} = Integer.parse(to_string(ttl_str))

    output =
      case String.upcase(type_str) do
        "A" -> {:ok, :a}
        "AAAA" -> {:ok, :aaaa}
        "CNAME" -> {:ok, :cname}
        "MX" -> {:ok, :mx}
        "NS" -> {:ok, :ns}
        "TXT" -> {:ok, :txt}
        "SOA" -> {:ok, :soa}
        "PTR" -> {:ok, :ptr}
        "SRV" -> {:ok, :srv}
        "CAA" -> {:ok, :caa}
        "TLSA" -> {:ok, :tlsa}
        "DNSKEY" -> {:ok, :dnskey}
        "DS" -> {:ok, :ds}
        "RRSIG" -> {:ok, :rrsig}
        "NSEC" -> {:ok, :nsec}
        "NSEC3" -> {:ok, :nsec3}
        "NSEC3PARAM" -> {:ok, :nsec3param}
        "HTTPS" -> {:ok, :https}
        "SVCB" -> {:ok, :svcb}
        _ -> {:error, :unknown_type}
      end

    case output do
      {:ok, :soa} ->
        record_data = parse_record_data(:soa, String.trim(data_str))
        {%{zone | soa: record_data}, prev_name}

      {:ok, type} ->
        record_data = parse_record_data(type, String.trim(data_str))
        full_name = expand_name(name, zone.origin)

        rr_set = RRSet.new(full_name, type, [record_data], ttl: ttl)

        {%{zone | records: [rr_set | zone.records]}, prev_name}

      _ ->
        {zone, prev_name}
    end
  end

  defp parse_record_data(type, data_str) do
    case type do
      :soa ->
        parse_soa_data(data_str)

      :a ->
        parse_a_data(data_str)

      :aaaa ->
        parse_aaaa_data(data_str)

      :cname ->
        parse_cname_data(data_str)

      :mx ->
        parse_mx_data(data_str)

      :ns ->
        parse_ns_data(data_str)

      :txt ->
        parse_txt_data(data_str)

      :srv ->
        parse_srv_data(data_str)

      :ptr ->
        parse_ptr_data(data_str)

      :caa ->
        parse_caa_data(data_str)

      :tlsa ->
        parse_tlsa_data(data_str)

      :dnskey ->
        parse_dnskey_data(data_str)

      :ds ->
        parse_ds_data(data_str)

      :rrsig ->
        parse_rrsig_data(data_str)

      :nsec ->
        parse_nsec_data(data_str)

      :nsec3 ->
        parse_nsec3_data(data_str)

      :nsec3param ->
        parse_nsec3param_data(data_str)

      :https ->
        parse_https_data(data_str)

      :svcb ->
        parse_svcb_data(data_str)

      _ ->
        %{type: type, data: data_str}
    end
  end

  defp parse_soa_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    if length(parts) >= 7 do
      %{
        type: :soa,
        mname: Enum.at(parts, 0),
        rname: Enum.at(parts, 1),
        serial: parse_integer_param(Enum.at(parts, 2)),
        refresh: parse_integer_param(Enum.at(parts, 3)),
        retry: parse_integer_param(Enum.at(parts, 4)),
        expire: parse_integer_param(Enum.at(parts, 5)),
        minimum: parse_integer_param(Enum.at(parts, 6))
      }
    else
      %{type: :soa, data: data_str}
    end
  end

  defp parse_a_data(data_str) do
    %{type: :a, address: String.trim(data_str)}
  end

  defp parse_aaaa_data(data_str) do
    %{type: :aaaa, address: String.trim(data_str)}
  end

  defp parse_cname_data(data_str) do
    %{type: :cname, cname: String.trim(data_str)}
  end

  defp parse_ns_data(data_str) do
    %{type: :ns, nsdname: String.trim(data_str)}
  end

  defp parse_mx_data(data_str) do
    case String.split(data_str, ~r/\s+/, trim: true) do
      [preference, exchange] ->
        %{type: :mx, preference: String.to_integer(preference), exchange: exchange}

      _ ->
        %{type: :mx, data: data_str}
    end
  end

  defp parse_txt_data(data_str) do
    txt_data =
      String.trim(data_str)
      |> String.trim("\"")
      |> String.trim("'")

    %{type: :txt, txtdata: txt_data}
  end

  defp parse_srv_data(data_str) do
    case String.split(data_str, ~r/\s+/, trim: true) do
      [priority, weight, port, target] ->
        %{
          type: :srv,
          priority: String.to_integer(priority),
          weight: String.to_integer(weight),
          port: String.to_integer(port),
          target: target
        }

      _ ->
        %{type: :srv, data: data_str}
    end
  end

  defp parse_ptr_data(data_str) do
    %{type: :ptr, ptrdname: String.trim(data_str)}
  end

  defp parse_integer_param(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {int, _} -> int
      _ -> 0
    end
  end

  defp expand_name(name, origin) when is_binary(name) do
    cond do
      String.ends_with?(name, ".") -> String.trim_trailing(name, ".")
      name == "@" -> origin || "@"
      origin && origin != "@" && !String.contains?(name, ".") -> "#{name}.#{origin}"
      origin && origin != "@" -> name
      true -> name
    end
  end

  defp expand_name(name, _origin), do: name

  defp normalize_origin(origin) do
    String.trim_trailing(origin, ".")
  end

  # Enhanced record data parsers
  defp parse_caa_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [flags, tag, value] ->
        %{type: :caa, flags: String.to_integer(flags), tag: tag, value: String.trim(value, "\"")}

      _ ->
        %{type: :caa, data: data_str}
    end
  end

  defp parse_tlsa_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [usage, selector, matching_type, certificate] ->
        %{
          type: :tlsa,
          usage: String.to_integer(usage),
          selector: String.to_integer(selector),
          matching_type: String.to_integer(matching_type),
          certificate: certificate
        }

      _ ->
        %{type: :tlsa, data: data_str}
    end
  end

  defp parse_dnskey_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [flags, protocol, algorithm, public_key] ->
        %{
          type: :dnskey,
          flags: String.to_integer(flags),
          protocol: String.to_integer(protocol),
          algorithm: String.to_integer(algorithm),
          public_key: public_key
        }

      _ ->
        %{type: :dnskey, data: data_str}
    end
  end

  defp parse_ds_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [key_tag, algorithm, digest_type, digest] ->
        %{
          type: :ds,
          key_tag: String.to_integer(key_tag),
          algorithm: String.to_integer(algorithm),
          digest_type: String.to_integer(digest_type),
          digest: digest
        }

      _ ->
        %{type: :ds, data: data_str}
    end
  end

  defp parse_rrsig_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [
        covered,
        algorithm,
        labels,
        original_ttl,
        expiration,
        inception,
        key_tag,
        signer_name | signature_parts
      ] ->
        signature = Enum.join(signature_parts, " ")

        %{
          type: :rrsig,
          covered: covered,
          algorithm: String.to_integer(algorithm),
          labels: String.to_integer(labels),
          original_ttl: String.to_integer(original_ttl),
          expiration: String.to_integer(expiration),
          inception: String.to_integer(inception),
          key_tag: String.to_integer(key_tag),
          signer_name: signer_name,
          signature: signature
        }

      _ ->
        %{type: :rrsig, data: data_str}
    end
  end

  defp parse_nsec_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [next_domain_name | types] ->
        %{type: :nsec, next_domain_name: next_domain_name, types: types}

      _ ->
        %{type: :nsec, data: data_str}
    end
  end

  defp parse_nsec3_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [hash_algorithm, flags, iterations, salt, next_hashed_owner_name | types] ->
        %{
          type: :nsec3,
          hash_algorithm: String.to_integer(hash_algorithm),
          flags: String.to_integer(flags),
          iterations: String.to_integer(iterations),
          salt: salt,
          next_hashed_owner_name: next_hashed_owner_name,
          types: types
        }

      _ ->
        %{type: :nsec3, data: data_str}
    end
  end

  defp parse_nsec3param_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [hash_algorithm, flags, iterations, salt] ->
        %{
          type: :nsec3param,
          hash_algorithm: String.to_integer(hash_algorithm),
          flags: String.to_integer(flags),
          iterations: String.to_integer(iterations),
          salt: salt
        }

      _ ->
        %{type: :nsec3param, data: data_str}
    end
  end

  defp parse_https_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [priority, target | params] ->
        %{
          type: :https,
          priority: String.to_integer(priority),
          target: target,
          params: Enum.join(params, " ")
        }

      _ ->
        %{type: :https, data: data_str}
    end
  end

  defp parse_svcb_data(data_str) do
    parts = String.split(data_str, ~r/\s+/, trim: true)

    case parts do
      [priority, target | params] ->
        %{
          type: :svcb,
          priority: String.to_integer(priority),
          target: target,
          params: Enum.join(params, " ")
        }

      _ ->
        %{type: :svcb, data: data_str}
    end
  end

  # defp validate_soa(soa, errors) do
  #   cond do
  #     !soa.mname || !soa.rname ->
  #       [
  #         %{line: 0, message: "SOA record missing mname or rname", context: "SOA validation"}
  #         | errors
  #       ]
  #
  #     soa.serial == 0 ->
  #       [
  #         %{
  #           line: 0,
  #           message: "SOA serial is 0, may indicate testing zone",
  #           context: "SOA validation"
  #         }
  #         | errors
  #       ]
  #
  #     true ->
  #       errors
  #   end
  # end

  defp validate_duplicate_records(records, errors) do
    duplicates =
      records
      |> Enum.group_by(fn rr -> {rr.name, rr.type, rr.data} end)
      |> Enum.filter(fn {_, records} -> length(records) > 1 end)
      |> Enum.map(fn {{name, type, data}, _records} ->
        %{
          line: 0,
          message: "Duplicate record: #{name} #{type} #{inspect(data)}",
          context: "record validation"
        }
      end)

    errors ++ duplicates
  end

  defp format_errors(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map(fn error ->
      "Line #{error.line}: #{error.message} (#{error.context})"
    end)
    |> Enum.join("\n")
  end

  defp generate_soa_record(soa) do
    lines = [
      "@ IN SOA #{soa.mname}. #{soa.rname}. (",
      "    #{soa.serial} ; Serial",
      "    #{soa.refresh} ; Refresh",
      "    #{soa.retry} ; Retry",
      "    #{soa.expire} ; Expire",
      "    #{soa.minimum} ) ; Minimum TTL"
    ]

    Enum.join(lines, "\n")
  end

  defp generate_record(rr) do
    data_str = generate_record_data(rr.data)
    ttl_str = if rr.ttl > 0, do: String.pad_leading(to_string(rr.ttl), 5), else: "    "
    name = if rr.name, do: rr.name, else: "@"
    name_str = String.pad_trailing(name, 20)
    "#{name_str}#{ttl_str}    IN    #{String.upcase(to_string(rr.type))}    #{data_str}"
  end

  defp generate_record_data(data) do
    case data do
      %{type: :a, address: address} ->
        address

      %{type: :aaaa, address: address} ->
        address

      %{type: :cname, cname: cname} ->
        cname

      %{type: :ns, nsdname: nsdname} ->
        nsdname

      %{type: :mx, preference: preference, exchange: exchange} ->
        "#{preference} #{exchange}"

      %{type: :txt, txtdata: txtdata} ->
        "\"#{txtdata}\""

      %{type: :srv, priority: priority, weight: weight, port: port, target: target} ->
        "#{priority} #{weight} #{port} #{target}"

      %{type: :ptr, ptrdname: ptrdname} ->
        ptrdname

      %{type: :caa, flags: flags, tag: tag, value: value} ->
        "#{flags} #{tag} \"#{value}\""

      %{
        type: :tlsa,
        usage: usage,
        selector: selector,
        matching_type: matching_type,
        certificate: certificate
      } ->
        "#{usage} #{selector} #{matching_type} #{certificate}"

      %{
        type: :dnskey,
        flags: flags,
        protocol: protocol,
        algorithm: algorithm,
        public_key: public_key
      } ->
        "#{flags} #{protocol} #{algorithm} #{public_key}"

      %{
        type: :ds,
        key_tag: key_tag,
        algorithm: algorithm,
        digest_type: digest_type,
        digest: digest
      } ->
        "#{key_tag} #{algorithm} #{digest_type} #{digest}"

      %{type: :rrsig, signature: signature} ->
        signature

      %{type: :nsec, next_domain_name: next_domain_name, types: types} ->
        "#{next_domain_name} #{Enum.join(types, " ")}"

      %{
        type: :nsec3,
        hash_algorithm: hash_algorithm,
        flags: flags,
        iterations: iterations,
        salt: salt,
        next_hashed_owner_name: next_hashed_owner_name,
        types: types
      } ->
        "#{hash_algorithm} #{flags} #{iterations} #{salt} #{next_hashed_owner_name} #{Enum.join(types, " ")}"

      %{
        type: :nsec3param,
        hash_algorithm: hash_algorithm,
        flags: flags,
        iterations: iterations,
        salt: salt
      } ->
        "#{hash_algorithm} #{flags} #{iterations} #{salt}"

      %{type: :https, priority: priority, target: target, params: params} ->
        format_svcb_params(priority, target, params)

      %{type: :svcb, priority: priority, target: target, params: params} ->
        format_svcb_params(priority, target, params)

      _ ->
        inspect(data)
    end
  end

  defp format_svcb_params(priority, target, params) do
    target_str = if target == ".", do: ".", else: target
    params_str = if params == "" or params == nil, do: "", else: " #{format_svc_params(params)}"
    "#{priority} #{target_str}#{params_str}"
  end

  defp format_svc_params(params) when is_binary(params) do
    params
    |> String.replace("alpn=", "alpn=\"")
    |> String.replace(" ipv4hint=", "\" ipv4hint=")
    |> String.replace(" ipv6hint=", "\" ipv6hint=")
    |> String.replace(" port=", "\" port=")
    |> then(fn str ->
      if String.contains?(str, "alpn=\"") and not String.ends_with?(str, "\"") do
        str <> "\""
      else
        str
      end
    end)
  end

  defp format_svc_params(params), do: inspect(params)
end
