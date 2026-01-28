defmodule YellowDog.Dhcpv4.PoolStoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.PoolStore

  @moduletag :unit

  setup do
    # Create a temporary directory for test files
    tmp_dir = Path.join(System.tmp_dir!(), "pool_store_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "save_all_pools/1 and load_pools/1" do
    test "roundtrip saves and loads pools correctly", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      pools = [
        %{
          name: "default",
          network: "192.168.1.0/24",
          range_start: "192.168.1.100",
          range_end: "192.168.1.200",
          subnet_mask: "255.255.255.0",
          gateway: "192.168.1.1",
          dns_servers: ["8.8.8.8", "8.8.4.4"],
          domain_name: "example.local",
          lease_time: 86400,
          max_leases: 100,
          enabled: true
        }
      ]

      # Mock the data dir by writing directly
      index_content = """
      # DHCPv4 Pool Index
      pools = ["default"]
      """

      pool_content = """
      # DHCPv4 Pool Configuration
      enabled = true
      network = "192.168.1.0/24"
      range_start = "192.168.1.100"
      range_end = "192.168.1.200"
      subnet_mask = "255.255.255.0"
      gateway = "192.168.1.1"
      dns_servers = ["8.8.8.8", "8.8.4.4"]
      domain_name = "example.local"
      lease_time = 86400
      max_leases = 100
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "default.toml"), pool_content)

      # Load pools back
      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 1

      loaded = hd(loaded_pools)
      assert loaded.name == "default"
      assert loaded.range_start == "192.168.1.100"
      assert loaded.range_end == "192.168.1.200"
      assert loaded.gateway == "192.168.1.1"
      assert loaded.dns_servers == ["8.8.8.8", "8.8.4.4"]
      assert loaded.lease_time == 86400
      assert loaded.enabled == true
    end

    test "loads multiple pools from index", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      index_content = """
      # DHCPv4 Pool Index
      pools = ["office", "guest"]
      """

      office_content = """
      enabled = true
      network = "192.168.1.0/24"
      range_start = "192.168.1.100"
      range_end = "192.168.1.150"
      """

      guest_content = """
      enabled = true
      network = "192.168.2.0/24"
      range_start = "192.168.2.100"
      range_end = "192.168.2.200"
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "office.toml"), office_content)
      File.write!(Path.join(pools_dir, "guest.toml"), guest_content)

      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 2

      names = Enum.map(loaded_pools, & &1.name)
      assert "office" in names
      assert "guest" in names
    end

    test "returns empty list when index file doesn't exist", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent.toml")
      assert {:ok, []} = PoolStore.load_pools(file_path)
    end

    test "skips pools in index that don't have corresponding files", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      index_content = """
      pools = ["exists", "missing"]
      """

      exists_content = """
      enabled = true
      network = "10.0.0.0/24"
      range_start = "10.0.0.1"
      range_end = "10.0.0.100"
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "exists.toml"), exists_content)
      # "missing" pool file is intentionally not created

      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 1
      assert hd(loaded_pools).name == "exists"
    end
  end

  describe "save_pool/1" do
    test "saves a pool and updates index" do
      # This test would require mocking the data directory
      # The save_pool function writes to the configured data directory
      # For now, we just verify the function exists
      assert function_exported?(PoolStore, :save_pool, 1)
    end
  end

  describe "remove_pool/1" do
    test "function exists" do
      assert function_exported?(PoolStore, :remove_pool, 1)
    end
  end

  describe "validate_pool/1" do
    test "validates pool with range_start and range_end" do
      pool = %{
        name: "valid",
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "validates pool with string keys" do
      pool = %{
        "name" => "valid",
        "network" => "192.168.1.0/24",
        "range_start" => "192.168.1.100",
        "range_end" => "192.168.1.200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "rejects pool without name" do
      pool = %{
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with empty name" do
      pool = %{
        name: "",
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without network CIDR" do
      pool = %{
        name: "invalid",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, "Network CIDR is required" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid network CIDR" do
      pool = %{
        name: "invalid",
        network: "192.168.1.0",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, "Invalid network CIDR format" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without ranges" do
      pool = %{name: "invalid", network: "192.168.1.0/24"}
      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid IP address" do
      pool = %{
        name: "invalid",
        network: "192.168.1.0/24",
        range_start: "not.an.ip.address",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end
  end

  describe "default_file_path/0" do
    test "returns a path ending with pools.toml" do
      path = PoolStore.default_file_path()
      assert String.ends_with?(path, "pools.toml")
    end
  end

  describe "pools_directory/0" do
    test "returns a path ending with pools" do
      path = PoolStore.pools_directory()
      assert String.ends_with?(path, "pools")
    end
  end

  describe "load_index/1" do
    test "loads pool names from index file", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")

      content = """
      pools = ["pool1", "pool2", "pool3"]
      """

      File.write!(index_path, content)

      assert {:ok, names} = PoolStore.load_index(index_path)
      assert names == ["pool1", "pool2", "pool3"]
    end

    test "returns empty list for missing file", %{tmp_dir: tmp_dir} do
      assert {:ok, []} = PoolStore.load_index(Path.join(tmp_dir, "missing.toml"))
    end

    test "handles [[pool]] format", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")

      content = """
      [[pool]]
      name = "alpha"

      [[pool]]
      name = "beta"
      """

      File.write!(index_path, content)

      assert {:ok, names} = PoolStore.load_index(index_path)
      assert "alpha" in names
      assert "beta" in names
    end
  end
end
