defmodule YellowDog.Dhcpv4Test do
  use ExUnit.Case

  @tag :privileged_port
  test "DHCPv4 supervisor can start and stop" do
    # Start the DHCPv4 supervisor directly with test configuration
    config = [
      pools: [
        %{
          "name" => "test",
          "range_start" => {192, 168, 1, 100},
          "range_end" => {192, 168, 1, 200},
          "subnet_mask" => {255, 255, 255, 0},
          "gateway" => {192, 168, 1, 1},
          "dns_servers" => [{8, 8, 8, 8}],
          "domain_name" => "test.local",
          "lease_time" => 3600
        }
      ]
    ]

    {:ok, pid} = YellowDog.Dhcpv4.start_link(config)
    assert Process.alive?(pid)

    # Stop the supervisor
    :ok = Supervisor.stop(pid)
    refute Process.alive?(pid)
  end
end
