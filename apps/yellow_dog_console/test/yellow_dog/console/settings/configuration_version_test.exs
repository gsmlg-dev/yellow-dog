defmodule YellowDog.Console.Settings.ConfigurationVersionTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.Settings.ConfigurationVersion.

  Tests cover:
  - Agent lifecycle (start_link)
  - Version tracking
  - File timestamp handling
  - Compare-and-swap operations
  - Version increment

  Note: These tests work with the application-managed ConfigurationVersion when it's
  running, or start their own when running in isolation. The tests avoid stopping
  the application-managed process to prevent interference with other test modules.
  """
  use ExUnit.Case, async: false

  alias YellowDog.Console.Settings.ConfigurationVersion

  # Test file path - unique per test run to avoid conflicts
  @test_file Path.join(System.tmp_dir!(), "config_version_test_#{:rand.uniform(100_000)}.toml")

  # Helper to ensure the agent is running (either from app or started fresh)
  # Does NOT stop existing application-managed process
  defp ensure_agent_running do
    case Process.whereis(ConfigurationVersion) do
      nil ->
        # Start using start_supervised! for proper test lifecycle management
        start_supervised!(ConfigurationVersion)

      pid ->
        # Use existing application-managed process
        pid
    end
  end

  setup do
    # Create a test file
    File.write!(@test_file, "# Test config\n")

    on_exit(fn ->
      # Cleanup test file only - don't stop agent
      File.rm(@test_file)
    end)

    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ConfigurationVersion)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(ConfigurationVersion)
      assert Kernel.function_exported?(ConfigurationVersion, :start_link, 1)
    end

    test "exports get_version/1" do
      Code.ensure_loaded!(ConfigurationVersion)
      assert Kernel.function_exported?(ConfigurationVersion, :get_version, 1)
    end

    test "exports compare_and_swap/3" do
      Code.ensure_loaded!(ConfigurationVersion)
      assert Kernel.function_exported?(ConfigurationVersion, :compare_and_swap, 3)
    end

    test "exports increment_version/0" do
      Code.ensure_loaded!(ConfigurationVersion)
      assert Kernel.function_exported?(ConfigurationVersion, :increment_version, 0)
    end
  end

  describe "start_link/1" do
    test "starts the agent when not already running" do
      # This test only works when run in isolation (without the application)
      # When running with full application, the agent is already started
      pid = ensure_agent_running()

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers with module name" do
      pid = ensure_agent_running()

      assert Process.whereis(ConfigurationVersion) == pid
    end

    test "agent is accessible after starting" do
      _pid = ensure_agent_running()

      # Agent should be able to respond to get_version
      version_info = ConfigurationVersion.get_version(@test_file)
      assert is_map(version_info)
    end
  end

  describe "get_version/1" do
    test "returns version info map" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      assert is_map(version_info)
      assert Map.has_key?(version_info, :version)
      assert Map.has_key?(version_info, :timestamp)
      assert Map.has_key?(version_info, :file_path)
    end

    test "returns current version as non-negative integer" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      assert is_integer(version_info.version)
      assert version_info.version >= 0
    end

    test "returns file path" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      assert version_info.file_path == @test_file
    end

    test "returns file timestamp" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      assert is_integer(version_info.timestamp)
      assert version_info.timestamp > 0
    end

    test "returns 0 timestamp for non-existent file" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version("/non/existent/file.toml")

      assert version_info.timestamp == 0
    end
  end

  describe "compare_and_swap/3" do
    test "succeeds with matching version and timestamp" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      result =
        ConfigurationVersion.compare_and_swap(
          @test_file,
          version_info.version,
          version_info.timestamp
        )

      assert result == :ok
    end

    test "increments version on success" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      :ok =
        ConfigurationVersion.compare_and_swap(
          @test_file,
          version_info.version,
          version_info.timestamp
        )

      new_version_info = ConfigurationVersion.get_version(@test_file)
      assert new_version_info.version == version_info.version + 1
    end

    test "returns error for version mismatch" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      result =
        ConfigurationVersion.compare_and_swap(
          @test_file,
          version_info.version + 1,
          version_info.timestamp
        )

      assert result == {:error, :version_mismatch}
    end

    test "returns error for file modification" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      # Modify the file - need to wait for mtime to change (1 second resolution)
      Process.sleep(1100)
      File.write!(@test_file, "# Modified config\n")

      result =
        ConfigurationVersion.compare_and_swap(
          @test_file,
          version_info.version,
          version_info.timestamp
        )

      assert result == {:error, :file_modified}
    end

    test "does not increment version on failure" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      # Try with wrong version
      {:error, :version_mismatch} =
        ConfigurationVersion.compare_and_swap(
          @test_file,
          version_info.version + 999,
          version_info.timestamp
        )

      # Version should remain unchanged
      new_version_info = ConfigurationVersion.get_version(@test_file)
      assert new_version_info.version == version_info.version
    end
  end

  describe "increment_version/0" do
    test "increments the version" do
      _pid = ensure_agent_running()

      initial_version = ConfigurationVersion.get_version(@test_file).version

      :ok = ConfigurationVersion.increment_version()

      new_version = ConfigurationVersion.get_version(@test_file).version
      assert new_version == initial_version + 1
    end

    test "can be called multiple times" do
      _pid = ensure_agent_running()

      initial_version = ConfigurationVersion.get_version(@test_file).version

      :ok = ConfigurationVersion.increment_version()
      :ok = ConfigurationVersion.increment_version()
      :ok = ConfigurationVersion.increment_version()

      new_version = ConfigurationVersion.get_version(@test_file).version
      assert new_version == initial_version + 3
    end
  end

  describe "concurrent access" do
    test "handles concurrent get_version calls" do
      _pid = ensure_agent_running()

      # Get initial version before concurrent calls
      initial_version = ConfigurationVersion.get_version(@test_file).version

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> ConfigurationVersion.get_version(@test_file) end)
        end

      results = Task.await_many(tasks, 5000)

      Enum.each(results, fn version_info ->
        assert is_map(version_info)
        # All concurrent reads should see the same version
        assert version_info.version >= initial_version
      end)
    end

    test "handles concurrent increment_version calls" do
      _pid = ensure_agent_running()

      # Get initial version before concurrent increments
      initial_version = ConfigurationVersion.get_version(@test_file).version

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> ConfigurationVersion.increment_version() end)
        end

      Task.await_many(tasks, 5000)

      version_info = ConfigurationVersion.get_version(@test_file)
      # Version should have increased by 10 from the initial
      assert version_info.version == initial_version + 10
    end

    test "compare_and_swap is atomic" do
      _pid = ensure_agent_running()

      version_info = ConfigurationVersion.get_version(@test_file)

      # Launch concurrent CAS attempts with same expected version
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            ConfigurationVersion.compare_and_swap(
              @test_file,
              version_info.version,
              version_info.timestamp
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Only one should succeed
      successes = Enum.count(results, &(&1 == :ok))
      failures = Enum.count(results, &(&1 == {:error, :version_mismatch}))

      assert successes == 1
      assert failures == 4
    end
  end
end
