defmodule YellowDog.Dns.Zone do
  @moduledoc """
  Core data structures for DNS zones and records.

  Provides structured representations of DNS zones, records, and related metadata
  compatible with standard DNS RFCs and BIND zone files.
  """

  @type zone_type :: :master | :slave | :stub | :forward | :hint
  @type dns_class :: :IN | :CH | :HS
  @type record_type ::
          :A
          | :AAAA
          | :NS
          | :SOA
          | :MX
          | :TXT
          | :CNAME
          | :PTR
          | :SRV
          | :CAA
          | :NAPTR
          | :TLSA
          | :DS
          | :DNSKEY
          | :RRSIG
          | :NSEC
          | :NSEC3

  defmodule Record do
    @moduledoc """
    Represents a single DNS resource record.
    """

    @type t :: %__MODULE__{
            owner: String.t(),
            ttl: non_neg_integer(),
            class: YellowDog.Dns.Zone.dns_class(),
            type: YellowDog.Dns.Zone.record_type(),
            rdata: any()
          }

    defstruct [:owner, :ttl, :class, :type, :rdata]

    @doc """
    Creates a new DNS record.

    ## Examples

        iex> Record.new("www", :A, {192, 168, 1, 10}, ttl: 300)
        %Record{owner: "www", ttl: 300, class: :IN, type: :A, rdata: {192, 168, 1, 10}}
    """
    def new(owner, type, rdata, opts \\ []) do
      %__MODULE__{
        owner: owner,
        type: type,
        rdata: rdata,
        ttl: Keyword.get(opts, :ttl, 3600),
        class: Keyword.get(opts, :class, :IN)
      }
    end
  end

  defmodule SOA do
    @moduledoc """
    Represents an SOA (Start of Authority) record.
    """

    @type t :: %__MODULE__{
            mname: String.t(),
            rname: String.t(),
            serial: non_neg_integer(),
            refresh: non_neg_integer(),
            retry: non_neg_integer(),
            expire: non_neg_integer(),
            minimum: non_neg_integer()
          }

    defstruct [:mname, :rname, :serial, :refresh, :retry, :expire, :minimum]

    @doc """
    Creates a new SOA record with defaults.

    ## Examples

        iex> SOA.new("ns1.example.com", "admin.example.com", 2024102801)
        %SOA{
          mname: "ns1.example.com",
          rname: "admin.example.com",
          serial: 2024102801,
          refresh: 7200,
          retry: 3600,
          expire: 1209600,
          minimum: 3600
        }
    """
    def new(mname, rname, serial, opts \\ []) do
      %__MODULE__{
        mname: mname,
        rname: rname,
        serial: serial,
        refresh: Keyword.get(opts, :refresh, 7200),
        retry: Keyword.get(opts, :retry, 3600),
        expire: Keyword.get(opts, :expire, 1_209_600),
        minimum: Keyword.get(opts, :minimum, 3600)
      }
    end

    @doc """
    Increments the SOA serial number.

    Uses format YYYYMMDDNN where NN is incremented.
    If date changes, resets to YYYYMMDD01.

    ## Examples

        iex> SOA.increment_serial(2024102801)
        2024102802

        iex> SOA.increment_serial(2024102899)
        2024102899
    """
    def increment_serial(current_serial) do
      current_date = Date.utc_today()
      date_str = Calendar.strftime(current_date, "%Y%m%d")
      date_int = String.to_integer(date_str)

      serial_date = div(current_serial, 100)

      if serial_date == date_int do
        # Same day, increment counter
        counter = rem(current_serial, 100)

        if counter < 99 do
          current_serial + 1
        else
          # Max counter reached, keep same
          current_serial
        end
      else
        # New day, start at 01
        date_int * 100 + 1
      end
    end
  end

  @type t :: %__MODULE__{
          name: String.t(),
          type: zone_type(),
          class: dns_class(),
          ttl: non_neg_integer(),
          origin: String.t(),
          records: [Record.t()],
          soa: SOA.t() | nil,
          file: String.t() | nil,
          loaded_at: integer() | nil,
          serial: non_neg_integer() | nil
        }

  defstruct [
    :name,
    :type,
    :class,
    :ttl,
    :origin,
    :records,
    :soa,
    :file,
    :loaded_at,
    :serial
  ]

  @doc """
  Creates a new zone.

  ## Parameters
  - `name` - Zone name (e.g., "example.com")
  - `type` - Zone type (:master, :slave, etc.)
  - `opts` - Additional options

  ## Options
  - `:ttl` - Default TTL (default: 3600)
  - `:class` - DNS class (default: :IN)
  - `:file` - Zone file path

  ## Examples

      iex> Zone.new("example.com", :master, ttl: 7200)
      %Zone{name: "example.com", type: :master, ttl: 7200, ...}
  """
  def new(name, type, opts \\ []) do
    origin = ensure_trailing_dot(name)

    %__MODULE__{
      name: name,
      type: type,
      class: Keyword.get(opts, :class, :IN),
      ttl: Keyword.get(opts, :ttl, 3600),
      origin: origin,
      records: [],
      soa: nil,
      file: Keyword.get(opts, :file),
      loaded_at: nil,
      serial: nil
    }
  end

  @doc """
  Adds a record to the zone.

  ## Examples

      iex> zone = Zone.new("example.com", :master)
      iex> record = Record.new("www", :A, {192, 168, 1, 10})
      iex> Zone.add_record(zone, record)
      %Zone{records: [%Record{...}], ...}
  """
  def add_record(%__MODULE__{} = zone, %Record{} = record) do
    %{zone | records: [record | zone.records]}
  end

  @doc """
  Sets the SOA record for the zone.

  ## Examples

      iex> zone = Zone.new("example.com", :master)
      iex> soa = SOA.new("ns1.example.com", "admin.example.com", 2024102801)
      iex> Zone.set_soa(zone, soa)
      %Zone{soa: %SOA{...}, serial: 2024102801, ...}
  """
  def set_soa(%__MODULE__{} = zone, %SOA{} = soa) do
    %{zone | soa: soa, serial: soa.serial}
  end

  @doc """
  Marks the zone as loaded.

  Updates the loaded_at timestamp.

  ## Examples

      iex> zone = Zone.new("example.com", :master)
      iex> Zone.mark_loaded(zone)
      %Zone{loaded_at: ..., ...}
  """
  def mark_loaded(%__MODULE__{} = zone) do
    %{zone | loaded_at: System.system_time(:second)}
  end

  @doc """
  Finds records in the zone by owner and type.

  ## Examples

      iex> Zone.find_records(zone, "www", :A)
      [%Record{owner: "www", type: :A, ...}]
  """
  def find_records(%__MODULE__{} = zone, owner, type) do
    Enum.filter(zone.records, fn record ->
      record.owner == owner && record.type == type
    end)
  end

  @doc """
  Gets the zone's current serial number from SOA.

  ## Examples

      iex> Zone.get_serial(zone)
      2024102801
  """
  def get_serial(%__MODULE__{soa: %SOA{serial: serial}}), do: serial
  def get_serial(%__MODULE__{}), do: nil

  @doc """
  Validates that a zone has required records.

  Checks for:
  - SOA record
  - At least one NS record

  ## Examples

      iex> Zone.validate(zone)
      :ok

      iex> Zone.validate(invalid_zone)
      {:error, :missing_soa}
  """
  def validate(%__MODULE__{soa: nil}), do: {:error, :missing_soa}

  def validate(%__MODULE__{records: records}) do
    has_ns? = Enum.any?(records, fn record -> record.type == :NS end)

    if has_ns? do
      :ok
    else
      {:error, :missing_ns}
    end
  end

  @doc """
  Converts zone to storable format for Zone.Storage.

  ## Examples

      iex> Zone.to_storage_format(zone)
      %{
        metadata: %{type: :master, serial: 2024102801, ...},
        records: [...]
      }
  """
  def to_storage_format(%__MODULE__{} = zone) do
    metadata = %{
      type: zone.type,
      class: zone.class,
      ttl: zone.ttl,
      origin: zone.origin,
      file: zone.file,
      loaded_at: zone.loaded_at || System.system_time(:second),
      serial: zone.serial
    }

    records =
      Enum.map(zone.records, fn record ->
        {record.owner, record.type, record.rdata, record.ttl, record.class}
      end)

    %{
      metadata: metadata,
      records: records,
      soa: zone.soa
    }
  end

  # Private helpers

  defp ensure_trailing_dot(name) do
    if String.ends_with?(name, ".") do
      name
    else
      name <> "."
    end
  end
end
