defmodule YellowDog.Netman.Control.ProfilesTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Control.Profiles
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  setup do
    profile_id = "control-profile-#{System.unique_integer([:positive])}"
    on_exit(fn -> YellowDog.Netman.delete_profile(profile_id) end)
    {:ok, profile_id: profile_id}
  end

  test "put and history queries return the lossless profile lifecycle", %{profile_id: profile_id} do
    initial = wire_profile(profile_id, 10)

    assert {:ok, :missing} = Profiles.current("netman.profiles.put", initial)

    assert {:ok, initial_state} =
             Profiles.dispatch("netman.profiles.put", initial, mutation_context(:must_be_missing))

    assert initial_state["profile"] == initial
    initial_revision = initial_state["desired_revision"]
    assert initial_state["active_revision"] == nil
    assert_valid_result("netman.profiles.put", initial_state)

    replacement = wire_profile(profile_id, 20)

    assert {:ok, replacement_state} =
             Profiles.dispatch(
               "netman.profiles.put",
               replacement,
               mutation_context({:revision, initial_revision}, initial_revision)
             )

    replacement_revision = replacement_state["desired_revision"]
    refute replacement_revision == initial_revision

    assert {:ok, history} =
             Profiles.dispatch("netman.profiles.history.list", %{"profile_id" => profile_id})

    assert Enum.map(history["items"], & &1["revision"]) == [
             replacement_revision,
             initial_revision
           ]

    assert Enum.map(history["items"], & &1["profile"]) == [replacement, initial]
    assert_valid_result("netman.profiles.history.list", history)

    assert {:ok, revision_state} =
             Profiles.dispatch("netman.profiles.active_revision.get", %{
               "profile_id" => profile_id
             })

    assert revision_state == %{
             "profile_id" => profile_id,
             "desired_revision" => replacement_revision,
             "active_revision" => nil
           }
  end

  test "replacement snapshot captures the exact current profile set and namespace revision", %{
    profile_id: profile_id
  } do
    profile = wire_profile(profile_id, 10)

    assert {:ok, _state} =
             Profiles.dispatch("netman.profiles.put", profile, mutation_context(:must_be_missing))

    assert {:ok, namespace_revision} = YellowDog.Netman.profiles_revision()

    assert {:ok, %{"profiles" => profiles}, ^namespace_revision} =
             Profiles.replacement_snapshot()

    assert Enum.find(profiles, &(&1["profile_id"] == profile_id)) == profile
    assert profiles == Enum.sort_by(profiles, & &1["profile_id"])
  end

  test "validation and patch use the full runtime profile model", %{profile_id: profile_id} do
    profile = wire_profile(profile_id, 10)

    assert {:ok, %{"profile_id" => ^profile_id, "valid" => true, "errors" => []}} =
             Profiles.dispatch("netman.profiles.validate", profile)

    assert {:ok, created} =
             Profiles.dispatch("netman.profiles.put", profile, mutation_context(:must_be_missing))

    revision = created["desired_revision"]

    patch = %{
      "profile_id" => profile_id,
      "changes" => [
        %{"field" => "zone", "value" => "guest"},
        %{"field" => "ethernet.mtu", "value" => 9_000},
        %{"field" => "ipv6", "value" => wire_profile(profile_id, 10)["ipv6"]}
      ]
    }

    assert {:ok, patched} =
             Profiles.dispatch(
               "netman.profiles.patch",
               patch,
               mutation_context({:revision, revision}, revision)
             )

    assert patched["profile"]["zone"] == "guest"
    assert patched["profile"]["ethernet"] == %{"mtu" => 9_000}
    assert_valid_result("netman.profiles.patch", patched)
  end

  test "activation returns only after the selected profile revision is active", %{
    profile_id: profile_id
  } do
    interface = "ctl#{System.unique_integer([:positive])}" |> String.slice(0, 15)
    profile = wire_profile(profile_id, 10, interface)
    profile = put_in(profile, ["ipv4", "method"], "disabled")

    MockNetlink.link_up(interface, carrier: true)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      MockNetlink.link_removed(interface)
    end)

    assert {:ok, created} =
             Profiles.dispatch("netman.profiles.put", profile, mutation_context(:must_be_missing))

    revision = created["desired_revision"]

    assert {:ok, activated} =
             Profiles.dispatch(
               "netman.profiles.activate",
               %{"profile_id" => profile_id},
               mutation_context({:revision, revision}, revision)
             )

    assert activated == %{
             "profile_id" => profile_id,
             "desired_revision" => revision,
             "active_revision" => revision,
             "state" => "activated",
             "connections" => [
               %{
                 "profile_id" => profile_id,
                 "interface" => interface,
                 "state" => "activated"
               }
             ]
           }

    assert_valid_result("netman.profiles.activate", activated)

    replacement = wire_profile(profile_id, 20, interface)
    replacement = put_in(replacement, ["ipv4", "method"], "disabled")

    assert {:ok, replacement_state} =
             Profiles.dispatch(
               "netman.profiles.put",
               replacement,
               mutation_context({:revision, revision}, revision)
             )

    replacement_revision = replacement_state["desired_revision"]

    assert {:ok, rolled_back} =
             Profiles.dispatch(
               "netman.profiles.rollback",
               %{"profile_id" => profile_id, "target_revision" => revision},
               mutation_context({:revision, replacement_revision}, replacement_revision)
             )

    assert rolled_back["desired_revision"] == revision
    assert rolled_back["active_revision"] == revision
    assert_valid_result("netman.profiles.rollback", rolled_back)
  end

  test "replace reports applied only after autoconnect profiles converge and omissions stop" do
    suffix = System.unique_integer([:positive])
    old_profile_id = "replace-old-#{suffix}"
    new_profile_id = "replace-new-#{suffix}"
    old_interface = "ctlo#{suffix}" |> String.slice(0, 15)
    new_interface = "ctln#{suffix}" |> String.slice(0, 15)

    old_profile =
      old_profile_id
      |> wire_profile(10, old_interface)
      |> put_in(["ipv4", "method"], "disabled")

    replacement =
      new_profile_id
      |> wire_profile(20, new_interface)
      |> put_in(["ipv4", "method"], "disabled")

    Enum.each([old_interface, new_interface], &MockNetlink.link_up(&1, carrier: true))

    on_exit(fn ->
      Enum.each([old_interface, new_interface], fn interface ->
        Connection.Supervisor.stop_connection(interface)
        MockNetlink.link_removed(interface)
      end)

      Enum.each([old_profile_id, new_profile_id], &YellowDog.Netman.delete_profile/1)
    end)

    assert {:ok, created} =
             Profiles.dispatch(
               "netman.profiles.put",
               old_profile,
               mutation_context(:must_be_missing)
             )

    assert :ok = YellowDog.Netman.activate(old_profile_id)
    assert {:ok, _pid} = Connection.Supervisor.find_connection(old_interface)
    assert {:ok, namespace_revision} = YellowDog.Netman.profiles_revision()

    assert {:ok, result} =
             Profiles.dispatch(
               "netman.profiles.replace",
               %{"profiles" => [replacement]},
               config_context(namespace_revision, 1)
             )

    assert result["state"] == "applied"
    assert result["applied_revision"] != namespace_revision
    assert Connection.Supervisor.find_connection(old_interface) == :error

    assert {:ok, replacement_state} = YellowDog.Netman.profile_state(new_profile_id)
    assert replacement_state.active_revision == replacement_state.desired_revision
    assert {:error, :not_found} = YellowDog.Netman.get_profile(old_profile_id)
    assert created["profile"]["profile_id"] == old_profile_id
    assert_valid_result("netman.profiles.replace", result)
  end

  test "replace does not report applied when an autoconnect profile cannot converge" do
    suffix = System.unique_integer([:positive])
    profile_id = "replace-fail-#{suffix}"
    interface = "miss#{suffix}" |> String.slice(0, 15)

    replacement =
      profile_id
      |> wire_profile(10, interface)
      |> put_in(["ipv4", "method"], "disabled")

    on_exit(fn ->
      Connection.Supervisor.stop_connection(interface)
      YellowDog.Netman.delete_profile(profile_id)
    end)

    assert {:ok, namespace_revision} = YellowDog.Netman.profiles_revision()

    assert {:error, %YellowDog.Sync.Error{code: :apply_failed}} =
             Profiles.dispatch(
               "netman.profiles.replace",
               %{"profiles" => [replacement]},
               config_context(namespace_revision, 2)
             )

    assert {:ok, %{active_revision: nil}} = YellowDog.Netman.profile_state(profile_id)
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = NetmanOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp mutation_context(precondition, current_revision \\ :missing) do
    %{
      expected_revision: if(is_binary(current_revision), do: current_revision, else: nil),
      current_revision: current_revision,
      precondition: precondition,
      config_version: nil
    }
  end

  defp config_context(current_revision, version) do
    %{
      expected_revision: current_revision,
      current_revision: current_revision,
      precondition: {:revision, current_revision},
      config_version: version
    }
  end

  defp wire_profile(profile_id, priority, interface \\ "eth0") do
    %{
      "profile_id" => profile_id,
      "type" => "ethernet",
      "interface" => interface,
      "autoconnect" => true,
      "autoconnect_priority" => priority,
      "zone" => "default",
      "ethernet" => %{"mtu" => 1_500},
      "ipv4" => %{
        "method" => "auto",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      },
      "ipv6" => %{
        "method" => "disabled",
        "address" => nil,
        "gateway" => nil,
        "dns" => [],
        "dns_search" => []
      }
    }
  end
end
