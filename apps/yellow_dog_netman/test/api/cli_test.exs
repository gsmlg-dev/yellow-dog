defmodule YellowDog.Netman.API.CLITest do
  use ExUnit.Case

  alias YellowDog.Netman.API.CLI
  alias YellowDog.Netman.ProfileStore

  describe "handle_command/1" do
    test "status returns system status" do
      result = CLI.handle_command(%{"method" => "status"})
      assert %{"result" => status} = result
      assert is_boolean(status["running"])
      assert is_integer(status["interfaces"])
      assert is_integer(status["connections"])
      assert Map.has_key?(status, "default_route")
    end

    test "device.list returns list" do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert %{"result" => devices} = result
      assert is_list(devices)
    end

    test "device.show with unknown interface returns error" do
      result =
        CLI.handle_command(%{
          "method" => "device.show",
          "params" => %{"interface" => "nonexistent_iface_99"}
        })

      assert %{"error" => _} = result
    end

    test "connection.list returns list" do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert %{"result" => profiles} = result
      assert is_list(profiles)
    end

    test "connection.show with valid profile returns profile" do
      # Seed a profile
      profile = %YellowDog.Netman.Types.Profile{
        id: "cli-test-profile",
        type: :ethernet,
        interface: "eth0",
        autoconnect_priority: 100,
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put("cli-test-profile", profile)

      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "cli-test-profile"}
        })

      assert %{"result" => data} = result
      assert data["id"] == "cli-test-profile"
      assert data["type"] == "ethernet"
      assert data["ipv4_method"] == "auto"
    end

    test "connection.show with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => "nonexistent-profile-99"}
        })

      assert %{"error" => _} = result
    end

    test "connection.delete with unknown id returns error" do
      result =
        CLI.handle_command(%{
          "method" => "connection.delete",
          "params" => %{"id" => "nonexistent-profile-99"}
        })

      assert %{"error" => _} = result
    end

    test "unknown method returns error" do
      result = CLI.handle_command(%{"method" => "foobar.unknown"})
      assert %{"error" => "unknown method: foobar.unknown"} = result
    end

    test "invalid command format returns error" do
      result = CLI.handle_command(%{"no_method" => true})
      assert %{"error" => "invalid command format"} = result
    end
  end
end
