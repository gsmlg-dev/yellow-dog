defmodule YellowDogTest do
  use ExUnit.Case

  test "starts application with all children" do
    # Start the application
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that all supervisors are started
    assert Process.whereis(YellowDog.Supervisor) != nil
    assert Process.whereis(YellowDog.Config) != nil
    assert Process.whereis(YellowDog.Dns) != nil
    assert Process.whereis(YellowDog.Dhcpv4) != nil
    assert Process.whereis(YellowDog.Dhcpv6) != nil
    assert Process.whereis(YellowDog.Mdns) != nil

    # Check that DNS children are started
    assert Process.whereis(YellowDog.Dns.ViewManager) != nil
    assert Process.whereis(YellowDog.Dns.NameResolver) != nil
  end

  test "application can be stopped" do
    # Start the application
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

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
  end
end
