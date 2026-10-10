import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve, sep } from 'node:path';

const base = process.env.MANAGEMENT_UI_URL || 'http://127.0.0.1:14281';
const macSmokePath = process.env.MANAGEMENT_MAC_SMOKE_PATH;
assert.ok(macSmokePath && resolve(macSmokePath).startsWith(resolve(tmpdir()) + sep) && basename(macSmokePath) === 'mac-browser-fixture.txt', 'Use the temporary MAC artifact from scripts/e2e/management_browser.sh');
const profile = await mkdtemp(join(tmpdir(), 'management-live-browser-'));
const chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
let socket;

async function until(check, message) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

async function api(path, body) {
  const response = await fetch(`${base}/api${path}`, body ? {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  } : { signal: AbortSignal.timeout(10000) });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return result.data;
}

function canonicalRecordContents(records) {
  return records.map(record => JSON.stringify([record.name, record.type, record.ttl, Object.entries(record.data).sort()])).sort();
}

try {
  assert.deepEqual(await api('/workers'), [], 'Use an empty disposable PostgreSQL database');
  assert.deepEqual(await api('/zones'), [], 'Use an empty disposable PostgreSQL database');
  const zone = await api('/commands/create_zone', {
    name: 'live.test.',
    records: [
      { name: 'live.test.', type: 'SOA', ttl: 300, data: { mname: 'ns.live.test.', rname: 'hostmaster.live.test.', serial: 1, refresh: 3600, retry: 600, expire: 86400, minimum: 300 } },
      { name: 'live.test.', type: 'NS', ttl: 300, data: { host: 'ns.live.test.' } },
      { name: 'ns.live.test.', type: 'A', ttl: 300, data: { address: '192.0.2.10' } },
    ],
  });
  const version = await api('/commands/confirm_zone', { id: zone.id, expected_revision: zone.revision });
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return true; }
    catch { return false; }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(`${base}/management`)}`, { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
  let sequence = 0;
  const pending = new Map();
  const errors = [];
  const loadedPages = new Set();
  let nextDialogDecision = null;
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Page.lifecycleEvent' && message.params.name === 'load') loadedPages.add(message.params.loaderId);
    if (message.method === 'Page.javascriptDialogOpening') {
      if (nextDialogDecision === null) errors.push({ unexpectedDialog: message.params });
      cdp('Page.handleJavaScriptDialog', { accept: nextDialogDecision === true }).catch(error => errors.push(error));
      nextDialogDecision = null;
    }
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
    if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') {
      const { source, text, url } = message.params.entry;
      errors.push({ source, text, url });
    }
    if (message.id) {
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) request.reject(message.error);
      else request.resolve(message.result);
    }
  });
  function cdp(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      pending.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const response = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  }
  async function navigate(path) {
    const navigation = await cdp('Page.navigate', { url: `${base}${path}` });
    if (navigation.loaderId) await until(async () => loadedPages.has(navigation.loaderId), `Page did not load: ${path}`);
    const pathname = new URL(path, base).pathname;
    await until(() => evaluate(`location.pathname === ${JSON.stringify(pathname)} && !!document.querySelector(".phx-connected")`), `LiveView did not connect: ${path}`);
  }
  async function submit(selector, values) {
    await evaluate(`(() => {
      const form = document.querySelector(${JSON.stringify(selector)});
      for (const [name, value] of Object.entries(${JSON.stringify(values)})) {
        const input = form.elements.namedItem(name);
        input.value = value;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      }
      form.requestSubmit();
    })()`);
  }
  async function previewBulk(records) {
    await evaluate(`(() => {
      const input = document.querySelector('#bulk-record-form textarea');
      input.value = ${JSON.stringify(JSON.stringify(records, null, 2))};
      input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`);
  }
  await cdp('Runtime.enable');
  await cdp('Log.enable');
  await cdp('Page.enable');
  await cdp('Page.setLifecycleEventsEnabled', { enabled: true });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await navigate('/management');
  assert.equal(await evaluate('document.querySelector("input[type=password], #login") === null'), true);
  assert.equal(await evaluate('!!document.querySelector("#yd-layout .navbar")'), true);
  assert.notEqual(await evaluate('getComputedStyle(document.querySelector(".navbar")).backgroundColor'), 'rgba(0, 0, 0, 0)');
  assert.match(await evaluate('document.body.innerText'), /Management.*Servers.*Netman.*Tools.*System/s);
  assert.equal(await evaluate('document.querySelector(".yd-sidebar").scrollWidth <= document.querySelector(".yd-sidebar").clientWidth'), true, 'Desktop sidebar must not overflow horizontally');
  await evaluate('document.querySelector("#notifications-dropdown-popover-trigger").click()');
  await until(() => evaluate('document.querySelector("#notifications-dropdown-popover").matches(":popover-open")'), 'Original notifications dropdown did not open');
  assert.equal(await evaluate('document.querySelector("#notifications-dropdown-popover-trigger").getAttribute("aria-expanded")'), 'true');
  await evaluate('document.querySelector("#notifications-dropdown-popover-trigger").click()');
  await evaluate(`document.querySelector('#theme-toggle input[value="sunshine"]').click()`);
  await until(() => evaluate('document.documentElement.dataset.theme === "sunshine"'), 'Sunshine theme did not activate');
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('.navbar-center a')).color !== getComputedStyle(document.querySelector('.navbar')).backgroundColor`), true, 'Navigation text must contrast with the primary header');

  assert.equal(await evaluate('document.querySelector("a[href=\'/management/profiles\'], #management-profile-count") === null'), true, 'Profiles must not appear in navigation or the overview');
  const removedProfiles = await fetch(`${base}/management/profiles`, { signal: AbortSignal.timeout(10000) });
  assert.equal(removedProfiles.status, 404, 'Profiles route must be removed');
  await navigate('/management/events');
  assert.equal(await evaluate('!!document.querySelector("#management-events")'), true);
  assert.deepEqual(await api('/workers'), [], 'Reading Management pages must not register a Worker');
  await navigate('/tool/whois');
  await submit('#whois-lookup-form', { query: ' ' });
  await until(() => evaluate('document.querySelector("#whois-lookup-form input").value === "" && !document.querySelector("#whois-lookup-form input").disabled'), 'Blank WHOIS query did not reset without blocking the form');
  assert.equal(await evaluate('document.querySelector("#whois-lookup-error, #whois-lookup-result") === null'), true);

  for (const id of ['settings', 'dns']) await api('/commands/create_worker', { id, name: `${id} Worker`, expected_capabilities: ['dns'] });
  await navigate('/server/settings/dashboard');
  assert.equal(await evaluate('document.querySelector("#server-selection-form-select").value'), 'settings');
  assert.equal(await evaluate(`document.querySelector('a[href="/server/settings/dns"]').textContent.trim()`), 'Overview');
  await evaluate(`document.querySelector('a[href="/server/settings/dns"]').click()`);
  await until(() => evaluate('location.pathname === "/server/settings/dns" && document.querySelector("#server-selection-form-select").value === "settings"'), 'Worker DNS overview lost its explicit selection');

  await navigate('/management/zones?server_id[]=settings');
  assert.equal(await evaluate(`!!document.querySelector('a[href="/management/zones/new"]')`), true, 'Query-only scope must not rewrite global Zone navigation');
  await navigate('/management/zones/import?server_id[id]=settings');
  assert.equal(await evaluate(`!!document.querySelector('#zone-import-form')`), true, 'Malformed query-only scope must not crash global Zone import');
  await navigate(`/management/zones/${zone.id}/records/new?server_id[]=settings&zone_id=not-the-route&rr_index[]=0`);
  assert.equal(await evaluate(`!!document.querySelector('#record-form')`), true, 'Malformed query identity must not change the global record scope');
  await navigate('/server/settings/dns/zones?server_id[]=dns');
  assert.equal(await evaluate(`!!document.querySelector('a[href="/server/settings/dns/zones/new"]')`), true, 'Query identity overrode the explicitly scoped Worker');
  assert.deepEqual((await api(`/zones/${zone.id}`)).records, zone.records, 'Read-only routing checks changed the Zone');

  await navigate('/server');
  await submit('#worker-form', { 'worker[id]': 'live-worker', 'worker[name]': 'Live Browser Worker' });
  await until(() => evaluate('!!document.querySelector("#server-selector-live-worker")'), 'Logical Worker was not registered');
  await until(() => evaluate(`document.querySelector('[name="worker[id]"]').value === ''`), 'Worker registration form did not reset');
  await evaluate('document.querySelector("#server-selector-live-worker a").click()');
  await until(() => evaluate('!!document.querySelector("#server-dashboard")'), 'Live navigation to dashboard failed');
  await submit('#service-form', { 'service[id]': 'dns', 'service[listen_address]': '127.0.0.1', 'service[port]': '5300', 'service[desired_state]': 'stopped' });
  await until(() => evaluate('document.querySelector("#dns-services").innerText.includes("stopped")'), 'Desired DNS service was not saved');
  const worker = await api('/workers/live-worker');
  await submit('#assignment-form', { 'assignment[service_id]': worker.services[0].id, 'assignment[resource_version_id]': version.id });
  await until(async () => (await api('/workers/live-worker')).assignments.length === 1, 'Immutable Zone version was not assigned');
  await evaluate('document.querySelector("[phx-click=preview]").click()');
  await until(() => evaluate('!!document.querySelector("#target-preview")'), 'Target preview failed');
  assert.match(await evaluate('document.querySelector("#target-preview").innerText'), /prepared_preview/);
  await evaluate('document.querySelector("[phx-click=confirm_target]").click()');
  await until(() => evaluate(`!!document.querySelector('a[href*="/targets/1/export"]')`), 'Target confirmation failed');
  const target = await api('/workers/live-worker/targets/1');
  assert.equal(target.actual_state, 'unknown');
  assert.equal(target.status, 'prepared');
  const exported = await fetch(`${base}/api/workers/live-worker/targets/1/export`, { signal: AbortSignal.timeout(10000) });
  assert.equal(exported.status, 200);
  const exportedToml = await exported.text();
  assert.match(exportedToml, /live\.test\./);
  await navigate('/management/config');
  assert.match(await evaluate(`document.getElementById(${JSON.stringify(`config-version-${target.id}`)}).innerText`), new RegExp(target.digest));
  assert.equal(await evaluate(`document.getElementById(${JSON.stringify(`config-version-${target.id}`)}).dataset.actualState`), 'unknown');
  assert.match(await evaluate('document.querySelector("#management-config-versions").innerText'), /prepared/);
  await evaluate('document.querySelector("#management-config-refresh").click()');
  await until(() => evaluate(`!!document.getElementById(${JSON.stringify(`config-version-${target.id}`)})`), 'Config refresh lost an immutable target');
  assert.deepEqual(await api('/netmans'), []);
  await navigate('/management/netman');
  await submit('#netman-form', { 'netman[id]': 'live-netman', 'netman[name]': 'Live Netman' });
  await until(() => evaluate('!!document.querySelector("#netman-selector-live-netman")'), 'Logical Netman registration failed');
  await until(() => evaluate(`document.querySelector('[name="netman[id]"]').value === ''`), 'Netman registration form did not reset');
  const netman = await api('/netmans/live-netman');
  assert.equal(netman.actual_state, 'unknown');
  assert.equal(netman.last_seen_at, null);
  await navigate('/netman/live-netman?netman_id[]=other');
  assert.equal(await evaluate('document.querySelector("#netman-selection-form-select").value'), 'live-netman', 'Query identities changed the scoped Netman');
  await navigate('/netman/live-netman/config?netman_id[id]=other');
  await submit('#netman-profile-form', { 'profile[profile_id]': 'wired', 'profile[interface]': 'eth0', 'profile[zone]': 'lan', 'profile[ipv4_method]': 'manual', 'profile[ipv4_address]': '192.0.2.10/24', 'profile[ipv4_gateway]': '192.0.2.1', 'profile[ipv4_dns]': '192.0.2.53', 'profile[ipv6_method]': 'disabled' });
  await until(async () => (await api('/netmans/live-netman/config')).document.profiles.length === 1, 'Typed Ethernet desired profile was not saved');
  await until(() => evaluate(`document.querySelector('[name="profile[profile_id]"]').value === ''`), 'Netman profile editor did not reset after save');
  await evaluate('document.querySelector("#confirm-netman-config").click()');
  await until(async () => (await api('/netmans/live-netman/versions')).length === 1, 'Immutable Netman desired version was not prepared');
  const firstNetmanVersion = (await api('/netmans/live-netman/versions'))[0];
  await evaluate('document.querySelector("#netman-desired-profiles [phx-click=edit_profile]").click()');
  await until(() => evaluate(`document.querySelector('[name="profile[profile_id]"]').value === 'wired'`), 'Desired profile edit did not load');
  const beforeInvalidNetman = await api('/netmans/live-netman/config');
  await submit('#netman-profile-form', { 'profile[ipv4_address]': '2001:db8::1/64' });
  await until(() => evaluate('document.querySelector("#yd-layout").innerText.includes("ipv4")'), 'Invalid address family did not show a validation result');
  assert.deepEqual(await api('/netmans/live-netman/config'), beforeInvalidNetman, 'Invalid Ethernet edit mutated desired data');
  await submit('#netman-profile-form', { 'profile[ipv4_address]': '192.0.2.11/24', 'profile[autoconnect_priority]': '20' });
  await until(async () => (await api('/netmans/live-netman/config')).document.profiles[0].ipv4.address === '192.0.2.11/24', 'Ethernet profile editing failed');
  await navigate('/netman/live-netman/resolved');
  await submit('#netman-resolved-form', { 'resolved[upstreams]': '192.0.2.53, 2001:db8::53', 'resolved[search_domains]': 'example.test' });
  await until(async () => (await api('/netmans/live-netman/config')).document.resolved.upstreams.length === 2, 'Desired Resolved settings were not saved');
  assert.equal((await api('/netmans/live-netman/config')).document.profiles[0].ipv4.address, '192.0.2.11/24', 'Resolved editing dropped the Ethernet profile');
  await evaluate('document.querySelector("#confirm-netman-config").click()');
  await until(async () => (await api('/netmans/live-netman/versions')).length === 2, 'Second Netman desired version was not prepared');
  nextDialogDecision = true;
  await evaluate(`(() => { const form = document.querySelector('#netman-config-rollback-form'); form.elements.namedItem('rollback[target_version]').value = '1'; document.querySelector('#rollback-netman-config').click(); })()`);
  await until(async () => (await api('/netmans/live-netman/versions')).length === 3, 'Desired Netman rollback failed');
  assert.equal(nextDialogDecision, null, 'Desired rollback must use its confirmation dialog');
  const rolledNetmanVersion = (await api('/netmans/live-netman/versions'))[0];
  assert.deepEqual(rolledNetmanVersion.document, firstNetmanVersion.document);
  assert.equal(rolledNetmanVersion.digest, firstNetmanVersion.digest);
  assert.equal(rolledNetmanVersion.rollback_source_id, firstNetmanVersion.id);
  assert.equal(rolledNetmanVersion.actual_state, 'unknown');
  await navigate('/management/config');
  assert.equal(await evaluate(`document.getElementById(${JSON.stringify(`config-version-${rolledNetmanVersion.id}`)}).dataset.netmanId`), 'live-netman');
  await navigate('/netman/live-netman/config');
  nextDialogDecision = true;
  await evaluate('document.querySelector("#netman-desired-profiles [phx-click=delete_profile]").click()');
  await until(async () => (await api('/netmans/live-netman/config')).document.profiles.length === 0, 'Desired Ethernet profile deletion failed');
  assert.deepEqual((await api('/netmans/live-netman/versions'))[0], rolledNetmanVersion, 'Profile deletion mutated historical publications');
  await api('/commands/create_netman', { id: 'live-observer', profile_name: 'observe_only' });
  await navigate('/netman/live-observer/config');
  assert.equal(await evaluate('document.querySelector("#confirm-netman-config").disabled'), true, 'Observe-only publication was not disabled');
  assert.match(await evaluate('document.body.innerText'), /Observe mode is read-only/);
  await navigate('/management/zones');
  assert.match(await evaluate('document.body.innerText'), /live\.test\./);
  await navigate(`/management/zones/${zone.id}/edit`);
  assert.equal(await evaluate('document.querySelector("#zone-name").value'), 'live.test.');
  await evaluate(`document.querySelector('a[href="/management/zones/new"]').click()`);
  await until(() => evaluate('location.pathname === "/management/zones/new" && document.querySelector("#zone-name").value === ""'), 'Phoenix New Zone navigation did not reset the edited identity');
  assert.equal((await api('/zones')).length, 1, 'New navigation must not mutate the draft');
  const recordsPath = `/management/zones/${zone.id}/records`;
  await navigate(`${recordsPath}/new`);
  await submit('#record-form', { 'record[name]': 'www', 'record[type]': 'A', 'record[ttl]': '300', 'record[data][address]': '192.0.2.20' });
  await until(async () => (await api(`/zones/${zone.id}`)).records.some(record => record.name === 'www.live.test.'), 'Single DNS record creation failed');
  const createdRecords = (await api(`/zones/${zone.id}`)).records;
  const createdIndex = createdRecords.findIndex(record => record.name === 'www.live.test.');
  await navigate(`${recordsPath}/${createdIndex}/edit`);
  await submit('#record-form', { 'record[name]': 'www.live.test.', 'record[type]': 'A', 'record[ttl]': '300', 'record[data][address]': '192.0.2.21' });
  await until(async () => (await api(`/zones/${zone.id}`)).records.some(record => record.data.address === '192.0.2.21'), 'Single DNS record editing failed');
  await navigate(`${recordsPath}/bulk`);
  const bulkRecord = { name: 'bulk.live.test.', type: 'A', ttl: 300, data: { address: '192.0.2.22' } };
  const beforeBulk = await api(`/zones/${zone.id}`);
  await previewBulk([bulkRecord, { ...bulkRecord, name: 'bad.live.test.', data: { address: 'invalid' } }]);
  await until(() => evaluate('!!document.querySelector("#record-error")'), 'Invalid bulk input did not show a validation error');
  assert.deepEqual(await api(`/zones/${zone.id}`), beforeBulk, 'Invalid bulk input partially changed the draft');
  await previewBulk([bulkRecord]);
  await until(() => evaluate('!!document.querySelector("#bulk-record-preview") && !document.querySelector("#bulk-record-save").disabled'), 'Bulk preview did not validate the candidate');
  await evaluate('document.querySelector("#bulk-record-form").requestSubmit()');
  await until(async () => (await api(`/zones/${zone.id}`)).records.some(record => record.name === 'bulk.live.test.'), 'Bulk record addition failed');
  await navigate(recordsPath);
  const beforeRecordDelete = await api(`/zones/${zone.id}`);
  const deleteIndex = beforeRecordDelete.records.findIndex(record => record.name === 'www.live.test.');
  nextDialogDecision = false;
  await evaluate(`document.querySelector('#record-${deleteIndex} button[phx-click="delete_record"]').click()`);
  assert.equal(nextDialogDecision, null, 'Cancelled record deletion must exercise the confirmation dialog');
  assert.deepEqual(await api(`/zones/${zone.id}`), beforeRecordDelete, 'Cancelled record deletion must not mutate the draft');
  nextDialogDecision = true;
  await evaluate(`document.querySelector('#record-${deleteIndex} button[phx-click="delete_record"]').click()`);
  try {
    await until(async () => !(await api(`/zones/${zone.id}`)).records.some(record => record.name === 'www.live.test.'), 'Single DNS record deletion failed');
  } catch (error) {
    console.error('Record deletion diagnostics', { nextDialogDecision, errors, page: await evaluate('({ url: location.href, text: document.body.innerText, connected: !!document.querySelector(".phx-connected") })'), zone: await api(`/zones/${zone.id}`) });
    throw error;
  }
  assert.equal(nextDialogDecision, null, 'Record deletion must exercise the confirmation dialog');
  assert.equal((await api(`/zones/${zone.id}/versions`)).length, 1, 'Record editing must not confirm a new immutable version');
  const afterRecordExport = await fetch(`${base}/api/workers/live-worker/targets/1/export`, { signal: AbortSignal.timeout(10000) });
  assert.equal(await afterRecordExport.text(), exportedToml, 'Draft edits changed a historical export');
  await navigate('/management/zones/import');
  await submit('#zone-import-form', { 'import[toml]': exportedToml });
  await until(() => evaluate('!!document.querySelector("#zone-import-preview")'), 'WorkerPlan Zone import preview failed');
  const importedResourceId = await evaluate('document.querySelector("#zone-import-resource").value');
  await submit('#zone-import-selection-form', { 'import[resource_id]': importedResourceId });
  await until(() => evaluate('document.querySelector("#zone-import-errors")?.innerText.includes("already exists")'), 'Duplicate import must report the actual Zone name conflict');
  const beforeUnassign = await api('/workers/live-worker');
  await api('/commands/unassign', { worker_id: 'live-worker', expected_revision: beforeUnassign.revision, service_id: worker.services[0].id, zone_id: zone.id });
  const beforeDelete = await api(`/zones/${zone.id}`);
  await api('/commands/delete_zone', { id: zone.id, expected_revision: beforeDelete.revision });
  await submit('#zone-import-form', { 'import[toml]': exportedToml });
  await until(() => evaluate('!!document.querySelector("#zone-import-preview")'), 'Import revalidation failed');
  await submit('#zone-import-selection-form', { 'import[resource_id]': importedResourceId });
  await until(() => evaluate('!!document.querySelector("#zone-import-result")'), 'Validated WorkerPlan Zone import did not persist a draft');
  const [importedZone] = await api('/zones');
  assert.notEqual(importedZone.id, zone.id);
  assert.deepEqual(canonicalRecordContents(importedZone.records), canonicalRecordContents((await api(`/zones/${zone.id}/versions`))[0].content.records), 'Import must preserve the exported immutable record content, not the edited draft');
  assert.deepEqual(await api(`/zones/${importedZone.id}/versions`), [], 'Import must create only a draft');
  const afterImportExport = await fetch(`${base}/api/workers/live-worker/targets/1/export`, { signal: AbortSignal.timeout(10000) });
  assert.equal(await afterImportExport.text(), exportedToml, 'Import changed a historical export');
  await navigate('/tool/mac');
  await submit('form', { mac: '00:00:0A:BB:28:FC' });
  await until(() => evaluate('document.body.innerText.includes("Omron")'), 'MAC vendor lookup failed');
  await navigate('/system/mac-database');
  assert.equal(await evaluate('document.querySelector("#mac-database-status").dataset.source'), 'file');
  assert.equal(await evaluate('document.querySelector("#mac-database-status").dataset.entryCount'), '2');
  await submit('#mac-database-lookup-form', { mac: '02:01:02:03:04:05' });
  await until(() => evaluate('document.querySelector("#mac-database-lookup-result")?.innerText.includes("Management Browser OUI Fixture")'), 'MAC Database lookup did not use the configured actual artifact');
  await submit('#mac-database-lookup-form', { mac: 'invalid-mac' });
  await until(() => evaluate('!!document.querySelector("#mac-database-lookup-error")'), 'Invalid MAC address did not render an error');
  const originalMacContents = await readFile(macSmokePath, 'utf8');
  try {
    await writeFile(macSmokePath, '00:00:0A\tOmronTat\tOmron Tateisi Electronics Co.\n02:01:02\tUpdated\tUpdated Browser OUI Fixture\n02:99:00\tAdded\tAdded Browser OUI Fixture\n');
    await evaluate('document.querySelector("#mac-database-reload").click()');
    await until(() => evaluate('document.querySelector("#mac-database-status").dataset.entryCount === "3" && document.querySelector("#mac-database-status").dataset.status === "loaded"'), 'MAC reload did not activate the actual replacement file');
    await submit('#mac-database-lookup-form', { mac: '02:01:02:03:04:05' });
    await until(() => evaluate('document.querySelector("#mac-database-lookup-result")?.innerText.includes("Updated Browser OUI Fixture")'), 'MAC Database lookup did not follow reload');
    await navigate('/tool/mac');
    await submit('#mac-lookup-form', { mac: '02:01:02:03:04:05' });
    await until(() => evaluate('document.querySelector("#mac-lookup-result")?.innerText.includes("Updated Browser OUI Fixture")'), 'MAC tool and database page do not share the active runtime snapshot');
    await navigate('/system/mac-database');
    await writeFile(macSmokePath, 'not a manufacturer database\n');
    await evaluate('document.querySelector("#mac-database-reload").click()');
    await until(() => evaluate('!!document.querySelector("#mac-database-error") && document.querySelector("#mac-database-status").dataset.status === "error"'), 'Invalid MAC artifact reload did not report its real failure');
    await submit('#mac-database-lookup-form', { mac: '02:01:02:03:04:05' });
    await until(() => evaluate('document.querySelector("#mac-database-lookup-result")?.innerText.includes("Updated Browser OUI Fixture")'), 'Failed reload destroyed the last valid MAC snapshot');
  } finally {
    await writeFile(macSmokePath, originalMacContents);
  }
  await evaluate('document.querySelector("#mac-database-reload").click()');
  await until(() => evaluate('document.querySelector("#mac-database-status").dataset.entryCount === "2" && document.querySelector("#mac-database-status").dataset.status === "loaded" && !document.querySelector("#mac-database-error")'), 'MAC artifact recovery did not restore the configured snapshot');
  await navigate('/tool/geoip');
  await submit('#geoip-lookup-form', { ip: '216.160.83.56', type: 'city' });
  await until(() => evaluate('!!document.querySelector("#geoip-lookup-result")'), 'GeoIP lookup requires the real MMDB smoke fixture to be configured');
  const geoipResult = await evaluate('document.querySelector("#geoip-lookup-result").innerText');
  for (const value of ['United States', 'Milton', 'Washington', 'North America', 'America/Los_Angeles', '98354', '47.2513, -122.3149']) assert.ok(geoipResult.includes(value), `Real MMDB lookup missing ${value}`);
  await submit('#geoip-lookup-form', { ip: 'invalid-ip', type: 'city' });
  await until(() => evaluate('!!document.querySelector("#geoip-lookup-error")'), 'Invalid GeoIP address did not render an error');
  assert.match(await evaluate('document.querySelector("#geoip-lookup-error").innerText'), /invalid.*IP|IP.*invalid/i);
  await navigate('/system/ip-database');
  assert.match(await evaluate('document.querySelector("#ip-database-city").innerText'), /GeoIP2-City/);
  assert.equal(await evaluate('document.querySelector("#ip-database-city [data-status]").dataset.status'), 'loaded');
  nextDialogDecision = false;
  await evaluate('document.querySelector("#ip-database-unload-city").click()');
  assert.equal(nextDialogDecision, null, 'GeoIP unload cancellation must exercise its confirmation dialog');
  assert.equal(await evaluate('document.querySelector("#ip-database-city [data-status]").dataset.status'), 'loaded', 'Cancelled GeoIP unload changed the cache');
  nextDialogDecision = true;
  await evaluate('document.querySelector("#ip-database-unload-city").click()');
  await until(() => evaluate('document.querySelector("#ip-database-city [data-status]").dataset.status === "unloaded"'), 'Accepted GeoIP unload failed');
  assert.equal(nextDialogDecision, null, 'GeoIP unload must exercise one confirmation dialog');
  await navigate('/tool/geoip');
  await submit('#geoip-lookup-form', { ip: '216.160.83.56', type: 'city' });
  await until(() => evaluate('!!document.querySelector("#geoip-lookup-error")'), 'Unloaded GeoIP lookup must report a real error');
  assert.match(await evaluate('document.querySelector("#geoip-lookup-error").innerText'), /not loaded|unloaded/i);
  await navigate('/system/ip-database');
  await evaluate('document.querySelector("#ip-database-reload-city").click()');
  await until(() => evaluate('document.querySelector("#ip-database-city [data-status]").dataset.status === "loaded"'), 'Configured MMDB reload failed');
  await navigate('/tool/geoip');
  await submit('#geoip-lookup-form', { ip: '216.160.83.56', type: 'city' });
  await until(() => evaluate('document.querySelector("#geoip-lookup-result")?.innerText.includes("Milton")'), 'Reloaded GeoIP cache did not restore lookup');
  await navigate('/management/events');
  assert.match(await evaluate('document.body.innerText'), /confirm_target/);
  await navigate('/system/logs/realtime');
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length > 0'), 'Genuine Management Logger snapshot did not render');
  await submit('#log-search-form', { search: 'CONNECTED TO Phoenix.LiveView.Socket' });
  await until(() => evaluate('document.querySelector("#log-container").innerText.includes("CONNECTED TO Phoenix.LiveView.Socket")'), 'Retained log search did not show the actual socket connection');
  await evaluate('document.querySelector("button[phx-click=select_no_apps]").click()');
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length === 0'), 'Select No Apps must hide all logs');
  await evaluate('document.querySelector("button[phx-click=select_all_apps]").click()');
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length > 0'), 'Select All Apps did not restore retained logs');
  await evaluate(`document.querySelector('button[phx-click="set_level"][phx-value-level="error"]').click()`);
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length === 0'), 'Minimum severity did not filter retained info events');
  await evaluate(`document.querySelector('button[phx-click="set_level"][phx-value-level="debug"]').click()`);
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length > 0'), 'Minimum severity reset did not restore info events');
  await evaluate('document.querySelector("button[phx-click=toggle_expand]").click()');
  await until(() => evaluate('!!document.querySelector("#log-container [id^=log-metadata-]")'), 'Log metadata expansion failed');
  await evaluate('document.querySelector("button[phx-click=toggle_pause]").click()');
  await until(() => evaluate('document.querySelector("#log-buffer-status").dataset.paused === "true"'), 'Log pause did not activate');
  const visibleWhilePaused = await evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length');
  const auxiliaryPage = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(`${base}/tool/mac`)}`, { method: 'PUT', signal: AbortSignal.timeout(10000) })).json();
  const auxiliarySocket = new WebSocket(auxiliaryPage.webSocketDebuggerUrl);
  try {
    await new Promise(resolve => auxiliarySocket.addEventListener('open', resolve, { once: true }));
    const auxiliaryConnected = new Promise((resolve, reject) => {
      auxiliarySocket.addEventListener('message', event => {
        const response = JSON.parse(event.data);
        if (response.id !== 1) return;
        if (response.error || response.result.exceptionDetails) reject(new Error(JSON.stringify(response)));
        else resolve(response.result.result.value);
      });
    });
    auxiliarySocket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: {
      expression: '(async () => { for (let attempt = 0; attempt < 100; attempt++) { if (document.querySelector(".phx-connected")) return true; await new Promise(resolve => setTimeout(resolve, 100)); } return false; })()',
      awaitPromise: true, returnByValue: true,
    } }));
    assert.equal(await auxiliaryConnected, true, 'Auxiliary browser must actually connect its LiveView websocket');
    await until(() => evaluate('Number(document.querySelector("#log-buffer-status").dataset.pending) > 0'), 'Paused log view did not buffer a genuine second browser connection');
    assert.equal(await evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length'), visibleWhilePaused, 'Paused view changed visible logs');
  } finally {
    auxiliarySocket.close();
    await fetch(`http://127.0.0.1:${port}/json/close/${auxiliaryPage.id}`, { signal: AbortSignal.timeout(10000) });
  }
  await evaluate('document.querySelector("button[phx-click=toggle_pause]").click()');
  await until(() => evaluate(`Number(document.querySelectorAll('#log-container [id^=log-row-]').length) > ${visibleWhilePaused} && document.querySelector('#log-buffer-status').dataset.pending === '0'`), 'Log resume did not flush pending observations');
  await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: profile });
  await evaluate('document.querySelector("#export-logs").click()');
  let logDownload;
  await until(async () => { logDownload = (await readdir(profile)).find(filename => filename.startsWith('management_logs_') && filename.endsWith('.csv')); return !!logDownload; }, 'Actual CSV download did not complete');
  const downloadedLogs = await readFile(join(profile, logDownload), 'utf8');
  assert.match(downloadedLogs, /^Timestamp,Level,App,Message,Metadata\r\n/);
  assert.match(downloadedLogs, /CONNECTED TO Phoenix\.LiveView\.Socket/);
  const replayLogId = await evaluate('document.querySelector("#log-container [id^=log-row-]").id');
  await evaluate('document.querySelector("button[phx-click=clear]").click()');
  await until(() => evaluate('document.querySelectorAll("#log-container [id^=log-row-]").length === 0'), 'Clear View did not clear local log history');
  await navigate('/system/logs/realtime');
  await until(() => evaluate(`!!document.getElementById(${JSON.stringify(replayLogId)})`), 'Clear View destroyed an existing backend replay entry');
  await navigate('/system/process-map');
  assert.equal(await evaluate('!!document.querySelector("#process-map-tree [data-process-node]")'), true);
  await evaluate('document.querySelector("#process-map-tree [data-process-node]").dispatchEvent(new MouseEvent("click", { bubbles: true }))');
  await until(() => evaluate('!!document.querySelector("#process-status-panel")'), 'Real Management process inspection failed');
  assert.match(await evaluate('document.querySelector("#process-status-panel").innerText'), /Management/);
  await evaluate('document.querySelector("#refresh-process-map").click()');
  await navigate('/management');
  if (process.env.MANAGEMENT_SCREENSHOT_PREFIX) {
    assert.equal(await evaluate('document.documentElement.dataset.theme'), 'sunshine', 'Selected theme did not persist across navigation');
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-desktop.png`, Buffer.from(screenshot.data, 'base64'));
  }
  await cdp('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await navigate('/management');
  assert.equal(await evaluate('innerWidth'), 390, 'Mobile viewport must use device width, not desktop scaling');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Mobile viewport overflows');
  await evaluate(`document.querySelector('button[aria-label="Open menu"]').click()`);
  await until(() => evaluate('document.querySelector("#yd-layout").classList.contains("yd-sidebar-open")'), 'Mobile drawer did not open');
  if (process.env.MANAGEMENT_SCREENSHOT_PREFIX) {
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-mobile.png`, Buffer.from(screenshot.data, 'base64'));
  }
  assert.deepEqual(errors, [], 'JavaScript, CSP or asset errors');
  console.log('PASS real Chromium: Console layout, websocket, read-only Profiles, blank WHOIS form, selected Worker/Netman scopes, logical registration, typed Ethernet/Resolved desired editing, immutable history/desired rollback, observe-only mode, Worker target/export, Zone reset/records/import, OUI/MMDB tools, audit/Logger/Process Map/mobile drawer; no login');
} finally {
  socket?.close();
  chromium.kill('SIGTERM');
  await Promise.race([new Promise(resolve => chromium.once('exit', resolve)), delay(2000)]);
  await rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}
