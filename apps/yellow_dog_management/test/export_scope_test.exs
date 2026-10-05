defmodule YellowDog.Management.ExportScopeTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.{ConfigCompiler, Domain, DomainFixtures, Repo, Web}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{fixture: prepared_fixture()}
  end

  test "limited exports disclose omitted features without changing confirmed TOML bytes", %{
    fixture: fixture
  } do
    path = export_path(fixture)
    implicit = request(path)
    explicit = request(path <> "?scope=dns_zones")
    assert implicit.status == 200
    assert explicit.status == 200
    assert get_resp_header(implicit, "x-yellow-dog-export-scope") == ["dns_zones"]

    assert get_resp_header(implicit, "x-yellow-dog-export-excludes") == [
             "dns_views,geoip_artifacts"
           ]

    assert {:ok, exported} =
             ConfigCompiler.export_target(fixture.worker["id"], fixture.target["revision"])

    assert implicit.resp_body == exported["toml"]
    assert explicit.resp_body == implicit.resp_body
    assert {:ok, plan} = ConfigSpec.decode(implicit.resp_body)
    assert plan == fixture.target["plan"]
    assert {:ok, digest} = ConfigSpec.plan_digest(plan)
    assert digest == fixture.target["digest"]
  end

  test "explicit full export rejects omitted Views and artifacts while drafts remain editable", %{
    fixture: fixture
  } do
    view =
      mutation("create_dns_view", %{
        "worker_id" => fixture.worker["id"],
        "service_id" => fixture.service["id"],
        "name" => "authored-view"
      })

    before_audit = Domain.list_audit()
    response = request(export_path(fixture) <> "?scope=full")
    assert response.status == 422

    assert %{
             "error" => %{
               "code" => "unsupported_export",
               "message" => message,
               "details" => %{
                 "supported_scope" => "dns_zones",
                 "excluded" => ["dns_views", "geoip_artifacts"]
               }
             }
           } =
             Jason.decode!(response.resp_body)

    assert message =~ "DNS Views"
    assert message =~ "IP database artifacts"
    assert message =~ "drafts can still be saved"
    assert Domain.list_audit() == before_audit

    assert {:ok, ^view} =
             Domain.get_dns_view(fixture.worker["id"], fixture.service["id"], view["id"])

    draft = mutation("create_zone", DomainFixtures.zone("draft-after-export.example.test."))
    assert {:ok, ^draft} = Domain.get_zone(draft["id"])
  end

  test "unknown scope is rejected and later edits cannot mutate historical limited exports", %{
    fixture: fixture
  } do
    original = request(export_path(fixture)).resp_body
    response = request(export_path(fixture) <> "?scope=everything")
    assert response.status == 422
    assert %{"error" => %{"code" => "invalid_request"}} = Jason.decode!(response.resp_body)
    revised = DomainFixtures.zone(fixture.zone["name"])

    records =
      Enum.map(revised["records"], fn
        %{"type" => "A"} = record -> put_in(record, ["data", "address"], "192.0.2.99")
        record -> record
      end)

    updated =
      mutation("update_zone", %{
        "id" => fixture.zone["id"],
        "expected_revision" => fixture.zone["revision"],
        "name" => fixture.zone["name"],
        "records" => records
      })

    mutation("confirm_zone", %{"id" => updated["id"], "expected_revision" => updated["revision"]})
    assert request(export_path(fixture) <> "?scope=dns_zones").resp_body == original
  end

  defp prepared_fixture do
    zone = mutation("create_zone", DomainFixtures.zone())

    version =
      mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    worker = mutation("create_worker", %{"id" => "export-scope", "name" => "Export Scope"})

    service =
      mutation("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

    assignment =
      mutation("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => service["worker_revision"]
      })

    target =
      mutation("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => assignment["worker_revision"]
      })

    %{zone: zone, worker: worker, service: service, target: target}
  end

  defp mutation(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  defp export_path(fixture),
    do: "/api/workers/#{fixture.worker["id"]}/targets/#{fixture.target["revision"]}/export"

  defp request(path), do: conn(:get, path) |> Web.call(Web.init([]))
end
