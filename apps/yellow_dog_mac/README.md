# YellowDog.MAC

**Fast, compile-time MAC address vendor lookup library for Elixir**

YellowDog.MAC provides efficient MAC (Media Access Control) address utilities including vendor/manufacturer lookup based on the IEEE OUI (Organizationally Unique Identifier) database. The library uses Wireshark's manufacturer database and compiles it into efficient pattern-matching code at compile time for zero-cost lookups.

## Features

- **Lightning-fast vendor lookups** - Compile-time database compilation for zero runtime overhead
- **Comprehensive MAC utilities** - Validate, normalize, format, and parse MAC addresses
- **Multiple format support** - Handles colons, hyphens, dots, and no separators
- **Telemetry integration** - Built-in observability with GSMLG.Telemetry
- **Type-safe API** - Full typespec coverage
- **Zero dependencies** (except optional telemetry)

## Installation

Add `yellow_dog_mac` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:yellow_dog_mac, "~> 0.1.0"}
  ]
end
```

### Database Setup

The library requires Wireshark's manufacturer database file. Download it:

```bash
# From your project root
mkdir -p apps/yellow_dog_mac/priv
curl -sSLf https://gitlab.com/wireshark/wireshark/-/raw/master/manuf \
  -o apps/yellow_dog_mac/priv/manuf.txt
```

**Note:** The database is compiled at compile-time. After updating `manuf.txt`, you must recompile:

```bash
mix deps.clean yellow_dog_mac --build
mix compile
```

## Quick Start

```elixir
# Lookup vendor by MAC address
iex> YellowDog.MAC.lookup_vendor("00:00:0A:BB:28:FC")
{:ok, "OmronTat", "Omron Tateisi Electronics Co."}

# Validate MAC address format
iex> YellowDog.MAC.validate("00:1A:2B:3C:4D:5E")
true

# Normalize MAC to standard format
iex> YellowDog.MAC.normalize("00-1a-2b-3c-4d-5e")
{:ok, "00:1A:2B:3C:4D:5E"}

# Format MAC with different separators
iex> YellowDog.MAC.format("001a2b3c4d5e", :hyphens)
{:ok, "00-1A-2B-3C-4D-5E"}

# Extract OUI (first 24 bits)
iex> YellowDog.MAC.parse_oui("00:1A:2B:3C:4D:5E")
{:ok, "00:1A:2B"}

# Generate random MAC address
iex> YellowDog.MAC.random()
"A3:4F:12:8B:C9:7E"
```

## Usage

### Vendor Lookup

Look up the manufacturer/vendor of a MAC address using the IEEE OUI database:

```elixir
# Standard colon format
YellowDog.MAC.lookup_vendor("00:00:0A:BB:28:FC")
#=> {:ok, "OmronTat", "Omron Tateisi Electronics Co."}

# Hyphen format
YellowDog.MAC.lookup_vendor("00-50-56-C0-00-08")
#=> {:ok, "VMware", "VMware, Inc."}

# Dot format (Cisco)
YellowDog.MAC.lookup_vendor("0050.56C0.0008")
#=> {:ok, "VMware", "VMware, Inc."}

# No separators
YellowDog.MAC.lookup_vendor("005056C00008")
#=> {:ok, "VMware", "VMware, Inc."}

# Unknown vendor
YellowDog.MAC.lookup_vendor("FF:FF:FF:FF:FF:FF")
#=> :error

# Invalid format
YellowDog.MAC.lookup_vendor("invalid")
#=> :error
```

**Returns:**
- `{:ok, short_name, full_name}` - Vendor found
- `:error` - Vendor not found or invalid MAC format

The lookup chooses the longest matching prefix, including /24, /28, and /36 entries sharing the same OUI. When a more specific prefix does not match, it falls back to a broader entry if one exists. The vendor database contains over 28,000+ entries from the IEEE registration authority and Wireshark project.

Operator-provided Wireshark manufacturer database contents can be compiled and queried without replacing the bundled database:

```elixir
table = YellowDog.MAC.Compiler.build_lookup_table(File.read!("/etc/manuf.txt"))
YellowDog.MAC.Compiler.count_entries(table)
YellowDog.MAC.Vendor.lookup("00:11:22:33:40:00", table)
```

Tables with a single prefix width per OUI retain their existing format. Mixed widths use `{:mixed, [{width, prefix_map}, ...]}` buckets ordered longest first. Repeated identical prefixes keep the last record, as before.

### MAC Address Validation

Check if a string is a valid MAC address format:

```elixir
# Valid formats
YellowDog.MAC.validate("00:1A:2B:3C:4D:5E")  #=> true
YellowDog.MAC.validate("00-1A-2B-3C-4D-5E")  #=> true
YellowDog.MAC.validate("001A.2B3C.4D5E")      #=> true
YellowDog.MAC.validate("001A2B3C4D5E")        #=> true

# Invalid formats
YellowDog.MAC.validate("00:1A:2B:3C:4D")     #=> false (too short)
YellowDog.MAC.validate("00:1A:2B:GG:4D:5E")  #=> false (invalid hex)
YellowDog.MAC.validate("not-a-mac")          #=> false
YellowDog.MAC.validate("")                   #=> false
```

Accepts any standard MAC address format with 48 bits (6 bytes).

### MAC Address Normalization

Convert any MAC format to the standard uppercase colon-separated format:

```elixir
# From hyphens
YellowDog.MAC.normalize("00-1a-2b-3c-4d-5e")
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# From dots (Cisco format)
YellowDog.MAC.normalize("001a.2b3c.4d5e")
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# From no separators
YellowDog.MAC.normalize("001a2b3c4d5e")
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# Already normalized (converts to uppercase)
YellowDog.MAC.normalize("00:1a:2b:3c:4d:5e")
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# Mixed formats (cleans up)
YellowDog.MAC.normalize("00:1A-2B.3C4D:5E")
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# Invalid MAC
YellowDog.MAC.normalize("invalid")
#=> {:error, :invalid_mac}
```

Normalization is useful for storing MACs in a database with consistent formatting.

### MAC Address Formatting

Format a MAC address with different separator styles:

```elixir
mac = "001A2B3C4D5E"

# Colon-separated (standard)
YellowDog.MAC.format(mac, :colons)
#=> {:ok, "00:1A:2B:3C:4D:5E"}

# Hyphen-separated
YellowDog.MAC.format(mac, :hyphens)
#=> {:ok, "00-1A-2B-3C-4D-5E"}

# Dot-separated, grouped by 2 (Cisco format)
YellowDog.MAC.format(mac, :dots)
#=> {:ok, "001A.2B3C.4D5E"}

# No separators
YellowDog.MAC.format(mac, :none)
#=> {:ok, "001A2B3C4D5E"}

# Cisco format (dots, grouped by 4 hex digits)
YellowDog.MAC.format(mac, :cisco)
#=> {:ok, "001A.2B3C.4D5E"}

# Invalid format style
YellowDog.MAC.format(mac, :unknown)
#=> {:error, :invalid_format}

# Invalid MAC
YellowDog.MAC.format("invalid", :colons)
#=> {:error, :invalid_mac}
```

**Format options:**
- `:colons` - `00:1A:2B:3C:4D:5E` (default, most common)
- `:hyphens` - `00-1A-2B-3C-4D-5E` (Windows style)
- `:dots` - `001A.2B3C.4D5E` (Cisco style)
- `:cisco` - Same as `:dots`
- `:none` - `001A2B3C4D5E` (compact)

### OUI Parsing

Extract the OUI (Organizationally Unique Identifier) - the first 24 bits that identify the vendor:

```elixir
# Standard format
YellowDog.MAC.parse_oui("00:1A:2B:3C:4D:5E")
#=> {:ok, "00:1A:2B"}

# Any format works
YellowDog.MAC.parse_oui("00-1A-2B-3C-4D-5E")
#=> {:ok, "00:1A:2B"}

YellowDog.MAC.parse_oui("001a2b3c4d5e")
#=> {:ok, "00:1A:2B"}

# Invalid MAC
YellowDog.MAC.parse_oui("invalid")
#=> {:error, :invalid_mac}
```

The OUI is always returned in uppercase colon-separated format.

### Random MAC Generation

Generate random MAC addresses for testing:

```elixir
# Fully random MAC
YellowDog.MAC.random()
#=> "A3:4F:12:8B:C9:7E"

# Random MAC with specific OUI
YellowDog.MAC.random("00:1A:2B")
#=> "00:1A:2B:7C:3E:91"

# Random MAC with OUI from vendor
YellowDog.MAC.random("00-50-56")  # VMware OUI
#=> "00:50:56:A2:B8:3F"

# Invalid OUI
YellowDog.MAC.random("invalid")
#=> {:error, :invalid_oui}
```

Useful for generating test data or temporary MAC addresses.

## Telemetry

YellowDog.MAC emits telemetry events when integrated with GSMLG.Telemetry. To enable telemetry, add the dependency:

```elixir
def deps do
  [
    {:yellow_dog_mac, "~> 0.1.0"},
    {:gsmlg_telemetry, "~> 0.1.0"}
  ]
end
```

### Events

#### `[:yellow_dog, :mac, :lookup]`

Emitted when performing vendor lookups.

**Metadata:**
- `:mac` - The MAC address being looked up
- `:oui` - Extracted OUI (first 24 bits)
- `:found` - Boolean indicating if vendor was found
- `:vendor_short` - Short vendor name (if found)
- `:vendor_full` - Full vendor name (if found)

**Measurements:**
- `:duration` - Lookup duration in native time units

**Example handler:**

```elixir
:telemetry.attach(
  "mac-lookup-handler",
  [:yellow_dog, :mac, :lookup],
  fn event, measurements, metadata, _config ->
    IO.puts("MAC lookup: #{metadata.mac} -> #{metadata.found}")
  end,
  nil
)
```

#### `[:yellow_dog, :mac, :operation]`

Emitted for utility operations (validate, normalize, format, etc.).

**Metadata:**
- `:operation` - Operation name (`:validate`, `:normalize`, `:format`, `:parse_oui`, `:random`)
- `:mac` - Input MAC address
- `:result` - Operation result (`:ok` or `:error`)

**Measurements:**
- `:duration` - Operation duration in native time units

## Supported MAC Formats

YellowDog.MAC automatically handles multiple MAC address formats:

| Format | Example | Description |
|--------|---------|-------------|
| Colon-separated | `00:1A:2B:3C:4D:5E` | Most common format (IEEE standard) |
| Hyphen-separated | `00-1A-2B-3C-4D-5E` | Windows style |
| Dot-separated | `001A.2B3C.4D5E` | Cisco style (4 hex digits per group) |
| No separators | `001A2B3C4D5E` | Compact format |
| Mixed case | `00:1a:2B:3c:4D:5e` | Accepts any case, normalizes to uppercase |

All formats are automatically recognized by all functions. The library normalizes internally.

## Architecture & Performance

### Compile-Time Database Compilation

YellowDog.MAC uses a unique compile-time approach for maximum performance:

1. **Build Time:** The `manuf.txt` database is parsed and compiled into Elixir module attributes
2. **Compile Time:** The lookup table becomes pattern-matching code in the BEAM bytecode
3. **Runtime:** Lookups are simple map lookups - effectively zero overhead

**Performance characteristics:**
- Vendor lookup: O(1) - constant time map lookup
- Memory: ~2-3MB for compiled lookup table (28,000+ entries)
- Startup: Zero - no runtime database loading
- Lookup latency: ~0.1-0.5 microseconds (essentially free)

This is significantly faster than:
- Runtime parsing: ~100-1000x faster
- External API calls: ~10,000-100,000x faster
- File I/O on each lookup: ~1,000-10,000x faster

### Trade-offs

**Advantages:**
- Blazing fast lookups (microseconds)
- No runtime dependencies
- No startup cost
- No file I/O or parsing overhead
- Type-safe with compile-time guarantees

**Disadvantages:**
- Requires recompilation to update database
- Increases compiled application size (~2-3MB)
- Database updates need redeployment
- Not suitable if database changes frequently

**Best for:**
- Applications where vendor database is relatively stable
- Performance-critical lookups
- Embedded systems with predictable MAC vendors
- CLI tools and scripts
- API services with high lookup volume

**Not ideal for:**
- Applications requiring frequent database updates
- When database must change without redeployment
- Extremely memory-constrained environments

## Updating the Database

The MAC vendor database changes as new OUIs are assigned. To update:

### Manual Update

```bash
# Download latest database
curl -sSLf https://gitlab.com/wireshark/wireshark/-/raw/master/manuf \
  -o apps/yellow_dog_mac/priv/manuf.txt

# Recompile the application
mix deps.clean yellow_dog_mac --build
mix compile

# Verify entry count (should be 28,000+)
iex> YellowDog.MAC.Vendor.entries()
28542
```

### Automated Update (CI/CD)

Add to your deployment pipeline:

```bash
#!/bin/bash
# update_mac_db.sh

echo "Updating MAC vendor database..."
curl -sSLf https://gitlab.com/wireshark/wireshark/-/raw/master/manuf \
  -o apps/yellow_dog_mac/priv/manuf.txt

echo "Recompiling with new database..."
mix deps.clean yellow_dog_mac --build
mix compile

echo "Database updated successfully!"
```

**Recommendation:** Update quarterly or when you need specific new vendors.

## Common Use Cases

### 1. Network Device Inventory

```elixir
defmodule NetworkInventory do
  def scan_devices(mac_addresses) do
    Enum.map(mac_addresses, fn mac ->
      case YellowDog.MAC.lookup_vendor(mac) do
        {:ok, short, full} ->
          %{mac: mac, vendor: short, manufacturer: full}
        :error ->
          %{mac: mac, vendor: "Unknown", manufacturer: "Unknown"}
      end
    end)
  end
end

NetworkInventory.scan_devices([
  "00:50:56:C0:00:08",
  "00:1A:2B:3C:4D:5E",
  "A4:5E:60:D8:9C:12"
])
```

### 2. MAC Address Validation in Ecto Schema

```elixir
defmodule Device do
  use Ecto.Schema
  import Ecto.Changeset

  schema "devices" do
    field :mac_address, :string
    field :vendor, :string
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:mac_address])
    |> validate_required([:mac_address])
    |> validate_mac_address()
    |> populate_vendor()
  end

  defp validate_mac_address(changeset) do
    validate_change(changeset, :mac_address, fn :mac_address, mac ->
      if YellowDog.MAC.validate(mac) do
        []
      else
        [mac_address: "is not a valid MAC address"]
      end
    end)
  end

  defp populate_vendor(changeset) do
    case get_change(changeset, :mac_address) do
      nil -> changeset
      mac ->
        case YellowDog.MAC.lookup_vendor(mac) do
          {:ok, _short, full} -> put_change(changeset, :vendor, full)
          :error -> changeset
        end
    end
  end
end
```

### 3. MAC Address Normalization for Storage

```elixir
defmodule MACStore do
  def store_device(mac, metadata) do
    with {:ok, normalized_mac} <- YellowDog.MAC.normalize(mac),
         {:ok, oui} <- YellowDog.MAC.parse_oui(normalized_mac) do
      %{
        mac: normalized_mac,
        oui: oui,
        vendor: lookup_vendor_safe(normalized_mac),
        metadata: metadata,
        inserted_at: DateTime.utc_now()
      }
      |> save_to_database()
    else
      {:error, _} -> {:error, :invalid_mac}
    end
  end

  defp lookup_vendor_safe(mac) do
    case YellowDog.MAC.lookup_vendor(mac) do
      {:ok, _short, full} -> full
      :error -> nil
    end
  end
end
```

### 4. Network Security Monitoring

```elixir
defmodule SecurityMonitor do
  @known_vendors ["Cisco", "VMware", "Dell", "HP"]

  def check_rogue_device(mac) do
    case YellowDog.MAC.lookup_vendor(mac) do
      {:ok, vendor, _full} ->
        if vendor in @known_vendors do
          {:ok, :authorized}
        else
          {:warning, :unknown_vendor, vendor}
        end
      :error ->
        {:alert, :unrecognized_mac}
    end
  end
end
```

### 5. API Endpoint (Phoenix)

```elixir
defmodule MyAppWeb.MACController do
  use MyAppWeb, :controller

  def lookup(conn, %{"mac" => mac}) do
    case YellowDog.MAC.lookup_vendor(mac) do
      {:ok, short, full} ->
        json(conn, %{
          mac: mac,
          vendor_short: short,
          vendor_full: full,
          success: true
        })
      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{mac: mac, error: "Vendor not found", success: false})
    end
  end

  def validate(conn, %{"mac" => mac}) do
    json(conn, %{
      mac: mac,
      valid: YellowDog.MAC.validate(mac)
    })
  end
end
```

## Troubleshooting

### Database file not found

**Error:** `(File.Error) could not read file "...priv/manuf.txt": no such file or directory`

**Solution:** Download the database file:

```bash
mkdir -p apps/yellow_dog_mac/priv
curl -sSLf https://gitlab.com/wireshark/wireshark/-/raw/master/manuf \
  -o apps/yellow_dog_mac/priv/manuf.txt
mix deps.clean yellow_dog_mac --build
mix compile
```

### Vendor not found for valid MAC

**Issue:** `lookup_vendor/1` returns `:error` for a legitimate MAC address.

**Causes:**
1. OUI not in database (new vendor, private OUI)
2. Outdated database
3. MAC is randomly generated or spoofed

**Solutions:**
- Update database (see "Updating the Database" section)
- Check if MAC is from a newer vendor
- For private/local MACs (02:xx:xx:xx:xx:xx), vendor lookup won't work

### Compilation is slow

**Issue:** Application takes longer to compile after adding yellow_dog_mac.

**Explanation:** The library compiles ~28,000 vendor entries into pattern-matching code at compile time. This is a one-time cost.

**Solutions:**
- This is expected behavior for compile-time optimization
- Compilation happens once, runtime is extremely fast
- Consider using `mix compile` cache in CI/CD
- Typical compilation overhead: 2-5 seconds

### MAC format not recognized

**Issue:** Valid MAC not being parsed correctly.

**Solution:** YellowDog.MAC accepts standard formats. Try normalizing first:

```elixir
mac = "unusual:format:here"
case YellowDog.MAC.normalize(mac) do
  {:ok, normalized} -> YellowDog.MAC.lookup_vendor(normalized)
  {:error, _} -> # Handle invalid format
end
```

## Comparison with Alternatives

| Approach | Speed | Memory | Updates | Dependencies |
|----------|-------|--------|---------|--------------|
| **YellowDog.MAC** | ★★★★★ | Medium | Recompile | None |
| Runtime parsing | ★★☆☆☆ | Low | Easy | None |
| ETS lookup | ★★★★☆ | Medium | Runtime | None |
| External API | ★☆☆☆☆ | Low | Always current | HTTP client |
| SQLite DB | ★★★☆☆ | Low | Easy | SQLite |

**Why choose YellowDog.MAC:**
- Need absolute fastest lookups
- Vendor database rarely changes
- Want zero runtime dependencies
- Prefer type safety and compile-time guarantees

**Consider alternatives if:**
- Database must update without redeployment
- Memory is extremely constrained
- Application rarely performs lookups

## Contributing

To contribute or report issues:

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Resources

- [IEEE OUI Database](https://standards.ieee.org/develop/regauth/oui/)
- [Wireshark Manufacturer Database](https://gitlab.com/wireshark/wireshark/-/blob/master/manuf)
- [MAC Address Format Standards](https://standards.ieee.org/products-programs/regauth/)

## Credits

Vendor database sourced from the Wireshark project, which aggregates IEEE OUI assignments and additional manufacturer information.
