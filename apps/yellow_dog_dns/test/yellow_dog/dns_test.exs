defmodule YellowDog.DnsTest do
  use ExUnit.Case

  test "DNS supervisor is running" do
    # Start the main application to ensure DNS supervisor is running
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that DNS supervisor is running
    pid = Process.whereis(YellowDog.Dns)
    assert pid != nil
    assert Process.alive?(pid)
  end

  test "DNS supervisor has children" do
    # Start the main application to ensure DNS supervisor is running
    {:ok, _pid} = Application.ensure_all_started(:yellow_dog)

    # Check that ViewManager is started
    assert Process.whereis(YellowDog.Dns.ViewManager) != nil

    # Check that NameResolver is started
    assert Process.whereis(YellowDog.Dns.NameResolver) != nil
  end
end
