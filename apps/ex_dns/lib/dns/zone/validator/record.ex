defmodule DNS.Zone.Validator.Record do
  @moduledoc """
  Pure validation functions for individual DNS records.

  All functions take record data and return `{:ok, normalized}` or `{:error, reasons}`.
  These are pure functions with no side effects, making them easy to test.

  ## Supported Record Types

  - A, AAAA - Address records
  - CNAME - Canonical name
  - MX - Mail exchange
  - NS - Nameserver
  - TXT - Text records
  - SRV - Service records
  - PTR - Pointer records
  - CAA - Certificate Authority Authorization

  ## Examples

      iex> DNS.Zone.Validator.Record.validate(:a, %{name: "www", rdata: "192.0.2.1", ttl: 3600})
      {:ok, %{name: "www", type: :a, class: :in, rdata: {192, 0, 2, 1}, ttl: 3600}}

      iex> DNS.Zone.Validator.Record.validate(:a, %{name: "www", rdata: "invalid"})
      {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address: invalid"}]}
  """

  @type validation_error :: %{
          field: atom(),
          code: atom(),
          message: String.t()
        }

  @type validation_result :: {:ok, map()} | {:error, [validation_error()]}

  @max_ttl 2_147_483_647
  @max_label_length 63
  @max_domain_length 253
  @max_txt_string_length 255
  @max_priority 65535
  @max_port 65535

  # ============================================
  # Main Dispatcher
  # ============================================

  @doc """
  Validate a record based on its type.

  ## Parameters
  - `type` - Record type atom (:a, :aaaa, :cname, :mx, :txt, :srv, :ns, :ptr, :caa)
  - `params` - Map with record parameters

  ## Returns
  - `{:ok, validated_record}` on success
  - `{:error, [errors]}` on validation failure
  """
  @spec validate(atom(), map()) :: validation_result()
  def validate(:a, params), do: validate_a(params)
  def validate(:aaaa, params), do: validate_aaaa(params)
  def validate(:cname, params), do: validate_cname(params)
  def validate(:mx, params), do: validate_mx(params)
  def validate(:txt, params), do: validate_txt(params)
  def validate(:srv, params), do: validate_srv(params)
  def validate(:ns, params), do: validate_ns(params)
  def validate(:ptr, params), do: validate_ptr(params)
  def validate(:caa, params), do: validate_caa(params)
  def validate(:soa, params), do: validate_soa(params)

  def validate(type, _params) do
    {:error, [%{field: :type, code: :unsupported, message: "Unsupported record type: #{type}"}]}
  end

  # ============================================
  # A Record
  # ============================================

  @doc """
  Validate an A record.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - IPv4 address as string or tuple (required)
  - `:ttl` - Time to live in seconds (optional, defaults to 3600)

  ## Examples

      iex> validate_a(%{name: "www", rdata: "192.0.2.1", ttl: 3600})
      {:ok, %{name: "www", type: :a, class: :in, rdata: {192, 0, 2, 1}, ttl: 3600}}

      iex> validate_a(%{name: "www", rdata: {10, 0, 0, 1}})
      {:ok, %{name: "www", type: :a, class: :in, rdata: {10, 0, 0, 1}, ttl: 3600}}
  """
  @spec validate_a(map()) :: validation_result()
  def validate_a(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, ip} <- parse_ipv4(params[:rdata]) do
      {:ok, %{name: name, type: :a, class: :in, ttl: ttl, rdata: ip}}
    end
  end

  # ============================================
  # AAAA Record
  # ============================================

  @doc """
  Validate an AAAA record.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - IPv6 address as string or tuple (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_aaaa(%{name: "www", rdata: "2001:db8::1", ttl: 3600})
      {:ok, %{name: "www", type: :aaaa, class: :in, rdata: {8193, 3512, 0, 0, 0, 0, 0, 1}, ttl: 3600}}
  """
  @spec validate_aaaa(map()) :: validation_result()
  def validate_aaaa(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, ip} <- parse_ipv6(params[:rdata]) do
      {:ok, %{name: name, type: :aaaa, class: :in, ttl: ttl, rdata: ip}}
    end
  end

  # ============================================
  # CNAME Record
  # ============================================

  @doc """
  Validate a CNAME record.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - Target domain name (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_cname(%{name: "www", rdata: "web.example.com.", ttl: 3600})
      {:ok, %{name: "www", type: :cname, class: :in, rdata: "web.example.com.", ttl: 3600}}
  """
  @spec validate_cname(map()) :: validation_result()
  def validate_cname(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :rdata) do
      {:ok, %{name: name, type: :cname, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # MX Record
  # ============================================

  @doc """
  Validate an MX record.

  ## Parameters
  - `:name` - Record name (required)
  - `:priority` - Mail server priority 0-65535 (required)
  - `:target` - Mail server hostname (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_mx(%{name: "@", priority: 10, target: "mail.example.com.", ttl: 3600})
      {:ok, %{name: "", type: :mx, class: :in, rdata: {10, "mail.example.com."}, ttl: 3600}}
  """
  @spec validate_mx(map()) :: validation_result()
  def validate_mx(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, priority} <- validate_priority(params[:priority]),
         {:ok, target} <- validate_domain_name(params[:target], :target) do
      {:ok, %{name: name, type: :mx, class: :in, ttl: ttl, rdata: {priority, target}}}
    end
  end

  # ============================================
  # TXT Record
  # ============================================

  @doc """
  Validate a TXT record.

  Each string segment must be max 255 bytes per RFC 1035.
  Long strings are automatically split into 255-byte chunks.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - Text data as string or list of strings (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_txt(%{name: "@", rdata: "v=spf1 include:_spf.google.com ~all", ttl: 3600})
      {:ok, %{name: "", type: :txt, class: :in, rdata: "v=spf1 include:_spf.google.com ~all", ttl: 3600}}
  """
  @spec validate_txt(map()) :: validation_result()
  def validate_txt(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, text} <- validate_txt_data(params[:rdata]) do
      {:ok, %{name: name, type: :txt, class: :in, ttl: ttl, rdata: text}}
    end
  end

  # ============================================
  # SRV Record
  # ============================================

  @doc """
  Validate an SRV record.

  ## Parameters
  - `:name` - Service name in format _service._proto (required)
  - `:priority` - Priority 0-65535 (required)
  - `:weight` - Weight 0-65535 (required)
  - `:port` - Port 0-65535 (required)
  - `:target` - Target hostname (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_srv(%{name: "_http._tcp", priority: 0, weight: 5, port: 443, target: "server.example.com.", ttl: 3600})
      {:ok, %{name: "_http._tcp", type: :srv, class: :in, rdata: {0, 5, 443, "server.example.com."}, ttl: 3600}}
  """
  @spec validate_srv(map()) :: validation_result()
  def validate_srv(params) do
    with {:ok, name} <- validate_srv_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, priority} <- validate_priority(params[:priority]),
         {:ok, weight} <- validate_weight(params[:weight]),
         {:ok, port} <- validate_port(params[:port]),
         {:ok, target} <- validate_domain_name(params[:target], :target) do
      {:ok,
       %{name: name, type: :srv, class: :in, ttl: ttl, rdata: {priority, weight, port, target}}}
    end
  end

  # ============================================
  # NS Record
  # ============================================

  @doc """
  Validate an NS record.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - Nameserver hostname (required)
  - `:ttl` - Time to live in seconds (optional)
  """
  @spec validate_ns(map()) :: validation_result()
  def validate_ns(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :rdata) do
      {:ok, %{name: name, type: :ns, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # PTR Record
  # ============================================

  @doc """
  Validate a PTR record.

  ## Parameters
  - `:name` - Record name (required)
  - `:rdata` - Target domain name (required)
  - `:ttl` - Time to live in seconds (optional)
  """
  @spec validate_ptr(map()) :: validation_result()
  def validate_ptr(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, target} <- validate_domain_name(params[:rdata], :rdata) do
      {:ok, %{name: name, type: :ptr, class: :in, ttl: ttl, rdata: target}}
    end
  end

  # ============================================
  # CAA Record
  # ============================================

  @doc """
  Validate a CAA record.

  ## Parameters
  - `:name` - Record name (required)
  - `:flags` - Flags 0-255 (optional, defaults to 0)
  - `:tag` - Tag: "issue", "issuewild", or "iodef" (required)
  - `:value` - Value string (required)
  - `:ttl` - Time to live in seconds (optional)

  ## Examples

      iex> validate_caa(%{name: "@", tag: "issue", value: "letsencrypt.org", ttl: 3600})
      {:ok, %{name: "", type: :caa, class: :in, rdata: {0, "issue", "letsencrypt.org"}, ttl: 3600}}
  """
  @spec validate_caa(map()) :: validation_result()
  def validate_caa(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, flags} <- validate_caa_flags(params[:flags]),
         {:ok, tag} <- validate_caa_tag(params[:tag]),
         {:ok, value} <- validate_caa_value(params[:value]) do
      {:ok, %{name: name, type: :caa, class: :in, ttl: ttl, rdata: {flags, tag, value}}}
    end
  end

  # ============================================
  # SOA Record
  # ============================================

  @doc """
  Validate an SOA record.

  ## Parameters
  - `:name` - Record name, typically zone apex (required)
  - `:mname` - Primary nameserver (required)
  - `:rname` - Admin email with @ replaced by . (required)
  - `:serial` - Zone serial number (required)
  - `:refresh` - Refresh interval in seconds (required)
  - `:retry` - Retry interval in seconds (required)
  - `:expire` - Expire time in seconds (required)
  - `:minimum` - Minimum/negative TTL in seconds (required)
  - `:ttl` - Record TTL (optional)
  """
  @spec validate_soa(map()) :: validation_result()
  def validate_soa(params) do
    with {:ok, name} <- validate_name(params[:name]),
         {:ok, ttl} <- validate_ttl(params[:ttl]),
         {:ok, mname} <- validate_domain_name(params[:mname], :mname),
         {:ok, rname} <- validate_domain_name(params[:rname], :rname),
         {:ok, serial} <- validate_serial(params[:serial]),
         {:ok, refresh} <- validate_soa_timer(params[:refresh], :refresh),
         {:ok, retry} <- validate_soa_timer(params[:retry], :retry),
         {:ok, expire} <- validate_soa_timer(params[:expire], :expire),
         {:ok, minimum} <- validate_soa_timer(params[:minimum], :minimum) do
      rdata = %{
        mname: mname,
        rname: rname,
        serial: serial,
        refresh: refresh,
        retry: retry,
        expire: expire,
        minimum: minimum
      }

      {:ok, %{name: name, type: :soa, class: :in, ttl: ttl, rdata: rdata}}
    end
  end

  # ============================================
  # Common Validators
  # ============================================

  @doc false
  def validate_name(nil), do: {:ok, ""}
  def validate_name(""), do: {:ok, ""}
  def validate_name("@"), do: {:ok, ""}

  def validate_name(name) when is_binary(name) do
    # Normalize: trim trailing dot for internal storage
    normalized = String.trim_trailing(name, ".")

    cond do
      String.length(normalized) > @max_domain_length ->
        {:error,
         [
           %{
             field: :name,
             code: :too_long,
             message: "Domain name too long (max #{@max_domain_length} characters)"
           }
         ]}

      not valid_domain_labels?(normalized) ->
        {:error,
         [%{field: :name, code: :invalid_label, message: "Invalid domain name label in: #{name}"}]}

      true ->
        {:ok, normalized}
    end
  end

  def validate_name(_) do
    {:error, [%{field: :name, code: :invalid, message: "Name must be a string"}]}
  end

  @doc false
  def validate_ttl(nil), do: {:ok, 3600}

  def validate_ttl(ttl) when is_integer(ttl) and ttl >= 0 and ttl <= @max_ttl do
    {:ok, ttl}
  end

  def validate_ttl(ttl) when is_integer(ttl) do
    {:error,
     [%{field: :ttl, code: :out_of_range, message: "TTL must be between 0 and #{@max_ttl}"}]}
  end

  def validate_ttl(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} when n >= 0 and n <= @max_ttl ->
        {:ok, n}

      {_, ""} ->
        {:error, [%{field: :ttl, code: :out_of_range, message: "TTL out of valid range"}]}

      _ ->
        {:error, [%{field: :ttl, code: :invalid, message: "TTL must be a number"}]}
    end
  end

  def validate_ttl(_) do
    {:error, [%{field: :ttl, code: :invalid, message: "Invalid TTL format"}]}
  end

  # ============================================
  # IPv4/IPv6 Parsing
  # ============================================

  defp parse_ipv4(ip) when is_tuple(ip) and tuple_size(ip) == 4 do
    octets = Tuple.to_list(ip)

    if Enum.all?(octets, &(is_integer(&1) and &1 >= 0 and &1 <= 255)) do
      {:ok, ip}
    else
      {:error,
       [%{field: :rdata, code: :invalid_ipv4, message: "IPv4 octets must be between 0 and 255"}]}
    end
  end

  defp parse_ipv4(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, {a, b, c, d}} ->
        {:ok, {a, b, c, d}}

      _ ->
        {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address: #{ip}"}]}
    end
  end

  defp parse_ipv4(nil) do
    {:error, [%{field: :rdata, code: :required, message: "IP address is required"}]}
  end

  defp parse_ipv4(_) do
    {:error, [%{field: :rdata, code: :invalid_ipv4, message: "Invalid IPv4 address format"}]}
  end

  defp parse_ipv6(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    segments = Tuple.to_list(ip)

    if Enum.all?(segments, &(is_integer(&1) and &1 >= 0 and &1 <= 0xFFFF)) do
      {:ok, ip}
    else
      {:error,
       [
         %{
           field: :rdata,
           code: :invalid_ipv6,
           message: "IPv6 segments must be between 0 and 65535"
         }
       ]}
    end
  end

  defp parse_ipv6(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, {a, b, c, d, e, f, g, h}} ->
        {:ok, {a, b, c, d, e, f, g, h}}

      _ ->
        {:error, [%{field: :rdata, code: :invalid_ipv6, message: "Invalid IPv6 address: #{ip}"}]}
    end
  end

  defp parse_ipv6(nil) do
    {:error, [%{field: :rdata, code: :required, message: "IPv6 address is required"}]}
  end

  defp parse_ipv6(_) do
    {:error, [%{field: :rdata, code: :invalid_ipv6, message: "Invalid IPv6 address format"}]}
  end

  # ============================================
  # Domain Name Validation
  # ============================================

  defp validate_domain_name(nil, field) do
    {:error, [%{field: field, code: :required, message: "#{field} is required"}]}
  end

  defp validate_domain_name(name, field) when is_binary(name) do
    # Normalize and validate
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, [%{field: field, code: :required, message: "#{field} is required"}]}

      String.length(trimmed) > @max_domain_length + 1 ->
        {:error, [%{field: field, code: :too_long, message: "Domain name too long"}]}

      not valid_domain_labels?(String.trim_trailing(trimmed, ".")) ->
        {:error, [%{field: field, code: :invalid_label, message: "Invalid domain name: #{name}"}]}

      true ->
        # Ensure trailing dot for FQDN
        {:ok, ensure_fqdn(trimmed)}
    end
  end

  defp validate_domain_name(_, field) do
    {:error, [%{field: field, code: :invalid, message: "Invalid #{field} format"}]}
  end

  defp valid_domain_labels?(name) do
    labels = String.split(name, ".")

    # Only allow empty label at the end (for trailing dot) or if single label
    labels
    |> Enum.with_index()
    |> Enum.all?(fn {label, index} ->
      cond do
        # Empty label is only valid at the end (trailing dot)
        label == "" ->
          index == length(labels) - 1

        # Check label length
        byte_size(label) > @max_label_length ->
          false

        # Allow underscore-prefixed labels (for SRV records)
        String.starts_with?(label, "_") ->
          true

        # Normal label: starts and ends with alphanumeric, may contain hyphens
        true ->
          label =~ ~r/^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$/
      end
    end)
  end

  defp ensure_fqdn(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end

  # ============================================
  # Priority/Weight/Port Validators
  # ============================================

  defp validate_priority(nil) do
    {:error, [%{field: :priority, code: :required, message: "Priority is required"}]}
  end

  defp validate_priority(p) when is_integer(p) and p >= 0 and p <= @max_priority do
    {:ok, p}
  end

  defp validate_priority(p) when is_integer(p) do
    {:error,
     [
       %{
         field: :priority,
         code: :out_of_range,
         message: "Priority must be between 0 and #{@max_priority}"
       }
     ]}
  end

  defp validate_priority(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n >= 0 and n <= @max_priority ->
        {:ok, n}

      {_, ""} ->
        {:error, [%{field: :priority, code: :out_of_range, message: "Priority out of range"}]}

      _ ->
        {:error, [%{field: :priority, code: :invalid, message: "Priority must be a number"}]}
    end
  end

  defp validate_priority(_) do
    {:error, [%{field: :priority, code: :invalid, message: "Invalid priority format"}]}
  end

  defp validate_weight(nil) do
    {:error, [%{field: :weight, code: :required, message: "Weight is required"}]}
  end

  defp validate_weight(w) when is_integer(w) and w >= 0 and w <= @max_priority do
    {:ok, w}
  end

  defp validate_weight(w) when is_integer(w) do
    {:error,
     [
       %{
         field: :weight,
         code: :out_of_range,
         message: "Weight must be between 0 and #{@max_priority}"
       }
     ]}
  end

  defp validate_weight(w) when is_binary(w) do
    case Integer.parse(w) do
      {n, ""} when n >= 0 and n <= @max_priority ->
        {:ok, n}

      {_, ""} ->
        {:error, [%{field: :weight, code: :out_of_range, message: "Weight out of range"}]}

      _ ->
        {:error, [%{field: :weight, code: :invalid, message: "Weight must be a number"}]}
    end
  end

  defp validate_weight(_) do
    {:error, [%{field: :weight, code: :invalid, message: "Invalid weight format"}]}
  end

  defp validate_port(nil) do
    {:error, [%{field: :port, code: :required, message: "Port is required"}]}
  end

  defp validate_port(p) when is_integer(p) and p >= 0 and p <= @max_port do
    {:ok, p}
  end

  defp validate_port(p) when is_integer(p) do
    {:error,
     [%{field: :port, code: :out_of_range, message: "Port must be between 0 and #{@max_port}"}]}
  end

  defp validate_port(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n >= 0 and n <= @max_port -> {:ok, n}
      {_, ""} -> {:error, [%{field: :port, code: :out_of_range, message: "Port out of range"}]}
      _ -> {:error, [%{field: :port, code: :invalid, message: "Port must be a number"}]}
    end
  end

  defp validate_port(_) do
    {:error, [%{field: :port, code: :invalid, message: "Invalid port format"}]}
  end

  # ============================================
  # SRV Name Validation
  # ============================================

  defp validate_srv_name(nil) do
    {:error, [%{field: :name, code: :required, message: "SRV name is required"}]}
  end

  defp validate_srv_name(name) when is_binary(name) do
    if String.starts_with?(name, "_") do
      {:ok, name}
    else
      {:error,
       [
         %{
           field: :name,
           code: :invalid_srv_name,
           message: "SRV name must start with underscore (_service._proto)"
         }
       ]}
    end
  end

  defp validate_srv_name(_) do
    {:error, [%{field: :name, code: :invalid, message: "Invalid SRV name format"}]}
  end

  # ============================================
  # TXT Data Validation
  # ============================================

  defp validate_txt_data(nil) do
    {:error, [%{field: :rdata, code: :required, message: "TXT data is required"}]}
  end

  defp validate_txt_data(data) when is_binary(data) do
    if byte_size(data) <= @max_txt_string_length do
      {:ok, data}
    else
      # Split into 255-byte chunks
      chunks = chunk_binary(data, @max_txt_string_length)
      {:ok, chunks}
    end
  end

  defp validate_txt_data(data) when is_list(data) do
    if Enum.all?(data, &(is_binary(&1) and byte_size(&1) <= @max_txt_string_length)) do
      {:ok, data}
    else
      {:error,
       [
         %{
           field: :rdata,
           code: :txt_too_long,
           message: "Each TXT string must be max #{@max_txt_string_length} bytes"
         }
       ]}
    end
  end

  defp validate_txt_data(_) do
    {:error, [%{field: :rdata, code: :invalid, message: "Invalid TXT data format"}]}
  end

  defp chunk_binary(binary, chunk_size) do
    do_chunk_binary(binary, chunk_size, [])
  end

  defp do_chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(binary, chunk_size, acc) when byte_size(binary) <= chunk_size do
    Enum.reverse([binary | acc])
  end

  defp do_chunk_binary(binary, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = binary
    do_chunk_binary(rest, chunk_size, [chunk | acc])
  end

  # ============================================
  # CAA Validators
  # ============================================

  defp validate_caa_flags(nil), do: {:ok, 0}

  defp validate_caa_flags(f) when is_integer(f) and f >= 0 and f <= 255 do
    {:ok, f}
  end

  defp validate_caa_flags(f) when is_integer(f) do
    {:error, [%{field: :flags, code: :out_of_range, message: "CAA flags must be 0-255"}]}
  end

  defp validate_caa_flags(f) when is_binary(f) do
    case Integer.parse(f) do
      {n, ""} when n >= 0 and n <= 255 -> {:ok, n}
      _ -> {:error, [%{field: :flags, code: :invalid, message: "CAA flags must be 0-255"}]}
    end
  end

  defp validate_caa_flags(_) do
    {:error, [%{field: :flags, code: :invalid, message: "Invalid CAA flags format"}]}
  end

  @valid_caa_tags ["issue", "issuewild", "iodef"]

  defp validate_caa_tag(nil) do
    {:error, [%{field: :tag, code: :required, message: "CAA tag is required"}]}
  end

  defp validate_caa_tag(tag) when tag in @valid_caa_tags do
    {:ok, tag}
  end

  defp validate_caa_tag(tag) when is_binary(tag) do
    {:error,
     [
       %{
         field: :tag,
         code: :invalid_tag,
         message: "CAA tag must be one of: #{Enum.join(@valid_caa_tags, ", ")}"
       }
     ]}
  end

  defp validate_caa_tag(_) do
    {:error, [%{field: :tag, code: :invalid, message: "Invalid CAA tag format"}]}
  end

  defp validate_caa_value(nil) do
    {:error, [%{field: :value, code: :required, message: "CAA value is required"}]}
  end

  defp validate_caa_value(v) when is_binary(v) and byte_size(v) > 0 do
    {:ok, v}
  end

  defp validate_caa_value("") do
    {:error, [%{field: :value, code: :required, message: "CAA value cannot be empty"}]}
  end

  defp validate_caa_value(_) do
    {:error, [%{field: :value, code: :invalid, message: "Invalid CAA value format"}]}
  end

  # ============================================
  # SOA Validators
  # ============================================

  defp validate_serial(nil) do
    {:error, [%{field: :serial, code: :required, message: "SOA serial is required"}]}
  end

  defp validate_serial(s) when is_integer(s) and s >= 0 and s <= 4_294_967_295 do
    {:ok, s}
  end

  defp validate_serial(s) when is_integer(s) do
    {:error, [%{field: :serial, code: :out_of_range, message: "Serial must be 0 to 4294967295"}]}
  end

  defp validate_serial(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 and n <= 4_294_967_295 -> {:ok, n}
      _ -> {:error, [%{field: :serial, code: :invalid, message: "Invalid serial number"}]}
    end
  end

  defp validate_serial(_) do
    {:error, [%{field: :serial, code: :invalid, message: "Invalid serial format"}]}
  end

  defp validate_soa_timer(nil, field) do
    {:error, [%{field: field, code: :required, message: "SOA #{field} is required"}]}
  end

  defp validate_soa_timer(t, _field) when is_integer(t) and t >= 0 and t <= @max_ttl do
    {:ok, t}
  end

  defp validate_soa_timer(t, field) when is_integer(t) do
    {:error, [%{field: field, code: :out_of_range, message: "#{field} out of valid range"}]}
  end

  defp validate_soa_timer(t, field) when is_binary(t) do
    case Integer.parse(t) do
      {n, ""} when n >= 0 and n <= @max_ttl -> {:ok, n}
      _ -> {:error, [%{field: field, code: :invalid, message: "Invalid #{field} value"}]}
    end
  end

  defp validate_soa_timer(_, field) do
    {:error, [%{field: field, code: :invalid, message: "Invalid #{field} format"}]}
  end
end
