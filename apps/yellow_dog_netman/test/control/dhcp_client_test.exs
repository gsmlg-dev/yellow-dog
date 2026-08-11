defmodule YellowDog.Netman.Control.DhcpClientTest do
  use ExUnit.Case, async: false

  alias YellowDog.DhcpClient.Lease
  alias YellowDog.Netman.Control.DhcpClient, as: DhcpControl
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @revision String.duplicate("a", 64)

  setup do
    previous = Application.get_env(:yellow_dog_netman, DhcpControl)
    start_supervised!(DhcpControlTestRuntime)

    Application.put_env(:yellow_dog_netman, DhcpControl,
      netman: DhcpControlTestRuntime,
      dhcp_client: DhcpControlTestRuntime
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:yellow_dog_netman, DhcpControl)
      else
        Application.put_env(:yellow_dog_netman, DhcpControl, previous)
      end
    end)

    :ok
  end

  test "reads the DHCP FSM only through the owning profile and interface" do
    configure_bound_connection()

    assert {:ok, result} =
             DhcpControl.dispatch("netman.dhcp_client.fsm.get", connection_ref())

    assert result == %{
             "profile_id" => "office",
             "interface" => "eth0",
             "state" => "bound"
           }

    assert_valid_result("netman.dhcp_client.fsm.get", result)

    assert {:error, %Error{code: :not_found}} =
             DhcpControl.dispatch(
               "netman.dhcp_client.fsm.get",
               %{"profile_id" => "other", "interface" => "eth0"}
             )
  end

  test "lists only active leases with their owning composite connection identity" do
    lease = configure_bound_connection()
    assert {:ok, release_revision} = DhcpControl.current(release_operation(), connection_ref())

    assert {:ok, result} =
             DhcpControl.dispatch("netman.dhcp_client.leases.list", %{})

    assert result["items"] == [
             %{
               "profile_id" => "office",
               "interface" => "eth0",
               "address" => "192.0.2.20",
               "expires_at" => lease |> Lease.expires_at() |> DateTime.to_iso8601(),
               "revision" => release_revision
             }
           ]

    assert_valid_result("netman.dhcp_client.leases.list", result)
  end

  test "releases a lease through YellowDog.DhcpClient and returns the typed result" do
    configure_bound_connection()
    assert {:ok, current_revision} = DhcpControl.current(release_operation(), connection_ref())

    assert {:ok, result} =
             DhcpControl.dispatch(
               release_operation(),
               connection_ref(),
               mutation_context(current_revision)
             )

    assert result == %{
             "family" => "ipv4",
             "lease_id" => "office.eth0",
             "address" => "192.0.2.20",
             "released" => true
           }

    assert_receive {:released, "eth0"}
    assert_valid_result(release_operation(), result)
  end

  test "rejects stale revisions, absent FSMs, missing leases, and release failures" do
    configure_bound_connection()

    assert {:error, %Error{code: :conflict}} =
             DhcpControl.dispatch(
               release_operation(),
               connection_ref(),
               mutation_context(@revision)
             )

    DhcpControlTestRuntime.configure(connections: [], snapshots: %{})

    assert {:error, %Error{code: :not_found}} =
             DhcpControl.dispatch("netman.dhcp_client.fsm.get", connection_ref())

    DhcpControlTestRuntime.configure(
      connections: [owner_connection()],
      snapshots: %{"eth0" => {:ok, %{interface: "eth0", state: :init, lease: nil}}}
    )

    assert {:error, %Error{code: :not_found}} =
             DhcpControl.current(release_operation(), connection_ref())

    expired_lease = %Lease{
      ip: {192, 0, 2, 20},
      obtained_at: ~U[2020-01-01 00:00:00Z],
      lease_time: 60
    }

    DhcpControlTestRuntime.configure(
      snapshots: %{
        "eth0" => {:ok, %{interface: "eth0", state: :bound, lease: expired_lease}}
      }
    )

    assert {:error, %Error{code: :not_found}} =
             DhcpControl.current(release_operation(), connection_ref())

    assert {:ok, %{"items" => []}} =
             DhcpControl.dispatch("netman.dhcp_client.leases.list", %{})

    configure_bound_connection(release: {:error, :not_found})
    assert {:ok, current_revision} = DhcpControl.current(release_operation(), connection_ref())

    assert {:error, %Error{code: :not_found}} =
             DhcpControl.dispatch(
               release_operation(),
               connection_ref(),
               mutation_context(current_revision)
             )
  end

  test "rejects unsupported DHCP mutations" do
    assert {:error, %Error{code: :unsupported}} =
             DhcpControl.dispatch("netman.dhcp_client.connections.renew", %{})
  end

  defp configure_bound_connection(overrides \\ []) do
    test_pid = self()

    lease = %Lease{
      ip: {192, 0, 2, 20},
      obtained_at: DateTime.utc_now() |> DateTime.truncate(:second),
      lease_time: 3_600
    }

    DhcpControlTestRuntime.configure(
      connections: [owner_connection()],
      snapshots: %{
        "eth0" => {:ok, %{interface: "eth0", state: :bound, lease: lease}}
      },
      release:
        Keyword.get(overrides, :release, fn interface ->
          send(test_pid, {:released, interface})
          :ok
        end)
    )

    lease
  end

  defp owner_connection,
    do: %{profile_id: "office", interface: "eth0", state: :activated}

  defp connection_ref,
    do: %{"profile_id" => "office", "interface" => "eth0"}

  defp release_operation,
    do: "netman.dhcp_client.connections.release_lease"

  defp mutation_context(revision) do
    %{
      expected_revision: revision,
      current_revision: revision,
      precondition: {:revision, revision},
      config_version: nil
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = NetmanOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end
end

defmodule DhcpControlTestRuntime do
  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{connections: [], snapshots: %{}, release: {:error, :not_found}} end,
      name: __MODULE__
    )
  end

  def configure(options) do
    Agent.update(__MODULE__, fn state ->
      Enum.reduce(options, state, fn {key, value}, acc -> Map.put(acc, key, value) end)
    end)
  end

  def list_connections, do: Agent.get(__MODULE__, & &1.connections)

  def connection(interface) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.snapshots, interface, {:error, :not_found})
    end)
  end

  def release(interface) do
    case Agent.get(__MODULE__, & &1.release) do
      callback when is_function(callback, 1) -> callback.(interface)
      result -> result
    end
  end
end
