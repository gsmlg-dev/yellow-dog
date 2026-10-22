import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { ClientCredentialsProvider } from '@modelcontextprotocol/sdk/client/auth-extensions.js';
import { fixture, jwt, scopes } from './mcp_fixture.mjs';
import { browser, until } from './mcp_browser.mjs';

const config = await fixture();
const base = config.resource;
const stateFile = join(process.env.MANAGEMENT_INTEGRATION_DIR, 'state.json');
const token = jwt(config);
const clients = [];
const sql = query => execFileSync('psql', [process.env.YELLOW_DOG_MANAGEMENT_DATABASE_URL,
  '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
const durableCounts = () => sql('SELECT (SELECT count(*) FROM management_audits) || \':\' || (SELECT count(*) FROM management_idempotency)');
async function http(path, { method = 'GET', body, key, expected = 200, access = token, headers = {} } = {}) {
  const response = await fetch(`${base}/api/v1${path}`, { method, headers: {
    Authorization: `Bearer ${access}`, ...(body ? { 'Content-Type': 'application/json', 'Idempotency-Key': key || crypto.randomUUID() } : {}), ...headers },
    ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(15000) });
  const result = await response.json();
  assert.equal(response.status, expected, JSON.stringify(result));
  return result.data ?? result.error;
}
async function connect(options = {}) {
  const provider = new ClientCredentialsProvider({ clientId: options.scope === 'config:read' ? 'integration-reader' : 'integration-client', clientSecret: config.secret,
    expectedIssuer: config.issuer, scope: options.scope || scopes });
  const client = new Client({ name: 'yellow-dog-integration', version: '1.0.0' }, { capabilities: {} });
  const transport = new StreamableHTTPClientTransport(new URL(`${base}/mcp`), {
    authProvider: provider, ...(options.fetch ? { fetch: options.fetch } : {}) });
  clients.push(client);
  await client.connect(transport);
  assert.equal(transport.protocolVersion, '2025-11-25');
  return { client, transport };
}
async function tool(client, name, args = {}, { error } = {}) {
  const result = await client.callTool({ name, arguments: args });
  assert.equal(result.isError, !!error, JSON.stringify(result));
  assert.equal(typeof result.structuredContent.correlation_id, 'string');
  assert.deepEqual(JSON.parse(result.content[0].text), result.structuredContent);
  if (error) { assert.equal(result.structuredContent.error.code, error); return result.structuredContent.error; }
  return result.structuredContent.data;
}
const command = (client, name, args, key = crypto.randomUUID()) => tool(client, name, { ...args, logical_request_key: key });

try {
  const unauth = await fetch(`${base}/mcp`, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: '{}' });
  assert.equal(unauth.status, 401);
  assert.match(unauth.headers.get('www-authenticate'), /resource_metadata=/);
  const metadata = await (await fetch(`${base}/.well-known/oauth-protected-resource`)).json();
  assert.equal(metadata.resource, base);
  assert.deepEqual(metadata.authorization_servers, [config.issuer]);
  const { client } = await connect(); // Actual 401 -> metadata -> external issuer -> token -> initialize lifecycle.
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 42);
  assert.ok(tools.every(entry => entry.inputSchema && entry.outputSchema));
  console.log('PASS SDK1.32.1 OAuth client_credentials discovery, token acquisition, initialize2025-11-25 and finite42-tool catalog');

  if (process.argv[2] === 'restart') {
    const state = JSON.parse(await readFile(stateFile, 'utf8'));
    assert.deepEqual(await tool(client, 'zone_get', { id: state.zone.id }), state.zone);
    assert.deepEqual(await tool(client, 'zone_assignments', { zone_id: state.zone.id }), state.assignments);
    assert.deepEqual(await tool(client, 'zone_version_get', { zone_id: state.zone.id, version_id: state.version.id }), state.version);
    assert.deepEqual(await tool(client, 'worker_target_get', { worker_id: state.worker, revision: state.target.revision }), state.target);
    assert.deepEqual(await tool(client, 'worker_target_export', { worker_id: state.worker, revision: state.target.revision }), state.exported);
    assert.deepEqual(await tool(client, 'audit_list', { page_size: 100 }), state.audit);
    assert.equal(durableCounts(), state.counts);
    assert.equal((await command(client, 'zone_update', state.retryArgs, state.retryKey)).revision, state.zone.revision);
    assert.equal(durableCounts(), state.counts, 'Restart replay created a receipt or audit');
    await browser(base, jwt(config, 'gateway'), async ({ navigate, evaluate }) => {
      await navigate(`/management/zones/${state.zone.id}/application`);
      assert.equal(await evaluate("document.querySelectorAll('#zone-assignments-form fieldset').length"), 2);
      await navigate(`/server/${state.worker}/targets/${state.target.revision}`);
      assert.ok((await evaluate('document.body.textContent')).includes(state.target.digest));
      await navigate('/system/ip-database');
      assert.ok((await evaluate('document.body.textContent')).includes(state.artifact.digest));
    });
    console.log('PASS restart: new SDK/Chromium clients read identical draft, fixed assignments, immutable version/target/export, artifact and audit; stable-key receipt replay unchanged');
  } else {
    assert.deepEqual((await http('/workers')).items, [], 'Disposable database required');
    assert.deepEqual((await http('/zones')).items, []);
    const workers = [];
    const services = [];
    let zone;
    await browser(base, jwt(config, 'gateway'), async ({ navigate, submit, until, click, change, evaluate }) => {
      for (const name of ['Integration Worker A', 'Integration Worker B']) {
        await navigate('/management/servers');
        await submit('#worker-form', { 'worker[name]': name });
        let worker;
        await until(async () => { worker = (await http('/workers')).items.find(row => row.name === name); return !!worker; }, 'UI Worker registration');
        workers.push(worker);
        await until(() => evaluate("!!document.querySelector('#worker-bootstrap')"), 'Transient bootstrap');
        await click('[phx-click="dismiss_connection"]');
        await navigate(`/server/${worker.id}/services/new`);
        await submit('#service-form', { 'service[id]': 'dns', 'service[listen_address]': '127.0.0.1', 'service[port]': String(18553 + workers.length), 'service[desired_state]': 'stopped' });
        let service;
        await until(async () => { service = (await http(`/workers/${worker.id}/services`)).items[0]; return !!service; }, 'UI DNS instance');
        services.push(service);
      }
      await navigate('/management/zones/new');
      await click('[phx-click="add_record"]');
      await until(() => evaluate("document.querySelectorAll('#zone-form fieldset').length === 3"), 'Zone rows');
      const name = 'integration.test.';
      const records = [
        { name, type: 'SOA', ttl: 300, data: { mname: `ns.${name}`, rname: `hostmaster.${name}`, serial: 1, refresh: 3600, retry: 600, expire: 86400, minimum: 300 } },
        { name, type: 'NS', ttl: 300, data: { host: `ns.${name}` } },
        { name: `ns.${name}`, type: 'A', ttl: 300, data: { address: '192.0.2.10' } } ];
      const fields = { 'zone[name]': name };
      records.forEach((row, index) => {
        for (const key of ['name', 'type', 'ttl']) fields[`zone[records][${index}][${key}]`] = String(row[key]);
        for (const [key, value] of Object.entries(row.data)) fields[`zone[records][${index}][data][${key}]`] = String(value);
      });
      await submit('#zone-form', fields);
      await until(async () => { const row = (await http('/zones')).items[0]; zone = row && await http(`/zones/${row.id}`); return !!zone; }, 'UI Zone draft');
      await navigate(`/management/zones/${zone.id}/edit`);
      const remoteRecords = structuredClone(zone.records);
      remoteRecords.find(row => row.type === 'A').data.address = '192.0.2.11';
      zone = await http(`/zones/${zone.id}`, { method: 'PATCH', body: { expected_revision: zone.revision, name, records: remoteRecords } });
      const addressField = await evaluate("document.querySelector('#zone-form [name$=\"[address]\"]').name");
      await submit('#zone-form', { [addressField]: '192.0.2.12' });
      await until(() => evaluate("document.body.textContent.includes('Expected revision does not match current revision')"), 'Stale UI conflict');
      assert.equal((await http(`/zones/${zone.id}`)).revision, zone.revision);
    });
    assert.deepEqual(await tool(client, 'zone_get', { id: zone.id }), zone);
    const version = await command(client, 'zone_confirm', { id: zone.id, expected_revision: zone.revision });
    assert.equal(version.source_revision, zone.revision);
    const snapshot = await tool(client, 'zone_assignments', { zone_id: zone.id });
    const revisions = Object.fromEntries(await Promise.all(workers.map(async worker => [worker.id, (await http(`/workers/${worker.id}`)).revision])));
    const assignments = await command(client, 'zone_set_assignments', { zone_id: zone.id,
      expected_assignment_token: snapshot.assignment_token, expected_worker_revisions: revisions,
      assignments: services.map((service, index) => ({ worker_id: workers[index].id, service_id: service.id, resource_version_id: version.id })) });
    assert.equal(assignments.assignments.length, 2);
    assert.deepEqual(await http(`/zones/${zone.id}/assignments`), assignments);
    await browser(base, jwt(config, 'gateway'), async ({ navigate, evaluate }) => {
      await navigate(`/management/zones/${zone.id}/application`);
      assert.equal(await evaluate("document.querySelectorAll('#zone-assignments-form fieldset').length"), 2);
      const values = await evaluate("Array.from(document.querySelectorAll('#zone-assignments-form select[name$=\"[resource_version_id]\"]')).map(field=>field.value)");
      assert.deepEqual(values, [version.id, version.id]);
    });
    const preview = await tool(client, 'worker_target_preview', { worker_id: workers[0].id });
    const other = (await connect()).client;
    const worker = await tool(other, 'worker_get', { worker_id: workers[0].id });
    await http(`/workers/${worker.id}`, { method: 'PATCH', body: { expected_revision: worker.revision, name: 'Integration Worker A revised' } });
    await tool(client, 'worker_target_publish', { worker_id: worker.id, expected_revision: preview.worker_revision, logical_request_key: 'stale-publication' }, { error: 'revision_conflict' });
    const reviewed = await tool(client, 'worker_target_preview', { worker_id: worker.id });
    const publication = await command(client, 'worker_target_publish', { worker_id: worker.id, expected_revision: reviewed.worker_revision });
    assert.equal(publication.worker_revision, reviewed.worker_revision + 1);
    const target = await tool(client, 'worker_target_get', { worker_id: worker.id, revision: publication.revision });
    const { worker_revision: _revision, ...publishedTarget } = publication;
    assert.deepEqual(publishedTarget, target);
    const exported = await tool(client, 'worker_target_export', { worker_id: worker.id, revision: target.revision });
    assert.deepEqual(await http(`/workers/${worker.id}/targets/${target.revision}`), target);
    assert.deepEqual(await http(`/workers/${worker.id}/targets/${target.revision}/export`), exported);
    assert.match(exported.toml, /integration\.test\./);
    assert.equal(target.actual_state, 'unknown');
    assert.deepEqual(target.export_scope.excluded, ['dns_views', 'dns_acls', 'geoip_artifacts']);
    console.log('PASS UI registered2Workers+DNS+Zone; HTTP edited draft; MCP confirmed+assigned fixed version; UI canonical reread; stale UI and MCP publication conflicts; exact reviewed target/export');

    // Discard the committed response at the actual transport boundary, then reconnect and retry.
    const retryKey = 'lost-response-zone-update';
    const retryArgs = { id: zone.id, expected_revision: zone.revision, name: zone.name, records: zone.records };
    let dropped = false;
    const lost = (await connect({ fetch: async (url, options) => {
      const response = await fetch(url, options);
      if (!dropped && typeof options?.body === 'string' && options.body.includes(retryKey)) {
        await response.arrayBuffer(); dropped = true; throw new TypeError('Fixture discarded committed response');
      }
      return response;
    } })).client;
    const before = durableCounts().split(':').map(Number);
    await assert.rejects(command(lost, 'zone_update', retryArgs, retryKey));
    assert.ok(dropped);
    const afterDrop = durableCounts().split(':').map(Number);
    assert.deepEqual(afterDrop, before.map(value => value + 1));
    const fresh = (await connect()).client;
    zone = await command(fresh, 'zone_update', retryArgs, retryKey);
    assert.equal(durableCounts(), afterDrop.join(':'));
    assert.deepEqual(await http(`/zones/${zone.id}`, { method: 'PATCH', body: retryArgs, key: retryKey }), zone, 'HTTP replay shares MCP business identity');
    assert.equal(durableCounts(), afterDrop.join(':'));
    const reader = (await connect({ scope: 'config:read' })).client;
    assert.ok((await reader.listTools()).tools.every(entry => entry.annotations.readOnlyHint));
    await tool(reader, 'zone_update', { ...retryArgs, logical_request_key: retryKey }, { error: 'forbidden' });
    assert.equal(durableCounts(), afterDrop.join(':'));
    console.log('PASS dropped-response retry through new SDK connection and HTTP replays exactly one receipt+audit; read-only replay denied');

    const job = await command(client, 'ip_database_sync', { key: 'ip_city' });
    assert.equal(typeof job.id, 'number');
    await until(async () => (await http(`/tasks/ip_city/jobs/${job.id}`)).state === 'completed', 'IP sync completed', 300);
    const artifact = (await tool(client, 'ip_database_catalog', { kind: 'city' })).selected;
    assert.ok(artifact?.digest);
    assert.equal(artifact.verification, 'unknown');
    await writeFile(process.env.MANAGEMENT_DATA_SOURCE_FILE, 'invalid fixture');
    const failed = await command(client, 'ip_database_sync', { key: 'ip_city' });
    assert.notEqual(failed.id, job.id);
    await until(async () => ['retryable', 'discarded'].includes((await http(`/tasks/ip_city/jobs/${failed.id}`)).state), 'IP sync failure', 300);
    assert.deepEqual((await tool(client, 'ip_database_catalog', { kind: 'city' })).selected, artifact);
    await browser(base, jwt(config, 'gateway'), async ({ navigate, evaluate, click, until }) => {
      await navigate(`/server/${worker.id}/targets/${target.revision}`);
      assert.ok((await evaluate('document.body.textContent')).includes(target.digest));
      await navigate('/system/ip-database');
      await click('#ip-database-refresh');
      await until(() => evaluate(`document.body.textContent.includes(${JSON.stringify(artifact.digest)})`), 'Selected artifact in UI');
      await navigate('/system/integrations');
      assert.equal(await evaluate("document.querySelector('#integration-status [data-mode]').dataset.mode"), 'protected_remote');
      assert.equal(await evaluate("document.querySelectorAll('#integration-tools tbody tr').length"), 42);
      const text = await evaluate('document.body.textContent');
      assert.ok(!text.includes(token)); assert.ok(!text.includes(config.secret)); assert.ok(!text.includes('PRIVATE KEY'));
    });
    const finalAssignments = await tool(client, 'zone_assignments', { zone_id: zone.id });
    assert.equal(finalAssignments.assignment_token, assignments.assignment_token);
    assert.deepEqual(finalAssignments.assignments.map(row => [row.id, row.service_id, row.resource_version_id]),
      assignments.assignments.map(row => [row.id, row.service_id, row.resource_version_id]));
    const state = { zone, version, assignments: finalAssignments, worker: worker.id, target, exported, artifact, retryArgs, retryKey,
      audit: await tool(client, 'audit_list', { page_size: 100 }), counts: durableCounts() };
    await writeFile(stateFile, JSON.stringify(state, null, 2));
    console.log('PASS MCP persistent sync job IDs, successful fixture artifact and failed replacement preserve selection; UI configured/verified state; safe integration information');
  }
} finally {
  await Promise.allSettled(clients.map(client => client.close()));
}
