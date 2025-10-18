defmodule YellowDog.MdnsTest do
  use ExUnit.Case

  test "mDNS supervisor is running" do
    # Start the main application to ensure mDNS supervisor is running
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that mDNS supervisor is running
    pid = Process.whereis(YellowDog.Mdns)
    assert pid != nil
    assert Process.alive?(pid)
  end
end
