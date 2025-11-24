defmodule YellowDogTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure application is stopped before each test
    Application.stop(:yellow_dog)
    Process.sleep(100)

    on_exit(fn ->
      Application.stop(:yellow_dog)
    end)

    :ok
  end

  test "starts application with core services" do
    # Start the application
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that core supervisor and config are started
    assert Process.whereis(YellowDog.Supervisor) != nil
    assert Process.whereis(YellowDog.Config) != nil

    # In test environment, DNS and mDNS are disabled by default
    # DHCPv4 should be started on non-privileged port
    # DHCPv6 is disabled in test mode
    # Services are conditionally started based on configuration
  end

  test "application can be stopped" do
    # Start the application
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Verify it's running
    assert Process.whereis(YellowDog.Supervisor) != nil

    # Stop the application
    :ok = Application.stop(:yellow_dog)

    # Give some time for shutdown
    Process.sleep(100)

    # Check that main supervisor is stopped
    assert Process.whereis(YellowDog.Supervisor) == nil
  end

  test "configuration is accessible" do
    # Start the application
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Test that config is available
    config = YellowDog.get_all_config()
    assert is_map(config)

    # Config should have core section
    assert Map.has_key?(config, "core")
  end
end
