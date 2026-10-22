defmodule YellowDog.ManagementUI.IntegrationsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias YellowDog.Management.{IntegrationSettings, Operations, Repo}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:yellow_dog_management, :integration)

    Application.put_env(:yellow_dog_management, :integration, %{
      mode: :trusted_local,
      http_enabled: true,
      mcp_enabled: false,
      write_enabled: false,
      resource: "http://localhost",
      issuer: "https://issuer.example.test",
      access_jwks_file: "/private/access-jwks.json",
      gateway_jwks_file: "/private/gateway-jwks.json",
      operator: "private-operator-identity",
      allowed_scopes: IntegrationSettings.scopes()
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog_management, :integration, previous),
        else: Application.delete_env(:yellow_dog_management, :integration)
    end)

    :ok
  end

  test "routed integration information uses public deployment settings and real operation catalog" do
    {:ok, view, html} = live(%{build_conn() | host: "localhost"}, "/system/integrations")

    assert has_element?(
             view,
             "#app-sidebar-navigation a[data-nav-item='api_mcp'][aria-current='page']"
           )

    assert has_element?(view, "#integration-status [data-mode='trusted_local']")
    assert has_element?(view, "#integration-status", "Enabled")
    assert has_element?(view, "#integration-status", "Disabled")
    assert has_element?(view, "a[href='/api/v1/openapi.json']", "OpenAPI document")
    assert has_element?(view, "a[href='/.well-known/oauth-protected-resource']")
    assert has_element?(view, "#integration-endpoints", "http://localhost/mcp")
    assert has_element?(view, "#integration-endpoints", "2025-11-25")
    assert has_element?(view, "#integration-tools", "zone_set_assignments")

    for operation <- Operations.all(),
        do: assert(has_element?(view, "#integration-tools code", operation.id))

    refute html =~ "/private/"
    refute html =~ "private-operator-identity"
    refute has_element?(view, "#integration-status input")
    assert html =~ "configuration-only"
    assert html =~ "logical_request_key"
  end
end
