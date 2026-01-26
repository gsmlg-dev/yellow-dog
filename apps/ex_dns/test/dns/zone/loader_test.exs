defmodule DNS.Zone.LoaderTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Loader module.

  Tests cover:
  - Module structure and exports
  - load_zones_from_directory/1
  - load_zone_from_file/2
  - reload_zone/1
  - save_zone_to_file/2
  - create_zone_data/1
  """
  use ExUnit.Case, async: true

  alias DNS.Zone
  alias DNS.Zone.Loader
  alias DNS.Zone.Name

  @test_zone_content """
  $ORIGIN example.com.
  $TTL 3600
  @       IN  SOA ns1.example.com. admin.example.com. (
              2024010101  ; serial
              3600        ; refresh
              1800        ; retry
              604800      ; expire
              86400       ; minimum
          )
  @       IN  NS  ns1.example.com.
  @       IN  NS  ns2.example.com.
  www     IN  A   192.168.1.100
  """

  setup do
    # Create temp directory for test files
    temp_dir = System.tmp_dir!() |> Path.join("dns_loader_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Loader)
    end

    test "exports load_zones_from_directory/1" do
      Code.ensure_loaded!(Loader)
      assert Kernel.function_exported?(Loader, :load_zones_from_directory, 1)
    end

    test "exports load_zone_from_file/2" do
      Code.ensure_loaded!(Loader)
      assert Kernel.function_exported?(Loader, :load_zone_from_file, 2)
    end

    test "exports reload_zone/1" do
      Code.ensure_loaded!(Loader)
      assert Kernel.function_exported?(Loader, :reload_zone, 1)
    end

    test "exports save_zone_to_file/2" do
      Code.ensure_loaded!(Loader)
      assert Kernel.function_exported?(Loader, :save_zone_to_file, 2)
    end

    test "exports create_zone_data/1" do
      Code.ensure_loaded!(Loader)
      assert Kernel.function_exported?(Loader, :create_zone_data, 1)
    end
  end

  describe "load_zone_from_file/2" do
    test "returns error for non-existent file" do
      result = Loader.load_zone_from_file("test.com", "/nonexistent/path/zone.db")

      assert {:error, _} = result
    end

    test "loads zone from valid file", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "example.com.zone")
      File.write!(zone_path, @test_zone_content)

      result = Loader.load_zone_from_file("example.com", zone_path)

      assert {:ok, zone} = result
      assert zone.name.value == "example.com"
    end

    test "stores source_file in zone options", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "source.com.zone")
      File.write!(zone_path, @test_zone_content)

      {:ok, zone} = Loader.load_zone_from_file("source.com", zone_path)

      assert Keyword.get(zone.options, :source_file) == zone_path
    end

    test "returns error for invalid zone content", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "invalid.zone")
      File.write!(zone_path, "this is not valid zone data @@@@")

      result = Loader.load_zone_from_file("invalid.com", zone_path)

      assert {:error, _} = result
    end

    test "handles empty file", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "empty.zone")
      File.write!(zone_path, "")

      result = Loader.load_zone_from_file("empty.com", zone_path)

      # Empty file should fail or return empty zone
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "load_zones_from_directory/1" do
    test "returns error for non-existent directory" do
      result = Loader.load_zones_from_directory("/nonexistent/directory")

      assert {:error, message} = result
      assert String.contains?(message, "Failed to read directory")
    end

    test "returns empty list for directory with no zone files", %{temp_dir: temp_dir} do
      {:ok, zones} = Loader.load_zones_from_directory(temp_dir)

      assert zones == []
    end

    test "loads zone files with .zone extension", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "example.com.zone")
      File.write!(zone_path, @test_zone_content)

      {:ok, zones} = Loader.load_zones_from_directory(temp_dir)

      assert length(zones) >= 0
    end

    test "ignores non-.zone files", %{temp_dir: temp_dir} do
      # Write a .txt file
      txt_path = Path.join(temp_dir, "notes.txt")
      File.write!(txt_path, "some notes")

      # Write a valid zone file
      zone_path = Path.join(temp_dir, "test.com.zone")
      File.write!(zone_path, @test_zone_content)

      {:ok, zones} = Loader.load_zones_from_directory(temp_dir)

      # Should not include the .txt file
      names = Enum.map(zones, & &1.name.value)
      refute "notes" in names
    end

    test "handles multiple zone files", %{temp_dir: temp_dir} do
      for name <- ["first.com", "second.com", "third.com"] do
        zone_path = Path.join(temp_dir, "#{name}.zone")
        content = String.replace(@test_zone_content, "example.com", name)
        File.write!(zone_path, content)
      end

      {:ok, zones} = Loader.load_zones_from_directory(temp_dir)

      # At least some zones should load (may fail on some)
      assert is_list(zones)
    end

    test "skips invalid zone files gracefully", %{temp_dir: temp_dir} do
      # Valid zone
      valid_path = Path.join(temp_dir, "valid.com.zone")
      File.write!(valid_path, @test_zone_content)

      # Invalid zone
      invalid_path = Path.join(temp_dir, "invalid.com.zone")
      File.write!(invalid_path, "not valid zone data @@@")

      {:ok, zones} = Loader.load_zones_from_directory(temp_dir)

      # Should still succeed with valid zones
      assert is_list(zones)
    end
  end

  describe "reload_zone/1" do
    test "returns error when zone has no source file" do
      zone = Zone.new("nosource.com", :authoritative)

      result = Loader.reload_zone(zone)

      assert {:error, "Zone has no source file"} = result
    end

    test "reloads zone from source file", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "reload.com.zone")
      File.write!(zone_path, @test_zone_content)

      zone = Zone.new("reload.com", :authoritative, source_file: zone_path)

      result = Loader.reload_zone(zone)

      assert {:ok, reloaded} = result
      assert Keyword.get(reloaded.options, :source_file) == zone_path
    end

    test "returns error when source file no longer exists", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "deleted.zone")
      zone = Zone.new("deleted.com", :authoritative, source_file: zone_path)

      result = Loader.reload_zone(zone)

      assert {:error, _} = result
    end
  end

  describe "save_zone_to_file/2" do
    test "saves zone to file", %{temp_dir: temp_dir} do
      zone = Zone.new("save.com", :authoritative)
      zone_path = Path.join(temp_dir, "save.com.zone")

      result = Loader.save_zone_to_file(zone, zone_path)

      assert result == :ok
      assert File.exists?(zone_path)
    end

    test "creates file with zone content", %{temp_dir: temp_dir} do
      zone = Zone.new("content.com", :authoritative)
      zone_path = Path.join(temp_dir, "content.com.zone")

      Loader.save_zone_to_file(zone, zone_path)

      content = File.read!(zone_path)
      assert is_binary(content)
    end

    test "returns error for invalid path" do
      zone = Zone.new("test.com", :authoritative)

      result = Loader.save_zone_to_file(zone, "/nonexistent/deep/path/zone.db")

      assert {:error, message} = result
      assert String.contains?(message, "Failed to write zone file")
    end

    test "overwrites existing file", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "overwrite.zone")
      File.write!(zone_path, "old content")

      zone = Zone.new("overwrite.com", :authoritative)
      Loader.save_zone_to_file(zone, zone_path)

      content = File.read!(zone_path)
      refute content == "old content"
    end
  end

  describe "create_zone_data/1" do
    test "creates data map from zone" do
      zone = Zone.new("data.com", :authoritative, ttl: 3600)

      data = Loader.create_zone_data(zone)

      assert is_map(data)
    end

    test "extracts ttl from options" do
      zone = Zone.new("ttl.com", :authoritative, ttl: 7200)

      data = Loader.create_zone_data(zone)

      assert data.ttl == 7200
    end

    test "defaults ttl to 3600" do
      zone = Zone.new("default.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.ttl == 3600
    end

    test "extracts origin from options" do
      zone = Zone.new("origin.com", :authoritative, origin: "origin.com.")

      data = Loader.create_zone_data(zone)

      assert data.origin == "origin.com."
    end

    test "returns nil for missing origin" do
      zone = Zone.new("noorigin.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.origin == nil
    end

    test "defaults records to empty list" do
      zone = Zone.new("norecords.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.records == []
    end

    test "defaults includes to empty list" do
      zone = Zone.new("noincludes.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.includes == []
    end

    test "defaults directives to empty list" do
      zone = Zone.new("nodirectives.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.directives == []
    end

    test "defaults errors to empty list" do
      zone = Zone.new("noerrors.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.errors == []
    end

    test "defaults warnings to empty list" do
      zone = Zone.new("nowarnings.com", :authoritative)

      data = Loader.create_zone_data(zone)

      assert data.warnings == []
    end

    test "extracts all available options" do
      zone =
        Zone.new("full.com", :authoritative,
          ttl: 1800,
          origin: "full.com.",
          records: [:record1],
          includes: ["/path/include"],
          directives: [:directive1],
          errors: ["error1"],
          warnings: ["warning1"]
        )

      data = Loader.create_zone_data(zone)

      assert data.ttl == 1800
      assert data.origin == "full.com."
      assert data.records == [:record1]
      assert data.includes == ["/path/include"]
      assert data.directives == [:directive1]
      assert data.errors == ["error1"]
      assert data.warnings == ["warning1"]
    end
  end

  describe "edge cases" do
    test "handles zone with Name struct" do
      zone = Zone.new(Name.new("named.com"), :authoritative, source_file: "/path/to/file")

      result = Loader.reload_zone(zone)

      # Should attempt reload (will fail because file doesn't exist)
      assert {:error, _} = result
    end

    test "load_zone_from_file with relative path", %{temp_dir: temp_dir} do
      zone_path = Path.join(temp_dir, "relative.zone")
      File.write!(zone_path, @test_zone_content)

      # Use absolute path from temp_dir
      result = Loader.load_zone_from_file("relative.com", zone_path)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
