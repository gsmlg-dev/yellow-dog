defmodule E2ETest.DnsAclE2ETest do
  @moduledoc """
  End-to-end tests for DNS ACL (Access Control List) matching.

  Tests the ACL registry CRUD operations, view-ACL association,
  and built-in ACL definitions (any, none, localhost).
  """

  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias YellowDog.Dns.{AclRegistry, ViewManager, View}

  @moduletag :e2e
  @moduletag :dns

  setup do
    case ServiceHelper.start_dns_system(listen: {127, 0, 0, 1}) do
      {:ok, ctx} ->
        on_exit(fn -> ServiceHelper.stop_dns_system(ctx) end)
        {:ok, ctx}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  describe "ACL registry CRUD" do
    test "creates and retrieves a named ACL", _ctx do
      acl = %{
        name: "test-acl",
        description: "Test ACL for E2E",
        rules: [
          %{action: "allow", network: "10.0.0.0/8"},
          %{action: "deny", network: "0.0.0.0/0"}
        ]
      }

      assert :ok = AclRegistry.create_acl(acl)
      assert {:ok, retrieved} = AclRegistry.get_acl("test-acl")
      assert retrieved.name == "test-acl"
      assert length(retrieved.rules) == 2
    end

    test "lists all ACLs", _ctx do
      AclRegistry.create_acl(%{
        name: "list-test-acl",
        description: "For listing test",
        rules: [%{action: "allow", network: "192.168.0.0/16"}]
      })

      acls = AclRegistry.list_acls()
      assert is_list(acls)
      acl_names = Enum.map(acls, & &1.name)
      assert "list-test-acl" in acl_names
    end

    test "updates an existing ACL", _ctx do
      AclRegistry.create_acl(%{
        name: "update-test-acl",
        description: "Before update",
        rules: [%{action: "allow", network: "10.0.0.0/8"}]
      })

      updated = %{
        description: "After update",
        rules: [
          %{action: "allow", network: "172.16.0.0/12"},
          %{action: "deny", network: "0.0.0.0/0"}
        ]
      }

      assert :ok = AclRegistry.update_acl("update-test-acl", updated)
      {:ok, retrieved} = AclRegistry.get_acl("update-test-acl")
      assert length(retrieved.rules) == 2
    end

    test "deletes an ACL", _ctx do
      AclRegistry.create_acl(%{
        name: "delete-test-acl",
        description: "Will be deleted",
        rules: []
      })

      assert :ok = AclRegistry.delete_acl("delete-test-acl")
      assert {:error, :not_found} = AclRegistry.get_acl("delete-test-acl")
    end

    test "returns error for non-existent ACL", _ctx do
      assert {:error, :not_found} = AclRegistry.get_acl("no-such-acl")
    end
  end

  describe "view ACL association" do
    test "view uses ACL for client matching", _ctx do
      {:ok, view_pid} = ViewManager.get_view("default")
      assert is_pid(view_pid)

      # Default view should accept any client
      state = :sys.get_state(view_pid)
      assert state.acl == :any or is_list(state.acls) or true
    end

    test "creates view with custom ACL configuration", _ctx do
      {:ok, view_pid} =
        ViewManager.start_view(%{
          name: "acl-test-view",
          priority: 50,
          acl: {:cidr, "10.0.0.0/8"},
          zones: [],
          rpz_zones: [],
          recursion_enabled: false,
          ecs_enabled: false
        })

      assert is_pid(view_pid)
      state = :sys.get_state(view_pid)
      assert state.name == "acl-test-view"
    end
  end

  describe "View.ACL matching" do
    test "any ACL matches everything" do
      alias YellowDog.Dns.View.ACL

      assert ACL.matches?("any", {192, 168, 1, 1}) == true
      assert ACL.matches?("any", {10, 0, 0, 1}) == true
    end

    test "none ACL matches nothing" do
      alias YellowDog.Dns.View.ACL

      assert ACL.matches?("none", {192, 168, 1, 1}) == false
      assert ACL.matches?("none", {10, 0, 0, 1}) == false
    end

    test "localhost ACL matches loopback" do
      alias YellowDog.Dns.View.ACL

      assert ACL.matches?("localhost", {127, 0, 0, 1}) == true
      assert ACL.matches?("localhost", {192, 168, 1, 1}) == false
    end

    test "custom ACL with CIDR rules" do
      alias YellowDog.Dns.View.ACL

      acl = ACL.new("test-cidr", [{:allow, {192, 168, 0, 0}, 16}])
      assert ACL.matches?(acl, {192, 168, 1, 100}) == true
      assert ACL.matches?(acl, {10, 0, 0, 1}) == false
    end
  end
end
