defmodule YellowDog.Dns.ZoneStoreTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.ZoneStore.

  Tests cover:
  - TOML file loading and parsing
  - Zone configuration validation
  - Zone type-specific validation
  - Zone normalization
  - File saving with atomic writes
  - View-based key parsing
  - Error cases
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.ZoneStore

  @test_dir "test/tmp/zone_store_test"

  setup do
    # Create a unique test directory for each test
    test_path = Path.join(@test_dir, "#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)
    end)

    {:ok, test_path: test_path}
  end

  describe "load_zones/1" do
    test "loads auth zone from valid TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."example.com"]
      type = "auth"
      file = "zones/example.com.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "example.com"
      assert zone.type == :auth
      assert zone.file == "zones/example.com.zone"
      assert zone.view_name == "default"
    end

    test "loads forward zone with upstreams", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."."]
      type = "forward"
      upstreams = ["8.8.8.8:53", "8.8.4.4:53"]
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "."
      assert zone.type == :forward
      assert zone.upstreams == ["8.8.8.8:53", "8.8.4.4:53"]
    end

    test "loads stub zone with ns_records", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."corp.example.com"]
      type = "stub"
      ns_records = ["ns1.corp.example.com", "ns2.corp.example.com"]
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "corp.example.com"
      assert zone.type == :stub
      assert zone.ns_records == ["ns1.corp.example.com", "ns2.corp.example.com"]
    end

    test "loads multiple zones", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."example.com"]
      type = "auth"
      file = "zones/example.com.zone"

      [zones."internal.example.com"]
      type = "auth"
      file = "zones/internal.example.com.zone"

      [zones."."]
      type = "forward"
      upstreams = ["8.8.8.8:53"]
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 3
      names = Enum.map(zones, & &1.name)
      assert "example.com" in names
      assert "internal.example.com" in names
      assert "." in names
    end

    test "loads zone with view_name in config", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."internal:example.com"]
      type = "auth"
      view_name = "internal"
      file = "zones/internal-example.com.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "example.com"
      assert zone.view_name == "internal"
    end

    test "parses view_name:zone_name key format", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."myview:myzone.com"]
      type = "auth"
      file = "zones/myzone.com.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "myzone.com"
      assert zone.view_name == "myview"
    end

    test "returns empty list for non-existent file", %{test_path: test_path} do
      file_path = Path.join(test_path, "nonexistent.toml")

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert zones == []
    end

    test "returns error for invalid TOML", %{test_path: test_path} do
      file_path = Path.join(test_path, "invalid.toml")

      content = """
      [zones."broken"
      type = "auth"
      """

      File.write!(file_path, content)

      {:error, {:toml_parse_error, _reason}} = ZoneStore.load_zones(file_path)
    end

    test "skips zones without valid name", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      # Empty zone name should be skipped
      content = """
      [zones.""]
      type = "auth"

      [zones."valid.com"]
      type = "auth"
      file = "zones/valid.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      # Only valid zone should be loaded
      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "valid.com"
    end

    test "skips forward zones without upstreams", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."invalid-forward.com"]
      type = "forward"

      [zones."valid.com"]
      type = "auth"
      file = "zones/valid.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      # Only valid zone should be loaded (forward without upstreams is skipped)
      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "valid.com"
    end

    test "skips stub zones without ns_records", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."invalid-stub.com"]
      type = "stub"

      [zones."valid.com"]
      type = "auth"
      file = "zones/valid.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 1
      [zone] = zones
      assert zone.name == "valid.com"
    end

    test "loads all zone types", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."auth.com"]
      type = "auth"
      file = "zones/auth.zone"

      [zones."forward.com"]
      type = "forward"
      upstreams = ["8.8.8.8:53"]

      [zones."stub.com"]
      type = "stub"
      ns_records = ["ns1.stub.com"]

      [zones."cache.com"]
      type = "cache"

      [zones."root.com"]
      type = "root"

      [zones."rpz.com"]
      type = "rpz"
      file = "zones/rpz.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      assert length(zones) == 6
      types = Enum.map(zones, & &1.type)
      assert :auth in types
      assert :forward in types
      assert :stub in types
      assert :cache in types
      assert :root in types
      assert :rpz in types
    end

    test "loads zone with TTL", %{test_path: test_path} do
      file_path = Path.join(test_path, "zones.toml")

      content = """
      [zones."example.com"]
      type = "auth"
      file = "zones/example.zone"
      ttl = 3600
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)

      [zone] = zones
      assert zone.ttl == 3600
    end
  end

  describe "save_zones/3" do
    test "saves auth zone to TOML file", %{test_path: test_path} do
      file_path = Path.join(test_path, "output.toml")

      zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "default",
          file: "zones/example.com.zone",
          upstreams: nil,
          ns_records: nil,
          ttl: nil
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)
      assert File.exists?(file_path)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.name == "example.com"
      assert zone.type == :auth
    end

    test "saves forward zone with upstreams", %{test_path: test_path} do
      file_path = Path.join(test_path, "forward.toml")

      zones = [
        %{
          name: ".",
          type: :forward,
          view_name: "default",
          upstreams: ["8.8.8.8:53", "1.1.1.1:53"],
          file: nil,
          ns_records: nil,
          ttl: nil
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.upstreams == ["8.8.8.8:53", "1.1.1.1:53"]
    end

    test "saves zone with non-default view", %{test_path: test_path} do
      file_path = Path.join(test_path, "views.toml")

      zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "internal",
          file: "zones/internal-example.zone",
          upstreams: nil,
          ns_records: nil,
          ttl: nil
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.view_name == "internal"
    end

    test "creates backup before overwriting", %{test_path: test_path} do
      file_path = Path.join(test_path, "backup_test.toml")
      backup_path = file_path <> ".backup"

      # Write initial file
      zones1 = [
        %{
          name: "original.com",
          type: :auth,
          view_name: "default",
          file: "zones/original.zone"
        }
      ]

      ZoneStore.save_zones(file_path, zones1)

      # Overwrite with new content
      zones2 = [
        %{
          name: "updated.com",
          type: :auth,
          view_name: "default",
          file: "zones/updated.zone"
        }
      ]

      ZoneStore.save_zones(file_path, zones2)

      assert File.exists?(backup_path)

      # Verify backup contains original content
      {:ok, backup} = ZoneStore.load_zones(backup_path)
      [backup_zone] = backup
      assert backup_zone.name == "original.com"
    end

    test "skips backup when option is false", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_backup.toml")
      backup_path = file_path <> ".backup"

      zones1 = [
        %{name: "first.com", type: :auth, view_name: "default", file: "zones/first.zone"}
      ]

      ZoneStore.save_zones(file_path, zones1)

      zones2 = [
        %{name: "second.com", type: :auth, view_name: "default", file: "zones/second.zone"}
      ]

      ZoneStore.save_zones(file_path, zones2, backup: false)

      refute File.exists?(backup_path)
    end

    test "creates parent directories if needed", %{test_path: test_path} do
      file_path = Path.join([test_path, "deep", "nested", "zones.toml"])

      zones = [
        %{name: "deep.com", type: :auth, view_name: "default", file: "zones/deep.zone"}
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)
      assert File.exists?(file_path)
    end

    test "saves stub zone with ns_records", %{test_path: test_path} do
      file_path = Path.join(test_path, "stub.toml")

      zones = [
        %{
          name: "stub.com",
          type: :stub,
          view_name: "default",
          ns_records: ["ns1.stub.com", "ns2.stub.com"],
          file: nil,
          upstreams: nil,
          ttl: nil
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.ns_records == ["ns1.stub.com", "ns2.stub.com"]
    end

    test "saves zone with TTL", %{test_path: test_path} do
      file_path = Path.join(test_path, "ttl.toml")

      zones = [
        %{
          name: "ttl.com",
          type: :auth,
          view_name: "default",
          file: "zones/ttl.zone",
          ttl: 7200
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.ttl == 7200
    end

    test "saves auth zone cloud mirror metadata", %{test_path: test_path} do
      file_path = Path.join(test_path, "cloud_mirror.toml")

      cloud_mirror = %{
        enabled: true,
        connector_name: "aws-prod",
        provider: :route53,
        zone_id: "Z123456789",
        direction: :bidirectional,
        conflict_strategy: :local_wins
      }

      zones = [
        %{
          name: "cloud.example.com",
          type: :auth,
          view_name: "default",
          file: "zones/cloud.example.com.zone",
          cloud_mirror: cloud_mirror
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      assert [%{cloud_mirror: ^cloud_mirror}] = loaded
    end
  end

  describe "validate_zone/1" do
    test "validates auth zone with all required fields" do
      zone = %{
        name: "valid.com",
        type: :auth,
        file: "zones/valid.zone"
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end

    test "validates forward zone with upstreams" do
      zone = %{
        name: ".",
        type: :forward,
        upstreams: ["8.8.8.8:53"]
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end

    test "validates stub zone with ns_records" do
      zone = %{
        name: "stub.com",
        type: :stub,
        ns_records: ["ns1.stub.com"]
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end

    test "returns error for missing name" do
      zone = %{
        type: :auth,
        file: "zones/test.zone"
      }

      assert {:error, "Missing required field: name"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for missing type" do
      zone = %{
        name: "test.com",
        file: "zones/test.zone"
      }

      assert {:error, "Missing required field: type"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for empty name" do
      zone = %{
        name: "",
        type: :auth
      }

      assert {:error, "Invalid zone name"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for invalid type" do
      zone = %{
        name: "test.com",
        type: :invalid
      }

      assert {:error, "Invalid zone type"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for forward zone without upstreams" do
      zone = %{
        name: "forward.com",
        type: :forward,
        upstreams: nil
      }

      assert {:error, "Forward zones require upstreams"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for forward zone with empty upstreams" do
      zone = %{
        name: "forward.com",
        type: :forward,
        upstreams: []
      }

      assert {:error, "Forward zones require upstreams"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for stub zone without ns_records" do
      zone = %{
        name: "stub.com",
        type: :stub,
        ns_records: nil
      }

      assert {:error, "Stub zones require ns_records"} = ZoneStore.validate_zone(zone)
    end

    test "returns error for stub zone with empty ns_records" do
      zone = %{
        name: "stub.com",
        type: :stub,
        ns_records: []
      }

      assert {:error, "Stub zones require ns_records"} = ZoneStore.validate_zone(zone)
    end

    test "validates cache zone without special requirements" do
      zone = %{
        name: "cache.com",
        type: :cache
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end

    test "validates root zone without special requirements" do
      zone = %{
        name: "root.com",
        type: :root
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end

    test "validates rpz zone without special requirements" do
      zone = %{
        name: "rpz.com",
        type: :rpz,
        file: "zones/rpz.zone"
      }

      assert :ok = ZoneStore.validate_zone(zone)
    end
  end

  describe "round-trip persistence" do
    test "complex zone config survives save/load cycle", %{test_path: test_path} do
      file_path = Path.join(test_path, "roundtrip.toml")

      original_zones = [
        %{
          name: "auth.example.com",
          type: :auth,
          view_name: "internal",
          file: "zones/auth.zone",
          ttl: 3600
        },
        %{
          name: "forward.example.com",
          type: :forward,
          view_name: "default",
          upstreams: ["8.8.8.8:53", "1.1.1.1:53"]
        },
        %{
          name: "stub.example.com",
          type: :stub,
          view_name: "external",
          ns_records: ["ns1.example.com", "ns2.example.com"]
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, original_zones)
      {:ok, loaded} = ZoneStore.load_zones(file_path)

      assert length(loaded) == 3

      auth = Enum.find(loaded, &(&1.name == "auth.example.com"))
      assert auth.type == :auth
      assert auth.view_name == "internal"
      assert auth.file == "zones/auth.zone"
      assert auth.ttl == 3600

      forward = Enum.find(loaded, &(&1.name == "forward.example.com"))
      assert forward.type == :forward
      assert forward.upstreams == ["8.8.8.8:53", "1.1.1.1:53"]

      stub = Enum.find(loaded, &(&1.name == "stub.example.com"))
      assert stub.type == :stub
      assert stub.ns_records == ["ns1.example.com", "ns2.example.com"]
    end
  end

  describe "edge cases" do
    test "handles empty zones list", %{test_path: test_path} do
      file_path = Path.join(test_path, "empty.toml")

      assert :ok = ZoneStore.save_zones(file_path, [])
      {:ok, loaded} = ZoneStore.load_zones(file_path)
      assert loaded == []
    end

    test "handles file with no zones section", %{test_path: test_path} do
      file_path = Path.join(test_path, "no_zones.toml")

      content = """
      # Configuration file with no zones
      [settings]
      debug = true
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)
      assert zones == []
    end

    test "handles zone names with dots", %{test_path: test_path} do
      file_path = Path.join(test_path, "dots.toml")

      zones = [
        %{
          name: "sub.domain.example.com",
          type: :auth,
          view_name: "default",
          file: "zones/sub.domain.example.com.zone"
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.name == "sub.domain.example.com"
    end

    test "handles root zone name (.)", %{test_path: test_path} do
      file_path = Path.join(test_path, "root.toml")

      zones = [
        %{
          name: ".",
          type: :forward,
          view_name: "default",
          upstreams: ["8.8.8.8:53"]
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.name == "."
    end

    test "handles unicode in zone file paths", %{test_path: test_path} do
      file_path = Path.join(test_path, "unicode.toml")

      zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "default",
          file: "zones/例え.zone"
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.file == "zones/例え.zone"
    end

    test "handles many zones", %{test_path: test_path} do
      file_path = Path.join(test_path, "many.toml")

      zones =
        for i <- 1..50 do
          %{
            name: "zone#{i}.example.com",
            type: :auth,
            view_name: "default",
            file: "zones/zone#{i}.zone"
          }
        end

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      assert length(loaded) == 50
    end

    test "handles quotes in file paths", %{test_path: test_path} do
      file_path = Path.join(test_path, "quotes.toml")

      zones = [
        %{
          name: "example.com",
          type: :auth,
          view_name: "default",
          file: "zones/\"special\".zone"
        }
      ]

      assert :ok = ZoneStore.save_zones(file_path, zones)

      {:ok, loaded} = ZoneStore.load_zones(file_path)
      [zone] = loaded
      assert zone.file == "zones/\"special\".zone"
    end

    test "normalizes string type to atom", %{test_path: test_path} do
      file_path = Path.join(test_path, "string_type.toml")

      content = """
      [zones."example.com"]
      type = "auth"
      file = "zones/example.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)
      [zone] = zones
      assert zone.type == :auth
    end

    test "defaults type to auth if unknown", %{test_path: test_path} do
      file_path = Path.join(test_path, "unknown_type.toml")

      content = """
      [zones."example.com"]
      type = "unknown"
      file = "zones/example.zone"
      """

      File.write!(file_path, content)

      {:ok, zones} = ZoneStore.load_zones(file_path)
      [zone] = zones
      assert zone.type == :auth
    end
  end
end
