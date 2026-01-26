defmodule YellowDog.Dns.ConnectionManagerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.ConnectionManager

  # Test IP addresses
  @client_ip {192, 168, 1, 100}
  @client_port 12345

  describe "start_link/1" do
    test "starts with default name" do
      name = :"TestConnectionManager_#{System.unique_integer([:positive])}"
      {:ok, pid} = ConnectionManager.start_link(name: name)

      assert Process.alive?(pid)
      assert Process.whereis(name) == pid

      GenServer.stop(pid)
    end

    test "starts multiple managers with different names" do
      name1 = :"TestCM1_#{System.unique_integer([:positive])}"
      name2 = :"TestCM2_#{System.unique_integer([:positive])}"

      {:ok, pid1} = ConnectionManager.start_link(name: name1)
      {:ok, pid2} = ConnectionManager.start_link(name: name2)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end

  describe "stats/1" do
    setup do
      name = :"TestCM_stats_#{System.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({ConnectionManager, name: name})
      %{manager: pid, name: name}
    end

    test "returns empty stats for new manager", %{manager: manager} do
      stats = ConnectionManager.stats(manager)

      assert stats.active_connections == 0
      assert stats.total_children == 0
    end
  end

  describe "count_connections/1" do
    setup do
      name = :"TestCM_count_#{System.unique_integer([:positive])}"
      {:ok, pid} = start_supervised({ConnectionManager, name: name})
      %{manager: pid, name: name}
    end

    test "returns 0 for new manager", %{manager: manager} do
      assert ConnectionManager.count_connections(manager) == 0
    end
  end

  describe "start_connection/5" do
    setup do
      name = :"TestCM_conn_#{System.unique_integer([:positive])}"
      {:ok, manager} = start_supervised({ConnectionManager, name: name})

      # Create a mock handler process
      handler = spawn_link(fn -> handler_loop() end)

      %{manager: manager, handler: handler}
    end

    test "starts a connection process", %{manager: manager, handler: handler} do
      result = ConnectionManager.start_connection(manager, handler, @client_ip, @client_port, [])

      assert {:ok, conn_pid} = result
      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # Verify connection count increased
      assert ConnectionManager.count_connections(manager) == 1
    end

    test "starts multiple connection processes", %{manager: manager, handler: handler} do
      {:ok, conn1} = ConnectionManager.start_connection(manager, handler, @client_ip, 12345, [])
      {:ok, conn2} = ConnectionManager.start_connection(manager, handler, @client_ip, 12346, [])
      {:ok, conn3} = ConnectionManager.start_connection(manager, handler, @client_ip, 12347, [])

      assert is_pid(conn1)
      assert is_pid(conn2)
      assert is_pid(conn3)
      assert conn1 != conn2
      assert conn2 != conn3

      assert ConnectionManager.count_connections(manager) == 3
    end

    test "stats reflect active connections", %{manager: manager, handler: handler} do
      {:ok, _} = ConnectionManager.start_connection(manager, handler, @client_ip, 12345, [])
      {:ok, _} = ConnectionManager.start_connection(manager, handler, @client_ip, 12346, [])

      stats = ConnectionManager.stats(manager)
      assert stats.active_connections == 2
      assert stats.total_children == 2
    end

    test "connection process is temporary (removed when it exits)", %{
      manager: manager,
      handler: handler
    } do
      {:ok, conn_pid} =
        ConnectionManager.start_connection(manager, handler, @client_ip, @client_port, [])

      assert ConnectionManager.count_connections(manager) == 1

      # Stop the connection process
      GenServer.stop(conn_pid, :normal)

      # Give some time for cleanup
      Process.sleep(10)

      # Count should decrease
      assert ConnectionManager.count_connections(manager) == 0
    end

    test "passes options to connection process", %{manager: manager, handler: handler} do
      opts = [query_timeout: 10_000, socket: self()]

      {:ok, conn_pid} =
        ConnectionManager.start_connection(manager, handler, @client_ip, @client_port, opts)

      assert Process.alive?(conn_pid)
    end
  end

  describe "different client IPs" do
    setup do
      name = :"TestCM_ips_#{System.unique_integer([:positive])}"
      {:ok, manager} = start_supervised({ConnectionManager, name: name})
      handler = spawn_link(fn -> handler_loop() end)
      %{manager: manager, handler: handler}
    end

    test "handles IPv4 addresses", %{manager: manager, handler: handler} do
      {:ok, conn} =
        ConnectionManager.start_connection(manager, handler, {192, 168, 1, 1}, 12345, [])

      assert Process.alive?(conn)
    end

    test "handles IPv6 addresses", %{manager: manager, handler: handler} do
      ipv6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      {:ok, conn} = ConnectionManager.start_connection(manager, handler, ipv6, 12345, [])
      assert Process.alive?(conn)
    end

    test "handles loopback addresses", %{manager: manager, handler: handler} do
      {:ok, conn} =
        ConnectionManager.start_connection(manager, handler, {127, 0, 0, 1}, 12345, [])

      assert Process.alive?(conn)
    end
  end

  # Helper: simple handler loop that stays alive
  defp handler_loop do
    receive do
      {:dns_response, _query_id, _response} ->
        handler_loop()

      {:dns_raw_response, _query_id, _data} ->
        handler_loop()

      :stop ->
        :ok

      _ ->
        handler_loop()
    after
      30_000 ->
        :ok
    end
  end
end
