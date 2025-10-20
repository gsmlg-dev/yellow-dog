defmodule YellowDog.Dhcpv6Test do
  use ExUnit.Case

  test "DHCPv6 modules are available" do
    # Test that DHCPv6 modules can be loaded and used
    assert Code.ensure_loaded?(YellowDog.Dhcpv6) == true
    assert function_exported?(YellowDog.Dhcpv6, :start_link, 1)
    assert function_exported?(YellowDog.Dhcpv6, :child_spec, 1)
  end

  test "DHCPv6 supervisor is not running when disabled" do
    # Start the main application - DHCPv6 should be disabled in test environment
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that DHCPv6 supervisor is not running (service disabled in test env)
    pid = Process.whereis(YellowDog.Dhcpv6)
    assert pid == nil
  end
end
