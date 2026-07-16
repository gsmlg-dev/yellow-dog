defmodule YellowDog.Server.Control.Result do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @max_depth 8
  @max_integer 9_223_372_036_854_775_807
  @identifier_delimiter ~r/[^a-z0-9]+/u
  @bearer_credential ~r/\A[A-Za-z0-9._~+\/=\-]{4,}\z/u
  @safe_setting_reference_suffixes ~w(_ref _id _uri _url _digest _hash)
  @sensitive_identifiers MapSet.new(
                           ~w(password passwd passphrase token secret authorization credential private signing bearer apikey accesstoken authtoken clientsecret)
                         )
  @sensitive_identifier_suffixes ~w(
                                   password passwd passphrase token secret credential bearer authorization
                                   apikey privatekey secretkey signingkey tlskey
                                 )
  @tls_material_tokens MapSet.new(~w(key private secret cert certificate pem pkcs12 pfx))
  @redacted_setting_value %{"type" => "string", "value" => "[redacted]"}
  @fixed_atoms MapSet.new([
                 :A,
                 :AAAA,
                 :CNAME,
                 :MX,
                 :NS,
                 :PTR,
                 :SRV,
                 :TXT,
                 :activated,
                 :active,
                 :all,
                 :allow,
                 :answered,
                 :apply,
                 :applied,
                 :applying,
                 :approved,
                 :authoritative,
                 :bound,
                 :completed,
                 :deactivated,
                 :default,
                 :degraded,
                 :delivered,
                 :delivery,
                 :deny,
                 :dhcp,
                 :disabled,
                 :discovered,
                 :down,
                 :expired,
                 :failed,
                 :forward,
                 :forwarded,
                 :global,
                 :healthy,
                 :host,
                 :init,
                 :ipv4,
                 :ipv6,
                 :lease_expired,
                 :lease_granted,
                 :lease_released,
                 :lease_renewed,
                 :link,
                 :local,
                 :managed,
                 :missing,
                 :pending,
                 :provider,
                 :rebinding,
                 :refused,
                 :released,
                 :renewing,
                 :requesting,
                 :require_approval,
                 :resolved,
                 :revoked,
                 :rollback,
                 :route53,
                 :rfc2136,
                 :running,
                 :selecting,
                 :snapshot,
                 :standalone,
                 :static,
                 :stopped,
                 :unavailable,
                 :unhealthy,
                 :unknown,
                 :up,
                 :updated,
                 :use_cloud,
                 :use_local,
                 :validation,
                 :cloudflare
               ])

  @spec normalize(term()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(value) do
    with {:ok, normalized} <- normalize_value(value, @max_depth),
         {:ok, encoded} <- Codec.encode(normalized),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, normalized}
    else
      _ -> invalid_error()
    end
  end

  @spec normalize(term(), Operation.t()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(value, %Operation{name: "server.settings.effective.get"}) do
    with {:ok, redacted} <- redact_settings_document(value, @max_depth),
         {:ok, normalized} <- normalize(redacted) do
      {:ok, normalized}
    end
  end

  def normalize(value, %Operation{}), do: normalize(value)
  def normalize(_value, _operation), do: invalid_error()

  defp normalize_value(%DateTime{utc_offset: 0, std_offset: 0} = value, _depth) do
    {:ok, DateTime.to_iso8601(value)}
  end

  defp normalize_value(value, _depth) when is_struct(value), do: invalid_error()

  defp normalize_value(value, _depth) when is_binary(value) do
    normalize_text(value)
  end

  defp normalize_value(value, _depth)
       when is_nil(value) or is_boolean(value),
       do: {:ok, value}

  defp normalize_value(value, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: {:ok, value}

  defp normalize_value(value, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> {:ok, value}
      _ -> invalid_error()
    end
  end

  defp normalize_value(value, _depth) when is_atom(value) do
    if MapSet.member?(@fixed_atoms, value) do
      {:ok, Atom.to_string(value)}
    else
      invalid_error()
    end
  end

  defp normalize_value(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         {:ok, entries} <- normalize_map(value, depth - 1) do
      {:ok, Map.new(entries)}
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(value, depth) when is_list(value) and depth > 0 do
    with {:ok, values} <- Bounds.list(value) do
      normalize_list(values, depth - 1, [])
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(_value, _depth), do: invalid_error()

  defp normalize_map(value, depth) do
    Enum.reduce_while(value, {:ok, %{}, []}, fn {key, nested}, {:ok, seen, entries} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(seen, key),
           {:ok, nested} <- normalize_value(nested, depth) do
        {:cont, {:ok, Map.put(seen, key, true), [{key, nested} | entries]}}
      else
        _ -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, _seen, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      error -> error
    end
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    case normalize_text(key) do
      {:ok, ""} -> invalid_error()
      {:ok, key} -> {:ok, key}
      _ -> invalid_error()
    end
  end

  defp normalize_key(_key), do: invalid_error()

  defp normalize_text(value) do
    with {:ok, value} <- Bounds.message(value),
         false <- sensitive_text?(value) do
      {:ok, value}
    else
      _invalid -> invalid_error()
    end
  end

  defp sensitive_text?(value) do
    case classify_http_uri(value) do
      :credentialed -> true
      :safe -> secret_diagnostic?(value)
      :not_http -> secret_diagnostic?(value) or local_path?(value)
    end
  end

  defp secret_diagnostic?(value) do
    secret_assignment?(value) or bearer_secret?(value)
  end

  defp local_path?(value) do
    downcased = String.downcase(value)

    String.contains?(downcased, "file://") or windows_absolute_path?(value) or
      unix_absolute_path?(value)
  end

  defp classify_http_uri(value) do
    if Regex.match?(~r/\s/u, value) do
      :not_http
    else
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, userinfo: userinfo}
        when is_binary(scheme) and is_binary(host) and host != "" ->
          if String.downcase(scheme) in ["http", "https"] do
            if is_binary(userinfo) and userinfo != "", do: :credentialed, else: :safe
          else
            :not_http
          end

        _uri ->
          :not_http
      end
    end
  end

  defp secret_assignment?(value), do: scan_assignments(value, "", nil)

  defp scan_assignments(<<>>, _current, _pending), do: false

  defp scan_assignments(<<byte, rest::binary>>, current, pending) do
    cond do
      identifier_byte?(byte) ->
        scan_assignments(rest, append_identifier(current, byte), nil)

      ascii_whitespace?(byte) ->
        scan_assignments(rest, "", if(current == "", do: pending, else: current))

      byte in [?:, ?=] ->
        identifier = if current == "", do: pending, else: current
        sensitive_identifier?(identifier) or scan_assignments(rest, "", nil)

      true ->
        scan_assignments(rest, "", nil)
    end
  end

  defp append_identifier(identifier, byte), do: identifier <> <<byte>>

  defp bearer_secret?(value) do
    value
    |> String.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [scheme, credential] ->
      String.downcase(String.trim(scheme, ":")) == "bearer" and
        Regex.match?(@bearer_credential, credential)
    end)
  end

  defp windows_absolute_path?(value) do
    bytes = :binary.bin_to_list(value)
    windows_drive_path?(bytes, true) or windows_unc_path?(bytes, true)
  end

  defp windows_drive_path?([drive, ?:, separator | _rest], boundary?)
       when (drive in ?a..?z or drive in ?A..?Z) and separator in [?/, ?\\] do
    boundary?
  end

  defp windows_drive_path?([byte | rest], _boundary?),
    do: windows_drive_path?(rest, not ascii_alphanumeric?(byte))

  defp windows_drive_path?([], _boundary?), do: false

  defp windows_unc_path?([?\\, ?\\, next | _rest], true)
       when next not in [?\\, ?/, ?\s, ?\t, ?\r, ?\n],
       do: true

  defp windows_unc_path?([byte | rest], _boundary?),
    do: windows_unc_path?(rest, not ascii_alphanumeric?(byte))

  defp windows_unc_path?([], _boundary?), do: false

  defp unix_absolute_path?(value) do
    value
    |> :binary.matches("/")
    |> Enum.any?(fn {index, 1} -> unix_path_at?(value, index) end)
  end

  defp unix_path_at?(value, index) do
    boundary? = index == 0 or not ascii_alphanumeric?(:binary.at(value, index - 1))
    next_index = index + 1

    boundary? and next_index < byte_size(value) and
      not ascii_whitespace?(:binary.at(value, next_index)) and not cidr_at?(value, index)
  end

  defp cidr_at?(value, slash_index) do
    prefix_start = scan_back(value, slash_index - 1)
    prefix = binary_part(value, prefix_start, slash_index - prefix_start)
    {prefix_length, suffix_index} = scan_digits(value, slash_index + 1)

    with {length, ""} <- Integer.parse(prefix_length),
         true <- valid_cidr_suffix?(value, suffix_index),
         {:ok, address} <- :inet.parse_address(String.to_charlist(prefix)) do
      valid_prefix_length?(address, length)
    else
      _ -> false
    end
  end

  defp scan_back(_value, index) when index < 0, do: 0

  defp scan_back(value, index) do
    if ip_character?(:binary.at(value, index)) do
      scan_back(value, index - 1)
    else
      index + 1
    end
  end

  defp scan_digits(value, index), do: scan_digits(value, index, [])

  defp scan_digits(value, index, digits) when index < byte_size(value) do
    byte = :binary.at(value, index)

    if byte in ?0..?9 do
      scan_digits(value, index + 1, [byte | digits])
    else
      {digits |> Enum.reverse() |> List.to_string(), index}
    end
  end

  defp scan_digits(_value, index, digits),
    do: {digits |> Enum.reverse() |> List.to_string(), index}

  defp valid_cidr_suffix?(value, index) when index == byte_size(value), do: true
  defp valid_cidr_suffix?(value, index), do: not identifier_byte?(:binary.at(value, index))

  defp valid_prefix_length?(address, length) when tuple_size(address) == 4,
    do: length in 0..32

  defp valid_prefix_length?(address, length) when tuple_size(address) == 8,
    do: length in 0..128

  defp valid_prefix_length?(_address, _length), do: false

  defp ip_character?(byte),
    do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F or byte in [?:, ?.]

  defp ascii_alphanumeric?(byte),
    do: byte in ?0..?9 or byte in ?a..?z or byte in ?A..?Z

  defp ascii_whitespace?(byte), do: byte in [?\s, ?\t, ?\r, ?\n]

  defp identifier_byte?(byte),
    do: ascii_alphanumeric?(byte) or byte in [?_, ?-]

  defp redact_settings_document(document, depth) when is_map(document) and depth > 0 do
    with {:ok, _document} <- Bounds.map(document) do
      case fetch_field(document, "entries", :entries) do
        {:ok, field, entries} when is_list(entries) ->
          with {:ok, entries} <- redact_setting_entries(entries, depth - 1) do
            {:ok, Map.put(document, field, entries)}
          end

        _other ->
          {:ok, document}
      end
    else
      _ -> invalid_error()
    end
  end

  defp redact_settings_document(document, _depth), do: {:ok, document}

  defp redact_setting_entries(entries, depth) when depth > 0 do
    with {:ok, entries} <- Bounds.list(entries) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, redacted} ->
        case redact_setting_entry(entry, depth - 1) do
          {:ok, entry} -> {:cont, {:ok, [entry | redacted]}}
          _error -> {:halt, invalid_error()}
        end
      end)
      |> case do
        {:ok, redacted} -> {:ok, Enum.reverse(redacted)}
        error -> error
      end
    else
      _ -> invalid_error()
    end
  end

  defp redact_setting_entries(_entries, _depth), do: invalid_error()

  defp redact_setting_entry(entry, depth) when is_map(entry) and depth > 0 do
    with {:ok, _entry} <- Bounds.map(entry) do
      redact_setting_entry_fields(
        entry,
        fetch_field(entry, "key", :key),
        fetch_field(entry, "value", :value),
        depth
      )
    else
      _ -> invalid_error()
    end
  end

  defp redact_setting_entry(entry, _depth), do: {:ok, entry}

  defp redact_setting_entry_fields(
         entry,
         {:ok, _key_field, key},
         {:ok, value_field, value},
         depth
       )
       when is_binary(key) do
    with {:ok, key} <- Bounds.message(key) do
      if sensitive_setting_key?(key) do
        with :ok <- bounded_raw_shape(value, depth - 1) do
          {:ok, Map.put(entry, value_field, @redacted_setting_value)}
        end
      else
        with {:ok, value} <- redact_setting_value(value, depth - 1) do
          {:ok, Map.put(entry, value_field, value)}
        end
      end
    else
      _ -> invalid_error()
    end
  end

  defp redact_setting_entry_fields(entry, _key, _value, _depth), do: {:ok, entry}

  defp redact_setting_value(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value) do
      case {fetch_field(value, "type", :type), fetch_field(value, "entries", :entries)} do
        {{:ok, _type_field, "object"}, {:ok, entries_field, entries}} when is_list(entries) ->
          with {:ok, entries} <- redact_setting_entries(entries, depth - 1) do
            {:ok, Map.put(value, entries_field, entries)}
          end

        _other ->
          {:ok, value}
      end
    else
      _ -> invalid_error()
    end
  end

  defp redact_setting_value(value, _depth), do: {:ok, value}

  defp fetch_field(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> {:ok, string_key, value}
      :error -> fetch_atom_field(map, atom_key)
    end
  end

  defp fetch_atom_field(map, atom_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> {:ok, atom_key, value}
      :error -> :error
    end
  end

  defp bounded_raw_shape(%DateTime{utc_offset: 0, std_offset: 0}, _depth), do: :ok
  defp bounded_raw_shape(value, _depth) when is_struct(value), do: invalid_error()

  defp bounded_raw_shape(value, _depth) when is_binary(value) do
    case Bounds.message(value) do
      {:ok, _value} -> :ok
      _ -> invalid_error()
    end
  end

  defp bounded_raw_shape(value, _depth) when is_nil(value) or is_boolean(value), do: :ok

  defp bounded_raw_shape(value, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: :ok

  defp bounded_raw_shape(value, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      _ -> invalid_error()
    end
  end

  defp bounded_raw_shape(value, _depth) when is_atom(value) do
    if MapSet.member?(@fixed_atoms, value), do: :ok, else: invalid_error()
  end

  defp bounded_raw_shape(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value) do
      Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
        with :ok <- bounded_raw_key(key),
             :ok <- bounded_raw_shape(nested, depth - 1) do
          {:cont, :ok}
        else
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp bounded_raw_shape(value, depth) when is_list(value) and depth > 0 do
    with {:ok, values} <- Bounds.list(value) do
      Enum.reduce_while(values, :ok, fn nested, :ok ->
        case bounded_raw_shape(nested, depth - 1) do
          :ok -> {:cont, :ok}
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp bounded_raw_shape(_value, _depth), do: invalid_error()

  defp bounded_raw_key(key) when is_atom(key), do: key |> Atom.to_string() |> bounded_raw_key()

  defp bounded_raw_key(key) when is_binary(key) do
    case Bounds.message(key) do
      {:ok, ""} -> invalid_error()
      {:ok, _key} -> :ok
      _ -> invalid_error()
    end
  end

  defp bounded_raw_key(_key), do: invalid_error()

  defp sensitive_setting_key?(key) do
    normalized = String.downcase(key)

    if Enum.any?(@safe_setting_reference_suffixes, &String.ends_with?(normalized, &1)) do
      false
    else
      sensitive_identifier?(normalized)
    end
  end

  defp sensitive_identifier?(identifier) when is_binary(identifier) and identifier != "" do
    tokens = String.split(String.downcase(identifier), @identifier_delimiter, trim: true)
    compact = Enum.join(tokens)

    Enum.any?([compact | tokens], &sensitive_identifier_candidate?/1) or tls_material?(tokens)
  end

  defp sensitive_identifier?(_identifier), do: false

  defp sensitive_identifier_candidate?(candidate) do
    MapSet.member?(@sensitive_identifiers, candidate) or
      Enum.any?(@sensitive_identifier_suffixes, &String.ends_with?(candidate, &1))
  end

  defp tls_material?(tokens) do
    "tls" in tokens and Enum.any?(tokens, &MapSet.member?(@tls_material_tokens, &1))
  end

  defp normalize_list([], _depth, values), do: {:ok, Enum.reverse(values)}

  defp normalize_list([value | rest], depth, values) do
    with {:ok, value} <- normalize_value(value, depth) do
      normalize_list(rest, depth, [value | values])
    end
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
