defmodule YellowDog.Dhcpv4Test do
  use ExUnit.Case

  test "DHCPv4 supervisor is running" do
    # Start the main application to ensure DHCPv4 supervisor is running
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that DHCPv4 supervisor is running
    pid = Process.whereis(YellowDog.Dhcpv4)
    assert pid != nil
    assert Process.alive?(pid)
  end
end
