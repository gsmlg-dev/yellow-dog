defmodule YellowDog.Management.ConfigDeliveryTest do
  use ExUnit.Case, async: false

  defmodule FailingTransport do
    @behaviour YellowDog.Management.Transport

    @impl true
    def connected?(:server, _server_id), do: true

    @impl true
    def request(_envelope, _timeout), do: raise("unexpected request")

    @impl true
    def deliver_config(_envelope) do
      case Process.get(:config_delivery_failure) do
        :raise -> raise "delivery crashed"
        :exit -> exit(:delivery_crashed)
      end
    end
  end

  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.FakeTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Envelope

  setup do
    previous_env =
      Map.new([:data_dir, :transport_module], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-delivery-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    restart_application()
    start_supervised!(FakeTransport)

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "publishing a connected Server configuration immediately delivers its committed version" do
    register_server("server-connected")
    :ok = FakeTransport.connect(:server, "server-connected")
    :ok = FakeTransport.script_config([{:report_committed_version, self()}])

    assert {:ok, %ConfigVersion{} = version} =
             ManagementCore.publish_server_config("server-connected", attrs(1))

    assert_receive {:committed_version_during_delivery, {:ok, ^version}}

    assert [%{kind: :config, timeout: nil, envelope: %Envelope{} = envelope}] =
             FakeTransport.recorded()

    assert envelope.target_type == version.target_type
    assert envelope.target_id == version.target_id
    assert envelope.operation == version.operation
    assert envelope.payload == version.payload
    assert envelope.payload_digest == version.digest
    assert envelope.expected_revision == version.expected_revision
    assert envelope.config_version == version.version

    assert {:ok, %ConfigVersion{state: :desired, state_revision: 0} = stored} =
             ManagementCore.get_server_config_version("server-connected", version.version)

    assert stored == version
  end

  test "transport exceptions and exits do not roll back committed desired versions" do
    Application.put_env(:yellow_dog_management_core, :transport_module, FailingTransport)

    for {failure, server_id, index} <- [
          {:raise, "server-delivery-raises", 2},
          {:exit, "server-delivery-exits", 3}
        ] do
      register_server(server_id)
      Process.put(:config_delivery_failure, failure)

      assert {:ok, %ConfigVersion{} = version} =
               ManagementCore.publish_server_config(server_id, attrs(index))

      assert {:ok, ^version} =
               ManagementCore.get_server_config_version(server_id, version.version)

      assert {:ok, ^version} = ManagementCore.latest_desired_config(:server, server_id)
    end
  after
    Process.delete(:config_delivery_failure)
  end

  test "a connected Server delivery failure preserves the committed desired version" do
    register_server("server-delivery-failure")
    :ok = FakeTransport.connect(:server, "server-delivery-failure")
    :ok = FakeTransport.script_config([{:error, Error.new(:internal, "temporary failure", %{})}])

    assert {:ok, %ConfigVersion{} = version} =
             ManagementCore.publish_server_config("server-delivery-failure", attrs(1))

    assert [%{kind: :config, envelope: %Envelope{config_version: delivered_version}}] =
             FakeTransport.recorded()

    assert delivered_version == version.version

    assert {:ok, %ConfigVersion{state: :desired, state_revision: 0} = stored} =
             ManagementCore.get_server_config_version("server-delivery-failure", version.version)

    assert stored == version

    assert {:ok, ^version} =
             ManagementCore.latest_desired_config(:server, "server-delivery-failure")
  end

  test "publishing an offline Server configuration leaves delivery to the desired queue" do
    register_server("server-offline")

    assert {:ok, %ConfigVersion{} = version} =
             ManagementCore.publish_server_config("server-offline", attrs(1))

    assert FakeTransport.recorded() == []
    assert {:ok, ^version} = ManagementCore.latest_desired_config(:server, "server-offline")
  end

  test "publishing a connected Netman configuration immediately delivers its committed version" do
    register_netman("netman-connected")
    :ok = FakeTransport.connect(:netman, "netman-connected")
    :ok = FakeTransport.script_config([{:report_committed_version, self()}])

    assert {:ok, %ConfigVersion{} = version} =
             ManagementCore.publish_netman_config("netman-connected", netman_attrs())

    assert_receive {:committed_version_during_delivery, {:ok, ^version}}

    assert [%{kind: :config, timeout: nil, envelope: %Envelope{} = envelope}] =
             FakeTransport.recorded()

    assert envelope.target_type == :netman
    assert envelope.target_id == version.target_id
    assert envelope.operation == "netman.profiles.replace"
    assert envelope.payload == version.payload
    assert envelope.payload_digest == version.digest
    assert envelope.config_version == version.version

    assert {:ok, ^version} =
             ManagementCore.get_netman_config_version("netman-connected", version.version)
  end

  test "publishing an offline Netman configuration leaves delivery to the desired queue" do
    register_netman("netman-offline")

    assert {:ok, %ConfigVersion{} = version} =
             ManagementCore.publish_netman_config("netman-offline", netman_attrs())

    assert FakeTransport.recorded() == []
    assert {:ok, ^version} = ManagementCore.latest_desired_config(:netman, "netman-offline")
  end

  defp attrs(index) do
    %{
      operation: "server.settings.update",
      payload: %{
        "service" => "dns",
        "entries" => [
          %{
            "key" => "listen",
            "value" => %{"type" => "string", "value" => "192.0.2.#{index}"}
          }
        ]
      },
      expected_revision: nil
    }
  end

  defp register_server(id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: id, profile: :dns_only})
  end

  defp register_netman(id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: id, profile: :vm})
  end

  defp netman_attrs do
    %{
      operation: "netman.profiles.replace",
      payload: %{
        "profiles" => [
          %{
            "profile_id" => "office",
            "type" => "ethernet",
            "interface" => "eth0",
            "autoconnect" => true,
            "autoconnect_priority" => 100,
            "zone" => "trusted",
            "ethernet" => %{"mtu" => 1_500},
            "ipv4" => %{
              "method" => "manual",
              "address" => "192.0.2.10/24",
              "gateway" => "192.0.2.1",
              "dns" => ["192.0.2.53"],
              "dns_search" => ["example.test"]
            },
            "ipv6" => %{
              "method" => "manual",
              "address" => "2001:db8::10/64",
              "gateway" => "2001:db8::1",
              "dns" => ["2001:db8::53"],
              "dns_search" => ["example.test"]
            }
          }
        ]
      },
      expected_revision: nil
    }
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
