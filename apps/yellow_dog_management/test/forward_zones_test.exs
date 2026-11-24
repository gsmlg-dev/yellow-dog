defmodule YellowDog.Management.ForwardZonesTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{
    Caller,
    Domain,
    DomainFixtures,
    ForwardZones,
    IntegrationSettings,
    Repo,
    Worker
  }

  @endpoint YellowDog.ManagementUI.Endpoint
  @path "/management/dns/forward-zones"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    caller = %Caller{
      issuer: "urn:yellow-dog:trusted-local",
      subject: "forward-zones-test",
      scopes: IntegrationSettings.scopes(),
      source: :ui,
      correlation_id: Ecto.UUID.generate(),
      expires_at: System.system_time(:second) + 600,
      policy_revision: IntegrationSettings.get().policy_revision,
      authentication: :trusted_local
    }

    for {id, name} <- [{"east", "East Worker"}, {"west", "West Worker"}, {"lab", "Lab Worker"}] do
      Repo.insert!(%Worker{id: id, name: name})
    end

    %{caller: caller}
  end

  test "writes standalone zones and serializes independent Worker target assignments", %{
    caller: caller
  } do
    assert {:ok, east_west} =
             ForwardZones.create(caller, params("Corp.Example", ["west", "east"]))

    assert east_west.name == "corp.example."
    assert east_west.worker_ids == ["east", "west"]
    assert east_west.revision == 1

    assert ForwardZones.target_zones("east") == [
             %{
               "name" => "corp.example.",
               "forwarders" => [%{"address" => "127.0.0.1", "port" => 15_353}]
             }
           ]

    assert ForwardZones.target_zones("west") == ForwardZones.target_zones("east")
    assert ForwardZones.target_zones("lab") == []
    assert revisions() == %{"east" => 2, "west" => 2, "lab" => 1}

    assert {:ok, lab_zone} = ForwardZones.create(caller, params("corp.example.", ["lab"]))
    assert lab_zone.id != east_west.id
    assert revisions() == %{"east" => 2, "west" => 2, "lab" => 2}

    assert {:error, %{code: "forward_zone_conflict"}} =
             ForwardZones.update(
               caller,
               east_west.id,
               1,
               params("corp.example.", ["east", "lab"])
             )

    assert {:ok, edited} =
             ForwardZones.update(caller, east_west.id, 1, params("Private.Example", ["lab"]))

    assert edited.revision == 2
    assert ForwardZones.target_zones("east") == []

    assert Enum.map(ForwardZones.target_zones("lab"), & &1["name"]) == [
             "corp.example.",
             "private.example."
           ]

    assert revisions() == %{"east" => 3, "west" => 3, "lab" => 3}
    assert {:error, %{code: "revision_conflict"}} = ForwardZones.delete(caller, east_west.id, 1)
    assert {:ok, :deleted} = ForwardZones.delete(caller, east_west.id, edited.revision)
    assert revisions() == %{"east" => 3, "west" => 3, "lab" => 4}
    assert Enum.map(ForwardZones.target_zones("lab"), & &1["name"]) == ["corp.example."]
  end

  test "requires registered Workers, normalized upstreams, and a write scope", %{caller: caller} do
    assert {:error, %{code: "invalid_workers"}} = ForwardZones.create(caller, params(".", []))

    assert {:error, %{code: "invalid_workers"}} =
             ForwardZones.create(caller, params(".", ["west", "west"]))

    assert {:error, %{code: "worker_not_found"}} =
             ForwardZones.create(caller, params(".", ["missing"]))

    assert {:error, %{code: "invalid_domain"}} =
             ForwardZones.create(caller, params("bad..example", ["east"]))

    invalid_ip = Map.put(params(".", ["east"]), "forwarders", [%{"address" => "upstream.test"}])
    assert {:error, %{code: "invalid_address"}} = ForwardZones.create(caller, invalid_ip)

    read_only = %{caller | scopes: ["config:read"]}
    assert {:error, %{code: "forbidden"}} = ForwardZones.create(read_only, params(".", ["east"]))

    ipv6 = Map.put(params(".", ["east"]), "forwarders", [%{"address" => "2001:0DB8::4"}])
    assert {:ok, fallback} = ForwardZones.create(caller, ipv6)
    assert fallback.name == "."
    assert fallback.forwarders == [%{"address" => "2001:db8::4", "port" => 53}]
  end

  test "Worker target review is invalidated and legacy suffixes remain while assigned keys win",
       %{
         caller: caller
       } do
    prior = [
      %{
        "name" => "preserved.example.",
        "forwarders" => [%{"address" => "192.0.2.1", "port" => 53}]
      },
      %{
        "name" => "replaced.example.",
        "forwarders" => [%{"address" => "192.0.2.2", "port" => 53}]
      }
    ]

    service =
      DomainFixtures.service("east", 1)
      |> put_in(["config", "forward_zones"], prior)

    assert {:ok, _} = Domain.mutate("put_service", service, "test", Ecto.UUID.generate())
    assert {:ok, stale_preview} = Domain.preview_target("east")
    assert {:ok, _} = ForwardZones.create(caller, params("replaced.example", ["east"]))

    confirmation = %{
      "worker_id" => "east",
      "expected_revision" => stale_preview["worker_revision"]
    }

    assert {:error, %{code: "revision_conflict"}} =
             Domain.mutate("confirm_target", confirmation, "test", Ecto.UUID.generate())

    assert {:ok, review} = Domain.preview_target("east")
    [service] = review["plan"]["services"]

    assert service["config"]["forward_zones"] == [
             hd(prior),
             %{
               "name" => "replaced.example.",
               "forwarders" => [%{"address" => "127.0.0.1", "port" => 15_353}]
             }
           ]
  end

  test "edits forwarding zones through React schema forms in the standalone page" do
    {:ok, view, _html} = live(build_conn(), @path)
    assert has_element?(view, "h1", "Forwarding Zones")
    refute has_element?(view, "#forward-zone-editor[phx-hook]")

    view |> element("#add-forward-zone") |> render_click()
    assert has_element?(view, "[phx-hook='SchemaModal']")
    assert render(view) =~ "checkbox-group"
    assert render(view) =~ "East Worker"

    render_hook(view, "submit_modal", params("shared.example", ["east", "west"]))
    assert has_element?(view, "tr", "shared.example.")
    assert has_element?(view, "tr", "East Worker")
    assert has_element?(view, "tr", "West Worker")
    refute has_element?(view, "[phx-hook='SchemaModal']")

    view |> element("button", "Edit") |> render_click()
    assert render(view) =~ "Edit forwarding zone"
    render_hook(view, "submit_modal", params("private.example", ["lab"]))

    refute has_element?(view, "tr", "shared.example.")
    assert has_element?(view, "tr", "private.example.")
    assert has_element?(view, "tr", "Lab Worker")

    view |> element("button", "Delete") |> render_click()
    refute has_element?(view, "tr", "private.example.")
  end

  test "checks the WorkerPlan suffix limit after combining legacy and assigned zones", %{
    caller: caller
  } do
    legacy =
      for i <- 1..64 do
        %{
          "name" => "legacy-#{i}.example.",
          "forwarders" => [%{"address" => "192.0.2.1", "port" => 53}]
        }
      end

    service =
      DomainFixtures.service("east", 1)
      |> put_in(["config", "forward_zones"], legacy)

    assert {:ok, _} = Domain.mutate("put_service", service, "test", Ecto.UUID.generate())
    assert {:ok, zone} = ForwardZones.create(caller, params("legacy-1.example", ["east"]))

    assert {:error, %{code: "too_many"}} =
             ForwardZones.create(caller, params("new.example", ["east"]))

    assert {:error, %{code: "too_many"}} =
             ForwardZones.update(caller, zone.id, 1, params("new.example", ["east"]))

    assert Enum.map(ForwardZones.target_zones("east"), & &1["name"]) == ["legacy-1.example."]
  end

  defp params(name, workers) do
    %{
      "name" => name,
      "forwarders" => [%{"address" => "127.0.0.1", "port" => 15_353}],
      "worker_ids" => workers
    }
  end

  defp revisions do
    Repo.all(Worker) |> Map.new(&{&1.id, &1.revision})
  end
end
