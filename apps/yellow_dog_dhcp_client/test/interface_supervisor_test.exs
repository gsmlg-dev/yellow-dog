defmodule YellowDog.DhcpClient.InterfaceSupervisorTest do
  use ExUnit.Case, async: false

  alias YellowDog.DhcpClient.{DhcpSocket, InterfaceSupervisor, LeaseStore, StateMachine}

  # Mock socket that always succeeds — no network required.
  defmodule NoOpSocketImpl do
    @moduledoc false
    @behaviour DhcpSocket

    @impl true
    def open(_interface, _owner), do: {:ok, make_ref()}
    @impl true
    def send_broadcast(_ref, _packet), do: :ok
    @impl true
    def send_unicast(_ref, _dest, _packet), do: :ok
    @impl true
    def send_arp_probe(_ref, _ip), do: {:error, :not_supported}
    @impl true
    def close(_ref), do: :ok
  end

  @mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

  defp unique_interface do
    "ifsup_test_#{System.unique_integer([:positive])}"
  end

  defp start_supervisor(interface, extra_opts \\ []) do
    lease_dir =
      Path.join(System.tmp_dir!(), "yd_ifsup_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(lease_dir)

    opts =
      [
        interface: interface,
        mac: @mac,
        socket_impl: NoOpSocketImpl,
        config: %{dad_enabled: false, lease_dir: lease_dir}
      ] ++ extra_opts

    {:ok, sup_pid} = InterfaceSupervisor.start_link(opts)

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :shutdown, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(lease_dir)
    end)

    {sup_pid, interface, lease_dir}
  end

  defp child_pids(sup_pid) do
    children = Supervisor.which_children(sup_pid)
    # Children are returned in reverse start order by which_children
    socket_pid = find_child(children, DhcpSocket)
    store_pid = find_child(children, LeaseStore)
    fsm_pid = find_child(children, StateMachine)
    {socket_pid, store_pid, fsm_pid}
  end

  defp find_child(children, mod) do
    case Enum.find(children, fn {id, _pid, _type, _mods} -> id == mod end) do
      {_, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  # -- startup --

  describe "startup" do
    test "starts all three children in order" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {socket_pid, store_pid, fsm_pid} = child_pids(sup_pid)

      assert is_pid(socket_pid)
      assert is_pid(store_pid)
      assert is_pid(fsm_pid)
      assert Process.alive?(socket_pid)
      assert Process.alive?(store_pid)
      assert Process.alive?(fsm_pid)
    end

    test "children are registered via Registry" do
      iface = unique_interface()
      {_sup_pid, _iface, _dir} = start_supervisor(iface)

      assert [{socket_pid, _}] =
               Registry.lookup(YellowDog.DhcpClient.Registry, {:socket, iface})

      assert [{store_pid, _}] =
               Registry.lookup(YellowDog.DhcpClient.Registry, {:store, iface})

      assert [{fsm_pid, _}] = Registry.lookup(YellowDog.DhcpClient.Registry, {:fsm, iface})

      assert is_pid(socket_pid)
      assert is_pid(store_pid)
      assert is_pid(fsm_pid)
    end

    test "FSM starts in :init state" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)
      {_socket_pid, _store_pid, fsm_pid} = child_pids(sup_pid)

      {state, _data} = StateMachine.status(fsm_pid)
      assert state == :init
    end
  end

  # -- rest_for_one: socket crash --

  describe "rest_for_one: socket crash" do
    test "socket crash restarts LeaseStore and StateMachine" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {socket_pid, store_pid, fsm_pid} = child_pids(sup_pid)

      # Monitor all three to detect restarts
      socket_ref = Process.monitor(socket_pid)
      store_ref = Process.monitor(store_pid)
      fsm_ref = Process.monitor(fsm_pid)

      # Kill the socket process
      Process.exit(socket_pid, :kill)

      # Wait for the socket to die
      assert_receive {:DOWN, ^socket_ref, :process, ^socket_pid, :killed}, 2_000
      # LeaseStore and FSM should also be terminated (rest_for_one)
      assert_receive {:DOWN, ^store_ref, :process, ^store_pid, _reason}, 2_000
      assert_receive {:DOWN, ^fsm_ref, :process, ^fsm_pid, _reason}, 2_000

      # Wait for supervisor to restart children
      Process.sleep(200)

      # All three children should be alive again with new PIDs
      {new_socket, new_store, new_fsm} = child_pids(sup_pid)
      assert is_pid(new_socket) and Process.alive?(new_socket)
      assert is_pid(new_store) and Process.alive?(new_store)
      assert is_pid(new_fsm) and Process.alive?(new_fsm)

      # PIDs should have changed
      assert new_socket != socket_pid
      assert new_store != store_pid
      assert new_fsm != fsm_pid
    end

    test "FSM re-enters :init after socket crash" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {socket_pid, _store_pid, _fsm_pid} = child_pids(sup_pid)

      Process.exit(socket_pid, :kill)
      Process.sleep(300)

      {_new_socket, _new_store, new_fsm} = child_pids(sup_pid)
      {state, _data} = StateMachine.status(new_fsm)
      assert state == :init
    end
  end

  # -- rest_for_one: LeaseStore crash --

  describe "rest_for_one: LeaseStore crash" do
    test "LeaseStore crash restarts FSM but socket stays alive" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {socket_pid, store_pid, fsm_pid} = child_pids(sup_pid)

      store_ref = Process.monitor(store_pid)
      fsm_ref = Process.monitor(fsm_pid)

      # Kill the LeaseStore
      Process.exit(store_pid, :kill)

      assert_receive {:DOWN, ^store_ref, :process, ^store_pid, :killed}, 2_000
      # FSM should also be terminated (rest_for_one: later children restart)
      assert_receive {:DOWN, ^fsm_ref, :process, ^fsm_pid, _reason}, 2_000

      Process.sleep(200)

      {new_socket, new_store, new_fsm} = child_pids(sup_pid)

      # Socket should be the SAME pid (not restarted)
      assert new_socket == socket_pid
      assert Process.alive?(new_socket)

      # LeaseStore and FSM should be new
      assert new_store != store_pid
      assert new_fsm != fsm_pid
      assert Process.alive?(new_store)
      assert Process.alive?(new_fsm)
    end
  end

  # -- rest_for_one: FSM crash --

  describe "rest_for_one: FSM crash" do
    test "FSM crash leaves socket and LeaseStore alive" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {socket_pid, store_pid, fsm_pid} = child_pids(sup_pid)

      fsm_ref = Process.monitor(fsm_pid)

      # Kill the FSM
      Process.exit(fsm_pid, :kill)
      assert_receive {:DOWN, ^fsm_ref, :process, ^fsm_pid, :killed}, 2_000

      Process.sleep(200)

      {new_socket, new_store, new_fsm} = child_pids(sup_pid)

      # Socket and LeaseStore should be the SAME pids
      assert new_socket == socket_pid
      assert new_store == store_pid
      assert Process.alive?(new_socket)
      assert Process.alive?(new_store)

      # FSM should be new
      assert new_fsm != fsm_pid
      assert Process.alive?(new_fsm)
    end

    test "FSM crash resets state to :init" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {_socket_pid, _store_pid, fsm_pid} = child_pids(sup_pid)

      fsm_ref = Process.monitor(fsm_pid)
      Process.exit(fsm_pid, :kill)
      assert_receive {:DOWN, ^fsm_ref, :process, ^fsm_pid, :killed}, 2_000

      Process.sleep(200)

      {_new_socket, _new_store, new_fsm} = child_pids(sup_pid)
      {state, _data} = StateMachine.status(new_fsm)
      assert state == :init
    end
  end

  # -- LeaseStore persistence across FSM restarts --

  describe "LeaseStore persistence across FSM restart" do
    test "lease stored before FSM crash is still available after restart" do
      iface = unique_interface()
      {sup_pid, _iface, _dir} = start_supervisor(iface)

      {_socket_pid, store_pid, fsm_pid} = child_pids(sup_pid)

      # Store a lease in the LeaseStore
      test_lease = %YellowDog.DhcpClient.Lease{
        ip: {192, 168, 1, 100},
        subnet_mask: {255, 255, 255, 0},
        router: {192, 168, 1, 1},
        dns_servers: [{8, 8, 8, 8}],
        server_ip: {192, 168, 1, 1},
        lease_time: 3600,
        t1: 1800,
        t2: 3150,
        obtained_at: DateTime.utc_now(),
        xid: 12345
      }

      :ok = LeaseStore.store(store_pid, iface, test_lease)
      assert {:ok, _} = LeaseStore.lookup(store_pid, iface)

      # Kill only the FSM — LeaseStore survives (rest_for_one)
      fsm_ref = Process.monitor(fsm_pid)
      Process.exit(fsm_pid, :kill)
      assert_receive {:DOWN, ^fsm_ref, :process, ^fsm_pid, :killed}, 2_000
      Process.sleep(200)

      # The same LeaseStore should still have the lease
      {_new_socket, same_store, _new_fsm} = child_pids(sup_pid)
      assert same_store == store_pid
      assert {:ok, loaded} = LeaseStore.lookup(same_store, iface)
      assert loaded.ip == {192, 168, 1, 100}
      assert loaded.xid == 12345
    end
  end
end
