defmodule YellowDog.ManagementUI.IntegrationsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{IntegrationSettings, MCP, Operations}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "API & MCP integration",
       integration: IntegrationSettings.public(),
       protocol: MCP.protocol_version(),
       tools: Operations.all()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>API &amp; MCP integration</h1>
      <p class="management-help">
        These interfaces manage confirmed configuration. Saving, confirming, assigning and publishing
        are separate operations. A published target does not establish Worker execution.
      </p>
      <.card title="Deployment configuration">
        <dl id="integration-status">
          <dt>Authentication mode</dt><dd data-mode={@integration.mode}>{@integration.mode}</dd>
          <dt>HTTP API</dt><dd>{enabled(@integration.http_enabled)}</dd>
          <dt>MCP</dt><dd>{enabled(@integration.mcp_enabled)}</dd>
          <dt>Remote writes</dt><dd>{enabled(@integration.write_enabled)}</dd>
          <dt>Policy revision</dt><dd>{@integration.policy_revision}</dd>
          <dt>External authorization server</dt><dd>{@integration.issuer || "Not configured"}</dd>
          <dt>Permitted scopes</dt><dd>{Enum.join(@integration.allowed_scopes, ", ")}</dd>
        </dl>
        <p class="management-help">
          Deployment configuration controls these values. Trusted-local mode accepts direct loopback
          traffic only. Protected-remote mode verifies external access tokens; the trusted gateway
          supplies a separate verified identity for this UI.
        </p>
      </.card>
      <.card title="Endpoints and client setup">
        <dl id="integration-endpoints">
          <dt>HTTP API v1</dt><dd><code>{@integration.resource}/api/v1</code></dd>
          <dt>MCP Streamable HTTP</dt><dd><code>{@integration.resource}/mcp</code></dd>
          <dt>Supported MCP revision</dt><dd>{@protocol}</dd>
          <dt>Pinned client target</dt><dd>Official TypeScript SDK 1.32.1</dd>
          <dt>OpenAPI 3.1.2</dt><dd><a href="/api/v1/openapi.json">OpenAPI document</a></dd>
          <dt>OAuth protected resource</dt>
          <dd><a href="/.well-known/oauth-protected-resource">Authorization metadata</a></dd>
        </dl>
        <p class="management-help">
          Configure a Streamable HTTP client with the MCP URL and an externally issued Bearer access
          token for this resource. POST requires Accept: application/json, text/event-stream and
          Content-Type: application/json. Initialize with the supported revision; subsequent calls
          include MCP-Protocol-Version. This endpoint returns JSON, stores no transport sessions,
          and provides no GET event stream. Each write needs a stable logical_request_key; reuse it
          unchanged after a lost response.
        </p>
      </.card>
      <.card title="Finite operation catalog">
        <p class="management-help">
          tools/list returns the operations permitted for the current API caller. All Worker, service,
          Zone and version identities are explicit; clients cannot change an implicit selected scope.
          Read access does not grant write or publication permission.
        </p>
        <table class="table" id="integration-tools">
          <thead>
            <tr>
              <th>Tool</th><th>Required scope</th><th>Purpose</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={tool <- @tools}>
              <td><code>{tool.id}</code></td><td>{tool.scope}</td><td>{tool.description}</td>
            </tr>
          </tbody>
        </table>
      </.card>
      <.card title="Current boundaries">
        <p class="management-help">
          DNS Views and ACLs remain configuration-only where the Worker compiler excludes them.
          IP artifact verification and selection do not prove Worker loading. Worker registration,
          credential rotation, bootstrap secrets, arbitrary files, raw command dispatch and Worker
          execution controls are excluded from this API. Login, consent and token issuance belong
          to the external authorization server.
        </p>
      </.card>
    </Layouts.app>
    """
  end

  defp enabled(true), do: "Enabled"
  defp enabled(false), do: "Disabled"
end
