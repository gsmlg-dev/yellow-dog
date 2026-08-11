defmodule YellowDog.Netman.Control.RuntimeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Control.Runtime
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  setup do
    runtime_state = :sys.get_state(RuntimeState)

    on_exit(fn ->
      :sys.replace_state(RuntimeState, fn _state -> runtime_state end)
    end)
  end

  test "reports only capabilities enabled by the runtime feature set" do
    replace_runtime_state(%{
      apply_mode: :managed,
      features: %{
        interfaces: true,
        dhcp_client: false,
        dns_client: false,
        routes: true,
        link_state: true,
        vpn: false
      }
    })

    assert {:ok, %{"capabilities" => capabilities} = result} =
             Runtime.dispatch("netman.runtime.capabilities.get", %{})

    assert capabilities == Enum.sort(capabilities)
    assert "runtime.apply_mode" in capabilities
    assert "profiles.read" in capabilities
    assert "network.links.read" in capabilities
    assert "network.addresses.read" in capabilities
    assert "network.routes.read" in capabilities
    assert "network.connections.read" in capabilities
    assert "network.connections.write" in capabilities
    refute "resolved.cache.read" in capabilities
    refute "resolved.link_dns.read" in capabilities
    refute "resolved.queries.read" in capabilities
    refute "dhcp_client.fsm.read" in capabilities
    refute "vpn.profile.read" in capabilities

    assert_valid_result("netman.runtime.capabilities.get", result)

    replace_runtime_state(%{
      features: %{
        interfaces: false,
        dhcp_client: false,
        dns_client: true,
        routes: false,
        link_state: false,
        vpn: false
      }
    })

    assert {:ok, %{"capabilities" => dns_capabilities}} =
             Runtime.dispatch("netman.runtime.capabilities.get", %{})

    assert "resolved.link_dns.read" in dns_capabilities
    assert "resolved.queries.read" in dns_capabilities
  end

  test "reports the retained apply mode without trusting request input" do
    for mode <- [:managed, :observe_first, :observe] do
      replace_runtime_state(%{apply_mode: mode})

      assert {:ok, %{"mode" => encoded_mode} = result} =
               Runtime.dispatch("netman.runtime.apply_mode.get", %{})

      assert encoded_mode == Atom.to_string(mode)
      assert_valid_result("netman.runtime.apply_mode.get", result)
    end
  end

  test "reports reconciliation health and contains reconciliation failures" do
    assert {:ok, %{"status" => "degraded", "pending_changes" => 3}} =
             Runtime.reconciliation_health(:managed, NetmanRuntimeDegradedEngine)

    assert {:ok, %{"status" => "unhealthy", "pending_changes" => 0} = failed} =
             Runtime.reconciliation_health(:managed, NetmanRuntimeFailedEngine)

    assert_valid_result("netman.runtime.reconciliation_health.get", failed)

    assert {:ok, %{"status" => "healthy", "pending_changes" => 0}} =
             Runtime.reconciliation_health(:observe, NetmanRuntimeFailedEngine)

    assert {:ok, result} =
             Runtime.dispatch("netman.runtime.reconciliation_health.get", %{})

    assert_valid_result("netman.runtime.reconciliation_health.get", result)
  end

  test "rejects unknown runtime operations" do
    assert {:error, %YellowDog.Sync.Error{code: :unsupported}} =
             Runtime.dispatch("netman.runtime.unknown", %{})
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = NetmanOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp replace_runtime_state(overrides) do
    :sys.replace_state(RuntimeState, fn state -> Map.merge(state, overrides) end)
  end
end

defmodule NetmanRuntimeDegradedEngine do
  def health, do: {:ok, %{status: :degraded, pending_changes: 3}}
end

defmodule NetmanRuntimeFailedEngine do
  def health, do: {:error, :reconciliation_failed}
end
