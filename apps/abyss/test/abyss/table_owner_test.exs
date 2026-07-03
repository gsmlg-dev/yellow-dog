defmodule Abyss.TableOwnerTest do
  use ExUnit.Case, async: false

  alias Abyss.ServerConfig

  test "shared ETS tables are owned by Abyss.TableOwner" do
    owner = Process.whereis(Abyss.TableOwner)
    assert is_pid(owner)

    # Other tests may have deleted the tables; lazy recreation from this
    # (transient) test process must still hand ownership to the TableOwner.
    Abyss.Listener.ensure_info_table_exists()
    Abyss.Telemetry.init_metrics()

    assert :ets.info(:abyss_listener_info, :owner) == owner
    assert :ets.info(:abyss_telemetry_metrics, :owner) == owner
  end

  test "listener info cache survives a listener crash" do
    config = ServerConfig.new(handler_module: Abyss.TestHandler, port: 0)

    {:ok, l1} = Abyss.Listener.start_link({"table-owner-test-1", self(), config})
    {:ok, l2} = Abyss.Listener.start_link({"table-owner-test-2", self(), config})

    assert {:ok, _info} = Abyss.Listener.listener_info_cached(l1)
    assert {:ok, _info} = Abyss.Listener.listener_info_cached(l2)

    # Kill one listener; the shared table (and the other listener's cached
    # info) must survive since the table is owned by Abyss.TableOwner.
    Process.unlink(l1)
    ref = Process.monitor(l1)
    Process.exit(l1, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert :ets.whereis(:abyss_listener_info) != :undefined
    assert {:ok, _info} = Abyss.Listener.listener_info_cached(l2)

    Abyss.Listener.stop(l2)
  end
end
