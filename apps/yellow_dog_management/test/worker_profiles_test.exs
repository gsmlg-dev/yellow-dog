defmodule YellowDog.Management.WorkerProfilesTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{ConfigCompiler, Domain, ProfileCatalog, Repo, Worker}
  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "all six catalog profiles are durable descriptive metadata, not executable defaults" do
    for profile <- ProfileCatalog.list_server_profiles() do
      name = to_string(profile.name)
      worker = create_worker("profile-#{name}", %{"profile_name" => name})
      assert worker["profile_name"] == name
      assert worker["expected_capabilities"] == ["dns"]
      assert worker["actual_state"] == "unknown"
      assert worker["status"] == "not_yet_connected"
      assert Repo.get!(Worker, worker["id"]).profile_name == name
      assert {:ok, stored} = Domain.get_worker(worker["id"])
      assert stored["profile_name"] == name
      assert stored["services"] == []
      assert stored["assignments"] == []
    end

    assert Enum.map(Domain.list_workers(), & &1["profile_name"]) |> Enum.sort() ==
             Enum.map(ProfileCatalog.list_server_profiles(), &to_string(&1.name)) |> Enum.sort()
  end

  test "custom is the business default and omitted edits retain the selected profile" do
    assert create_worker("default-profile")["profile_name"] == "custom"
    worker = create_worker("retain-profile", %{"profile_name" => "cloud_dns"})

    renamed =
      mutate("update_worker", %{
        "id" => worker["id"],
        "expected_revision" => worker["revision"],
        "name" => "Renamed Worker"
      })

    assert renamed["profile_name"] == "cloud_dns"
    assert renamed["revision"] == worker["revision"] + 1
    assert renamed["expected_capabilities"] == worker["expected_capabilities"]
  end

  test "invalid profile types and names cannot create or overwrite a Worker" do
    worker = create_worker("valid-profile", %{"profile_name" => "dns_only"})

    for profile <- ["unknown", "", "observe_only", nil, 123, [], %{"name" => "dns_only"}] do
      assert {:error, %{code: "invalid_request"}} =
               Domain.mutate(
                 "create_worker",
                 %{
                   "id" => "invalid-profile",
                   "name" => "Invalid Worker",
                   "expected_capabilities" => ["dns"],
                   "profile_name" => profile
                 },
                 "operator",
                 Ecto.UUID.generate()
               )

      assert {:error, %{code: "invalid_request"}} =
               Domain.mutate(
                 "update_worker",
                 %{
                   "id" => worker["id"],
                   "expected_revision" => worker["revision"],
                   "name" => "Must Not Save",
                   "profile_name" => profile
                 },
                 "operator",
                 Ecto.UUID.generate()
               )

      assert is_nil(Repo.get(Worker, "invalid-profile"))
      assert {:ok, stored} = Domain.get_worker(worker["id"])
      assert stored["name"] == worker["name"]
      assert stored["profile_name"] == "dns_only"
      assert stored["revision"] == worker["revision"]
    end
  end

  test "profile edits use existing CAS and preserve concurrently saved metadata" do
    worker = create_worker("cas-profile")

    changed =
      mutate("update_worker", %{
        "id" => worker["id"],
        "expected_revision" => worker["revision"],
        "profile_name" => "local_network"
      })

    assert changed["profile_name"] == "local_network"

    assert {:error, %{code: "revision_conflict"}} =
             Domain.mutate(
               "update_worker",
               %{
                 "id" => worker["id"],
                 "expected_revision" => worker["revision"],
                 "name" => "Stale Name",
                 "profile_name" => "dhcp_only"
               },
               "operator",
               Ecto.UUID.generate()
             )

    assert {:ok, current} = Domain.get_worker(worker["id"])
    assert current["profile_name"] == changed["profile_name"]
    assert current["name"] == worker["name"]
    assert current["revision"] == changed["revision"]
  end

  test "idempotency preserves the recorded profile result and rejects a different selection" do
    key = Ecto.UUID.generate()
    params = %{"id" => "replay-profile", "name" => "Replay", "profile_name" => "dns_only"}
    assert {:ok, original} = Domain.mutate("create_worker", params, "operator", key)
    assert {:ok, ^original} = Domain.mutate("create_worker", params, "operator", key)

    assert {:error, %{code: "idempotency_conflict"}} =
             Domain.mutate(
               "create_worker",
               %{params | "profile_name" => "cloud_dns"},
               "operator",
               key
             )

    assert length(Domain.list_workers()) == 1
    assert length(Domain.list_audit()) == 1
  end

  test "changing catalog labels leaves DNS, pinned assignments, immutable targets and export bytes alone" do
    zone = mutate("create_zone", Fixtures.zone("profile.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    worker = create_worker("configured-profile", %{"profile_name" => "dns_only"})
    service = mutate("put_service", Fixtures.service(worker["id"], worker["revision"], "stopped"))

    assignment =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => service["worker_revision"]
      })

    target =
      mutate("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => assignment["worker_revision"]
      })

    assert {:ok, stored_target} = Domain.get_target(worker["id"], target["revision"])
    assert {:ok, before} = Domain.get_worker(worker["id"])
    assert {:ok, export} = ConfigCompiler.export_target(worker["id"], target["revision"])

    mutate("update_worker", %{
      "id" => worker["id"],
      "expected_revision" => before["revision"],
      "profile_name" => "dhcp_only"
    })

    assert {:ok, after_edit} = Domain.get_worker(worker["id"])
    assert after_edit["profile_name"] == "dhcp_only"
    assert after_edit["services"] == before["services"]
    assert after_edit["assignments"] == before["assignments"]
    assert after_edit["expected_capabilities"] == before["expected_capabilities"]
    assert after_edit["actual_state"] == "unknown"
    assert {:ok, ^stored_target} = Domain.get_target(worker["id"], target["revision"])
    assert {:ok, ^export} = ConfigCompiler.export_target(worker["id"], target["revision"])
    assert Domain.list_versions(zone["id"]) == [version]
    refute Map.has_key?(target["plan"], "profile_name")
  end

  defp create_worker(id, extra \\ %{}) do
    mutate(
      "create_worker",
      Map.merge(%{"id" => id, "name" => id, "expected_capabilities" => ["dns"]}, extra)
    )
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
