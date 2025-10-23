defmodule DNS.Zone do
  @moduledoc """
  DNS Zone management and operations.

  This module provides the core DNS zone functionality including zone creation,
  management, validation, zone file parsing, and zone transfers.

  ## Zone Types

  The following zone types are supported:
  - `:authoritative` - Primary authoritative zone with full record management
  - `:stub` - Stub zone containing only NS records for delegation
  - `:forward` - Forward zone redirecting queries to specified servers
  - `:cache` - Cache zone for temporary DNS response caching

  ## Creating Zones

  ### Basic Zone Creation
  ```elixir
  # Create a basic authoritative zone
  zone = DNS.Zone.new("example.com")

  # Create a zone with specific type
  zone = DNS.Zone.new("example.com", :authoritative)

  # Create a zone with options
  zone = DNS.Zone.new("example.com", :authoritative, soa_records: [soa_record])
  ```

  ### Interactive Zone Creation
  ```elixir
  # Create zone with interactive prompts
  {:ok, zone} = DNS.Zone.Editor.create_zone_interactive("example.com")

  # Create zone with initial records
  {:ok, zone} = DNS.Zone.Editor.create_zone_interactive("example.com",
    type: :authoritative,
    soa: [
      mname: "ns1.example.com",
      rname: "admin.example.com",
      serial: 2024010101,
      refresh: 3600,
      retry: 1800,
      expire: 604800,
      minimum: 300
    ],
    ns: ["ns1.example.com", "ns2.example.com"],
    a: ["192.168.1.1"]
  )
  ```

  ## Managing Zone Records

  ### Adding Records
  ```elixir
  # Add an A record
  {:ok, zone} = DNS.Zone.Editor.add_record("example.com", :a,
    name: "www.example.com",
    ip: {192, 168, 1, 100},
    ttl: 300
  )

  # Add an MX record
  {:ok, zone} = DNS.Zone.Editor.add_record("example.com", :mx,
    name: "example.com",
    preference: 10,
    exchange: "mail.example.com"
  )

  # Add a CNAME record
  {:ok, zone} = DNS.Zone.Editor.add_record("example.com", :cname,
    name: "ftp.example.com",
    target: "www.example.com"
  )
  ```

  ### Listing and Searching Records
  ```elixir
  # List all records in a zone
  {:ok, records} = DNS.Zone.Editor.list_records("example.com")

  # Search for specific records
  {:ok, a_records} = DNS.Zone.Editor.search_records("example.com", type: :a)
  {:ok, www_records} = DNS.Zone.Editor.search_records("example.com", name: "www.example.com")
  ```

  ### Updating and Removing Records
  ```elixir
  # Update a record
  {:ok, zone} = DNS.Zone.Editor.update_record(
    "example.com", :a,
    [name: "www.example.com"],
    [ttl: 600]
  )

  # Remove records
  {:ok, zone} = DNS.Zone.Editor.remove_record("example.com", :a, name: "old.example.com")
  ```

  ## Zone Validation

  ### Basic Validation
  ```elixir
  # Validate a zone
  case DNS.Zone.Validator.validate_zone(zone) do
    {:ok, result} ->
      IO.puts("Zone is valid: \#{result.zone_name}")
    {:error, result} ->
      IO.puts("Zone has errors: \#{inspect(result.errors)}")
  end
  ```

  ### Comprehensive Diagnostics
  ```elixir
  # Generate zone diagnostics
  diagnostics = DNS.Zone.Validator.generate_diagnostics(zone)
  IO.inspect(diagnostics.statistics)
  IO.inspect(diagnostics.security_assessment)
  IO.inspect(diagnostics.recommendations)
  ```

  ## Zone File Operations

  ### Parsing Zone Files
  ```elixir
  # Load zone from BIND format file
  {:ok, zone} = DNS.Zone.Loader.load_zone_from_file("example.com", "example.com.zone")

  # Load zone from string
  zone_content = \"\"\"
  $TTL 3600
  $ORIGIN example.com.
  @ IN SOA ns1.example.com. admin.example.com. (
      2024010101 ; serial
      3600       ; refresh
      1800       ; retry
      604800     ; expire
      300        ; minimum
  )
  @ IN NS ns1.example.com.
  @ IN NS ns2.example.com.
  www IN A 192.168.1.100
  mail IN A 192.168.1.200
  \"\"\"
  {:ok, zone} = DNS.Zone.Loader.load_zone_from_string(zone_content)
  ```

  ### Exporting Zone Files
  ```elixir
  # Export to BIND format
  {:ok, bind_content} = DNS.Zone.Editor.export_zone("example.com", format: :bind)
  File.write!("example.com.zone", bind_content)

  # Export to JSON
  {:ok, json_content} = DNS.Zone.Editor.export_zone("example.com", format: :json)
  File.write!("example.com.json", json_content)

  # Export to YAML
  {:ok, yaml_content} = DNS.Zone.Editor.export_zone("example.com", format: :yaml)
  File.write!("example.com.yaml", yaml_content)
  ```

  ## Zone Transfers

  ### Full Zone Transfer (AXFR)
  ```elixir
  # Perform AXFR transfer
  case DNS.Zone.Transfer.axfr("example.com") do
    {:ok, records} ->
      IO.puts("Received \#{length(records)} records via AXFR")
    {:error, reason} ->
      IO.puts("AXFR failed: \#{reason}")
  end
  ```

  ### Incremental Zone Transfer (IXFR)
  ```elixir
  # Perform IXFR transfer
  case DNS.Zone.Transfer.ixfr("example.com", 2024010101) do
    {:ok, changes} ->
      IO.puts("Received \#{length(changes)} changes via IXFR")
    {:error, reason} ->
      IO.puts("IXFR failed: \#{reason}")
  end
  ```

  ### Applying Zone Transfers
  ```elixir
  # Apply transferred zone data
  records = [...] # Records from AXFR/IXFR
  case DNS.Zone.Transfer.apply_transfer("example.com", records, transfer_type: :axfr) do
    {:ok, zone} ->
      IO.puts("Zone updated successfully")
    {:error, reason} ->
      IO.puts("Failed to apply transfer: \#{reason}")
  end
  ```

  ## DNSSEC Management

  ### Enabling DNSSEC
  ```elixir
  # Enable DNSSEC for a zone
  case DNS.Zone.Editor.enable_dnssec("example.com") do
    {:ok, signed_zone} ->
      IO.puts("DNSSEC enabled successfully")
    {:error, reason} ->
      IO.puts("DNSSEC setup failed: \#{reason}")
  end
  ```

  ### Manual DNSSEC Signing
  ```elixir
  # Sign zone with custom options
  case DNS.Zone.DNSSEC.sign_zone(zone,
    algorithm: :rsasha256,
    key_size: 2048,
    nsec3_enabled: true
  ) do
    {:ok, signed_zone} ->
      IO.puts("Zone signed successfully")
    {:error, reason} ->
      IO.puts("Signing failed: \#{reason}")
  end
  ```

  ## Zone Cloning

  ### Clone Zone for Testing
  ```elixir
  # Clone an existing zone
  case DNS.Zone.Editor.clone_zone("production.com", "staging.com") do
    {:ok, cloned_zone} ->
      IO.puts("Zone cloned successfully")
    {:error, reason} ->
      IO.puts("Cloning failed: \#{reason}")
  end
  ```

  ## Examples

  ### Complete Zone Setup
  ```elixir
  # Create a complete zone with all essential records
  {:ok, zone} = DNS.Zone.Editor.create_zone_interactive("company.com",
    type: :authoritative,
    soa: [
      mname: "ns1.company.com",
      rname: "admin.company.com",
      serial: 2024010101,
      refresh: 3600,
      retry: 1800,
      expire: 604800,
      minimum: 300
    ],
    ns: ["ns1.company.com", "ns2.company.com"],
    a: [
      {"@", "192.168.1.10"},
      {"www", "192.168.1.10"},
      {"mail", "192.168.1.20"},
      {"ns1", "192.168.1.1"},
      {"ns2", "192.168.1.2"}
    ],
    mx: [{10, "mail.company.com"}],
    txt: [{"@", "v=spf1 mx ~all"}]
  )

  # Validate the zone
  {:ok, validation} = DNS.Zone.Validator.validate_zone(zone)
  IO.inspect(validation.summary)

  # Export to BIND format
  {:ok, zone_file} = DNS.Zone.Editor.export_zone("company.com", format: :bind)
  File.write!("company.com.zone", zone_file)
  ```
  """

  alias DNS.Zone.Name
  alias DNS.Zone.Parser
  alias DNS.Zone.RRSet

  @type zone_type :: :authoritative | :stub | :forward | :cache

  @type t :: %__MODULE__{
          name: Name.t(),
          type: zone_type(),
          origin: String.t() | nil,
          ttl: integer() | nil,
          soa: map() | nil,
          records: list(RRSet.t()),
          options: list(term()),
          comments: list(String.t())
        }

  defstruct name: Name.new("."),
            type: :authoritative,
            origin: nil,
            ttl: nil,
            soa: nil,
            records: [],
            options: [],
            comments: []

  @spec new(binary() | map(), any()) :: t()
  def new(name, type \\ :authoritative, options \\ [])

  def new(name, type, options) when is_binary(name) do
    new(Name.new(name), type, options)
  end

  def new(name, type, options) when is_struct(name, Name) do
    %__MODULE__{
      name: name,
      type: type,
      options: options
    }
  end

  @spec hostname(Name.t(), DNS.Message.Domain.t()) :: Name.t() | false
  def hostname(%Name{value: "."} = _zone_name, %DNS.Message.Domain{} = domain) do
    Name.from_domain(domain)
  end

  def hostname(%Name{} = zone_name, %DNS.Message.Domain{} = domain) do
    domain_name = Name.from_domain(domain)

    if Name.child?(zone_name, domain_name) do
      domain_name.value
      |> String.trim_trailing(zone_name.value)
      |> Name.new()
    else
      false
    end
  end

  ## Zone File Parsing

  @doc """
  Parse a zone file from a string using the new AST-based parser.

  ## Examples

      iex> zone_content = ""
      ...> $ORIGIN example.com.
      ...> $TTL 3600
      ...> @ IN SOA ns1.example.com. admin.example.com. (
      ...>     2024010101 ; serial
      ...>     3600       ; refresh
      ...>     1800       ; retry
      ...>     604800     ; expire
      ...>     300        ; minimum
      ...> )
      ...> @ IN NS ns1.example.com.
      ...> @ IN NS ns2.example.com.
      ...> www IN A 192.168.1.100
      ...> ""
      iex> {:ok, zone} = DNS.Zone.parse_zone_string(zone_content)
      iex> zone.origin
      "example.com"
      iex> length(zone.records)
      3
  """
  @spec parse_zone_string(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_zone_string(content) do
    case Parser.parse(content) do
      {:ok, ast} ->
        zone = from_ast(ast)
        {:ok, zone}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse a zone file from a file path using the new AST-based parser.

  ## Examples

      iex> {:ok, zone} = DNS.Zone.parse_zone_file("example.com.zone")
      iex> zone.origin
      "example.com"
  """
  @spec parse_zone_file(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_zone_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        parse_zone_string(content)

      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  @doc """
  Convert zone AST to DNS.Zone struct.
  """
  @spec from_ast(Parser.ZoneFile.t()) :: t()
  def from_ast(%Parser.ZoneFile{} = ast) do
    %__MODULE__{
      name: Name.new(ast.origin || "."),
      type: :authoritative,
      origin: ast.origin,
      ttl: ast.ttl,
      comments: ast.comments,
      records: Enum.map(ast.records, &record_from_ast/1)
    }
    |> extract_soa_record()
  end

  @doc """
  Export zone to BIND format string.
  """
  @spec to_bind_format(t()) :: String.t()
  def to_bind_format(%__MODULE__{} = zone) do
    lines = []

    # Add comments at the top
    lines =
      if zone.comments != [] do
        Enum.reduce(zone.comments, lines, fn comment, acc ->
          ["; #{comment}" | acc]
        end)
      else
        lines
      end

    # Add directives
    lines = if zone.origin, do: ["$ORIGIN #{zone.origin}" | lines], else: lines
    lines = if zone.ttl, do: ["$TTL #{zone.ttl}" | lines], else: lines

    # Add SOA record if present
    lines =
      if zone.soa do
        soa_lines = generate_soa_record(zone.soa)
        [soa_lines | lines]
      else
        lines
      end

    # Add other records grouped by type
    record_lines =
      zone.records
      |> Enum.sort_by(fn rr -> {rr.name, rr.type} end)
      |> Enum.map(&generate_bind_record/1)

    lines = Enum.reverse(lines) ++ record_lines
    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Export zone with specified format.

  Supported formats: :bind, :json, :yaml
  """
  @spec export_zone(t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def export_zone(zone, opts \\ []) do
    format = Keyword.get(opts, :format, :bind)

    case format do
      :bind ->
        {:ok, to_bind_format(zone)}

      :json ->
        {:error, "JSON export not implemented"}

      :yaml ->
        {:ok, "# YAML export not implemented yet\n"}

      _ ->
        {:error, "Unsupported format: #{format}"}
    end
  end

  ## Private functions

  defp record_from_ast(%Parser.ResourceRecord{} = record) do
    type = String.downcase(record.type) |> String.to_atom()

    data =
      case type do
        :soa ->
          %{type: :soa, data: record.rdata}

        :a ->
          %{type: :a, address: record.rdata}

        :aaaa ->
          %{type: :aaaa, address: record.rdata}

        :cname ->
          %{type: :cname, cname: record.rdata}

        :ns ->
          %{type: :ns, nsdname: record.rdata}

        :mx ->
          %{type: :mx, preference: record.rdata.priority, exchange: record.rdata.exchange}

        :txt ->
          %{type: :txt, txtdata: record.rdata}

        :srv ->
          %{
            type: :srv,
            priority: record.rdata.priority,
            weight: record.rdata.weight,
            port: record.rdata.port,
            target: record.rdata.target
          }

        _ ->
          %{type: type, data: record.rdata}
      end

    RRSet.new(record.name, type, [data], ttl: record.ttl || 3600)
  end

  defp extract_soa_record(%__MODULE__{records: records} = zone) do
    soa_record = Enum.find(records, fn rr -> rr.type == :soa end)

    if soa_record do
      soa_data = List.first(soa_record.data)
      %{zone | soa: soa_data.data, records: List.delete(records, soa_record)}
    else
      zone
    end
  end

  defp generate_soa_record(%DNS.Zone.Parser.SOARecord{} = soa) do
    primary_ns =
      if String.ends_with?(soa.primary_ns, "."), do: soa.primary_ns, else: soa.primary_ns <> "."

    admin_email =
      if String.ends_with?(soa.admin_email, "."),
        do: soa.admin_email,
        else: soa.admin_email <> "."

    lines = [
      "@ IN SOA #{primary_ns} #{admin_email} (",
      "    #{soa.serial} ; Serial",
      "    #{soa.refresh} ; Refresh",
      "    #{soa.retry} ; Retry",
      "    #{soa.expire} ; Expire",
      "    #{soa.minimum} ) ; Minimum TTL"
    ]

    Enum.join(lines, "\n")
  end

  defp generate_bind_record(rr) do
    data_str = generate_record_data(List.first(rr.data))
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

      %{type: :soa, data: soa_data} ->
        inspect(soa_data)

      _ ->
        inspect(data)
    end
  end
end
