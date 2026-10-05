import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { isAbsolute } from 'node:path';

for (const variable of ['YELLOW_DOG_PHASE1_PG_DATA_DIR', 'MANAGEMENT_UI_URL', 'MANAGEMENT_WORKER_PROFILES_EVIDENCE', 'MANAGEMENT_WORKER_PROFILES_BROWSER_PROFILE']) {
  assert.ok(process.env[variable], `Required disposable harness input: ${variable}`);
}
const address = new URL(process.env.MANAGEMENT_UI_URL);
assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(address.hostname), 'Only the disposable loopback release may be tested');
assert.equal(address.username + address.password, '', 'Do not supply browser URL credentials');
const base = address.origin;
const evidencePath = process.env.MANAGEMENT_WORKER_PROFILES_EVIDENCE;
const profileDirectory = process.env.MANAGEMENT_WORKER_PROFILES_BROWSER_PROFILE;
assert.ok(isAbsolute(profileDirectory), 'Parent must provide an absolute fresh browser profile directory');
const verifyOnly = process.env.MANAGEMENT_WORKER_PROFILES_VERIFY_ONLY === '1';
const catalog = ['cloud_dns', 'local_network', 'dns_only', 'dhcp_only', 'netboot_only', 'custom'];
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const pending = new Map();
const actions = [];
const actionRequests = new Map();
const loadedPages = new Set();
const errors = [];
let sequence = 0;
let socket;
let chromium;
let chromiumClosed;
let closing = false;

async function until(check, message) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    assert.deepEqual(errors, [], 'Unexpected browser error');
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

async function api(path, body, expected = 200) {
  const response = await fetch(`${base}/api${path}`, {
    ...(body === undefined ? {} : {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() },
      body: JSON.stringify(body),
    }),
    signal: AbortSignal.timeout(10000),
  });
  const result = await response.json();
  assert.equal(response.status, expected, JSON.stringify(result));
  return expected === 200 ? result.data : result.error;
}

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timed out: ${method}`)); }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const response = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  assert.ok(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
  return response.result.value;
}

async function navigate(path, selector) {
  const expected = new URL(path, base);
  const navigation = await cdp('Page.navigate', { url: expected.href });
  assert.ok(!navigation.errorText, navigation.errorText);
  if (navigation.loaderId) await until(() => loadedPages.has(navigation.loaderId), `Page did not load: ${path}`);
  await until(() => evaluate(`location.pathname === ${JSON.stringify(expected.pathname)} && location.search === ${JSON.stringify(expected.search)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true, 'Fresh browser must work without login');
}

async function acknowledged(event, operation) {
  const start = actions.length;
  await operation();
  let action;
  await until(() => {
    action = actions.slice(start).find(item => item.event === event && item.reply);
    return !!action;
  }, `LiveView did not acknowledge ${event}`);
  assert.equal(action.reply.status, 'ok', JSON.stringify(action.reply));
}

async function submit(selector, values, injectProfile = false) {
  const event = await evaluate(`document.querySelector(${JSON.stringify(selector)}).getAttribute('phx-submit')`);
  assert.ok(event, `Missing LiveView form: ${selector}`);
  await acknowledged(event, () => evaluate(`(() => {
    const form = document.querySelector(${JSON.stringify(selector)});
    const values = ${JSON.stringify(values)};
    for (const [name, value] of Object.entries(values)) {
      const input = form.elements.namedItem(name);
      if (!input) throw new Error('Missing form field: ' + name);
      if (${injectProfile} && name === 'worker[profile_name]') input.add(new Option(value, value));
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
    form.requestSubmit();
  })()`));
}

async function refreshWorker() {
  const path = await evaluate('location.pathname + location.search');
  await navigate(path, '#worker-edit-form');
}

function workerPath(id, spoofId) {
  return `/server/${encodeURIComponent(id)}/dashboard${spoofId ? `?server_id=${encodeURIComponent(spoofId)}&worker_id=${encodeURIComponent(spoofId)}&id=${encodeURIComponent(spoofId)}` : ''}`;
}

function workerWithoutMetadata(worker) {
  const result = structuredClone(worker);
  for (const key of ['name', 'profile_name', 'revision']) delete result[key];
  return result;
}

async function fixtureSnapshot(id) {
  const worker = await api(`/workers/${encodeURIComponent(id)}`);
  const target = await api(`/workers/${encodeURIComponent(id)}/targets/latest`);
  const exportResponse = await fetch(`${base}/api/workers/${encodeURIComponent(id)}/targets/${target.revision}/export`, { signal: AbortSignal.timeout(10000) });
  assert.equal(exportResponse.status, 200, 'Confirmed target export must be available without authentication');
  assert.match(exportResponse.headers.get('content-type') || '', /application\/toml/);
  const bytes = Buffer.from(await exportResponse.arrayBuffer());
  const versions = {};
  for (const id of [...new Set(worker.assignments.map(assignment => assignment.zone_id))].sort()) {
    versions[id] = await api(`/zones/${encodeURIComponent(id)}/versions`);
  }
  return { worker, target, versions, export_base64: bytes.toString('base64'), export_sha256: createHash('sha256').update(bytes).digest('hex') };
}

function assertFixture(snapshot) {
  assert.deepEqual(snapshot.worker.expected_capabilities, ['dns']);
  assert.equal(snapshot.worker.actual_state, 'unknown');
  assert.equal(snapshot.worker.status, 'not_yet_connected');
  assert.ok(snapshot.worker.services.length > 0, 'Parent must seed a stopped DNS service');
  assert.ok(snapshot.worker.assignments.length > 0, 'Parent must seed a confirmed Zone assignment');
  for (const service of snapshot.worker.services) {
    assert.equal(service.type, 'dns');
    assert.equal(service.desired_state, 'stopped');
    assert.equal(service.actual_state, 'unknown');
  }
  for (const assignment of snapshot.worker.assignments) {
    assert.ok(snapshot.versions[assignment.zone_id].some(version => version.id === assignment.resource_version_id));
  }
  assert.equal(snapshot.target.worker_id, snapshot.worker.id);
  assert.equal(snapshot.target.actual_state, 'unknown');
  assert.equal(snapshot.target.status, 'prepared');
}

function assertFixtureUnchanged(before, after) {
  assert.deepEqual(workerWithoutMetadata(after.worker), workerWithoutMetadata(before.worker));
  for (const key of ['target', 'versions', 'export_base64', 'export_sha256']) {
    assert.deepEqual(after[key], before[key], `Profile metadata changed immutable fixture ${key}`);
  }
  assertFixture(after);
}

async function verifyList(workers) {
  await navigate('/management/servers', '#worker-form');
  assert.equal(await evaluate(`document.querySelector('#worker-profile').name`), 'worker[profile_name]');
  assert.equal(await evaluate(`document.querySelector('#worker-profile').value`), 'custom');
  const options = await evaluate(`Array.from(document.querySelector('#worker-profile').options).map(option => option.value).sort()`);
  assert.deepEqual(options, [...catalog].sort(), 'Only the six pure Server catalog presets should be selectable');
  for (const worker of workers) {
    const row = await evaluate(`(() => {
      const row = document.getElementById(${JSON.stringify(`server-selector-${worker.id}`)});
      return row && { profile_name: row.dataset.profileName, text: row.textContent, in_table: !!row.closest('#server-selector-records') };
    })()`);
    assert.ok(row, `Missing stored Worker row: ${worker.id}`);
    assert.equal(row.in_table, true);
    assert.equal(row.profile_name, worker.profile_name);
    assert.ok(row.text.includes(worker.name) && row.text.includes('unknown'));
    const listed = (await api('/workers')).find(item => item.id === worker.id);
    assert.ok(listed);
    for (const key of ['name', 'profile_name', 'revision', 'expected_capabilities', 'actual_state', 'status']) assert.deepEqual(listed[key], worker[key]);
  }
}

async function verifyEditor(worker, spoofId) {
  await navigate(workerPath(worker.id, spoofId), '#worker-edit-form');
  const form = await evaluate(`({ name: document.querySelector('#worker-edit-form').elements.namedItem('worker[name]').value, profile_name: document.querySelector('#worker-edit-profile').value, profile_field: document.querySelector('#worker-edit-profile').name, profiles: Array.from(document.querySelector('#worker-edit-profile').options).map(option => option.value).sort() })`);
  assert.equal(form.name, worker.name, 'Matched Worker route must remain authoritative');
  assert.equal(form.profile_name, worker.profile_name, 'Editing must preserve the stored profile');
  assert.equal(form.profile_field, 'worker[profile_name]');
  assert.deepEqual(form.profiles, [...catalog].sort());
  assert.match(await evaluate(`document.querySelector('#server-dashboard').textContent`), /unknown/i);
}

async function verifyStyle() {
  const style = await evaluate(`(() => {
    const header = document.querySelector('#yd-layout .navbar');
    const select = document.querySelector('select[name="worker[profile_name]"]');
    const card = document.querySelector('.card');
    if (!header || !select || !card) throw new Error('Missing shared DuskMoon UI structure');
    return { header: getComputedStyle(header).backgroundColor, padding: parseFloat(getComputedStyle(select).paddingLeft), radius: parseFloat(getComputedStyle(card).borderRadius), overflow: document.documentElement.scrollWidth > innerWidth + 1 };
  })()`);
  assert.ok(!['transparent', 'rgba(0, 0, 0, 0)'].includes(style.header), 'Bundled header styling must be active');
  assert.ok(style.padding > 0 && style.radius > 0, 'Shared DuskMoon controls/cards must be styled');
  assert.equal(style.overflow, false, 'Worker profile page overflows the viewport');
}

try {
  assert.deepEqual(await readdir(profileDirectory), [], 'Parent must supply a fresh isolated Chromium profile');
  chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profileDirectory}`, 'about:blank'], { stdio: 'ignore' });
  chromiumClosed = new Promise(resolve => chromium.once('close', resolve));
  chromium.once('error', error => errors.push(error.message));
  let port;
  await until(async () => {
    try { port = (await readFile(`${profileDirectory}/DevToolsActivePort`, 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(5000) })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params);
    if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') errors.push(message.params);
    if (message.method === 'Page.lifecycleEvent' && message.params.name === 'load') loadedPages.add(message.params.loaderId);
    if (['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(message.method)) {
      let frame;
      try { frame = JSON.parse(message.params.response.payloadData); } catch { frame = null; }
      if (Array.isArray(frame)) {
        const identity = JSON.stringify([message.params.requestId, frame[0], frame[1], frame[2]]);
        if (message.method === 'Network.webSocketFrameSent' && frame[3] === 'event') {
          const action = { event: frame[4]?.event };
          actions.push(action);
          actionRequests.set(identity, action);
        }
        if (message.method === 'Network.webSocketFrameReceived' && frame[3] === 'phx_reply' && actionRequests.has(identity)) actionRequests.get(identity).reply = frame[4];
      }
    }
    const request = pending.get(message.id);
    if (request) {
      clearTimeout(request.timeout);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    }
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('CDP websocket did not open')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timeout); reject(new Error('CDP websocket failed')); }, { once: true });
  });
  socket.addEventListener('close', () => { if (!closing) errors.push('CDP websocket closed unexpectedly'); });
  for (const domain of ['Runtime', 'Log', 'Page', 'Network']) await cdp(`${domain}.enable`);
  await cdp('Page.setLifecycleEventsEnabled', { enabled: true });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  const css = await fetch(`${base}/management.css`, { signal: AbortSignal.timeout(10000) });
  assert.equal(css.status, 200);
  assert.match(css.headers.get('content-type') || '', /text\/css/);
  assert.doesNotMatch(await css.text(), /@(import|theme|plugin|apply|utility)\b/);

  let evidence;
  let fixtureId = process.env.MANAGEMENT_WORKER_PROFILES_FIXTURE_ID;
  if (verifyOnly) {
    evidence = JSON.parse(await readFile(evidencePath, 'utf8'));
    if (fixtureId) assert.equal(fixtureId, evidence.fixture_id);
    fixtureId = evidence.fixture_id;
  } else if (!fixtureId) {
    const fixtures = (await api('/workers')).filter(worker => worker.id.startsWith('profile-fixture'));
    assert.equal(fixtures.length, 1, 'Provide exactly one profile-fixture Worker or an explicit fixture ID');
    fixtureId = fixtures[0].id;
  }
  assert.match(fixtureId, /^[A-Za-z0-9_.-]{1,64}$/);

  if (!verifyOnly) {
    const before = await fixtureSnapshot(fixtureId);
    assertFixture(before);
    const registeredId = `profile-browser-${randomUUID().slice(0, 8)}`;
    await verifyList([before.worker]);
    await verifyStyle();
    await submit('#worker-form', { 'worker[id]': registeredId, 'worker[name]': 'Profile Browser Worker', 'worker[profile_name]': 'dns_only' });
    await until(() => evaluate(`document.getElementById(${JSON.stringify(`server-selector-${registeredId}`)})?.dataset.profileName === 'dns_only' && document.querySelector('#worker-profile').value === 'custom'`), 'Registration did not persist dns_only and reset to custom');
    let registered = await api(`/workers/${registeredId}`);
    assert.equal(registered.profile_name, 'dns_only');
    assert.deepEqual(registered.expected_capabilities, ['dns']);
    assert.deepEqual(registered.services, []);
    assert.deepEqual(registered.assignments, []);
    assert.equal(registered.actual_state, 'unknown');
    const immutableRegistered = workerWithoutMetadata(registered);
    await verifyList([registered, before.worker]);
    await verifyEditor(registered);
    await submit('#worker-edit-form', { 'worker[name]': 'Profile Browser Worker Edited', 'worker[profile_name]': 'local_network' });
    const edited = await api(`/workers/${registeredId}`);
    assert.equal(edited.name, 'Profile Browser Worker Edited');
    assert.equal(edited.profile_name, 'local_network');
    assert.equal(edited.revision, registered.revision + 1);
    assert.deepEqual(workerWithoutMetadata(edited), immutableRegistered);
    registered = edited;
    await verifyList([registered]);
    await verifyEditor(registered);

    const concurrent = await api('/commands/update_worker', { id: registeredId, name: 'Concurrent Profile Worker', expected_revision: registered.revision });
    assert.equal(concurrent.profile_name, 'local_network', 'Omitted API profile must retain the stored profile');
    await submit('#worker-edit-form', { 'worker[name]': 'Stale Must Not Persist', 'worker[profile_name]': 'dhcp_only' });
    assert.deepEqual(await api(`/workers/${registeredId}`), { ...registered, ...concurrent }, 'Stale browser metadata overwrote the concurrent change');
    await until(() => evaluate(`!!document.querySelector('#flash-error') && /revision|stale|changed/i.test(document.querySelector('#flash-error').textContent)`), 'Stale revision rejection was not explained');
    await refreshWorker();
    registered = await api(`/workers/${registeredId}`);
    assert.equal(registered.name, 'Concurrent Profile Worker');
    assert.equal(registered.profile_name, 'local_network');
    await until(() => evaluate(`document.querySelector('#worker-edit-form').elements.namedItem('worker[name]').value === 'Concurrent Profile Worker' && document.querySelector('#worker-edit-profile').value === 'local_network'`), 'Refresh discarded or hid concurrent metadata');

    await submit('#worker-edit-form', { 'worker[name]': 'Invalid Must Not Persist', 'worker[profile_name]': 'unknown_profile' }, true);
    assert.deepEqual(await api(`/workers/${registeredId}`), registered, 'Unknown profile was silently normalized or persisted');
    await until(() => evaluate(`!!document.querySelector('#flash-error') && /profile|preset/i.test(document.querySelector('#flash-error').textContent)`), 'Unknown profile rejection was not explained');
    await refreshWorker();
    assert.equal(await evaluate(`document.querySelector('#worker-edit-profile').value`), 'local_network');
    assert.equal((await api(`/workers/${registeredId}/targets/latest`, undefined, 404)).code, 'not_found', 'Profile metadata must not prepare a target');

    await verifyEditor(before.worker, registeredId);
    await submit('#worker-edit-form', { 'worker[name]': before.worker.name, 'worker[profile_name]': 'dhcp_only' });
    const after = await fixtureSnapshot(fixtureId);
    assert.equal(after.worker.profile_name, 'dhcp_only');
    assert.equal(after.worker.name, before.worker.name);
    assert.equal(after.worker.revision, before.worker.revision + 1);
    assertFixtureUnchanged(before, after);
    assert.deepEqual(await api(`/workers/${registeredId}`), registered, 'Query spoof changed the other Worker');
    evidence = { fixture_id: fixtureId, registered_id: registeredId, catalog_profiles: catalog, fixture_before: before, fixture_after: after, registered_worker: registered };
  }

  const currentFixture = await fixtureSnapshot(fixtureId);
  const currentRegistered = await api(`/workers/${encodeURIComponent(evidence.registered_id)}`);
  assert.deepEqual(currentFixture, evidence.fixture_after, 'Fixture metadata, history or export changed across restart/read-only verification');
  assert.deepEqual(currentRegistered, evidence.registered_worker, 'Registered profile metadata changed across restart');
  assertFixtureUnchanged(evidence.fixture_before, currentFixture);
  const workers = [currentFixture.worker, currentRegistered];
  for (const viewport of [{ width: 1440, height: 1000, mobile: false }, { width: 390, height: 844, mobile: true }]) {
    await cdp('Emulation.setDeviceMetricsOverride', { ...viewport, deviceScaleFactor: 1 });
    await verifyList(workers);
    await verifyStyle();
    for (const worker of workers) {
      await verifyEditor(worker, worker.id === fixtureId ? currentRegistered.id : fixtureId);
      await refreshWorker();
      assert.equal(await evaluate(`document.querySelector('#worker-edit-profile').value`), worker.profile_name);
      await verifyStyle();
    }
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(`${evidencePath}.${viewport.width}.png`, Buffer.from(screenshot.data, 'base64'));
  }
  assert.deepEqual(await fixtureSnapshot(fixtureId), currentFixture, 'Read-only UI inspection modified fixture data');
  assert.deepEqual(await api(`/workers/${currentRegistered.id}`), currentRegistered, 'Read-only UI inspection modified registered metadata');
  assert.deepEqual(errors, []);
  await writeFile(evidencePath, JSON.stringify({ ...evidence, fixture_after: currentFixture, registered_worker: currentRegistered }));
  console.log(`PASS Chromium Worker profiles (${verifyOnly ? 'restart read-only' : 'registration/edit/CAS/invalid-profile'}): six presets, true persisted selection, metadata-only immutable target/export, route authority, mobile/style/noauth`);
} finally {
  closing = true;
  for (const request of pending.values()) { clearTimeout(request.timeout); request.reject(new Error('Browser closed')); }
  socket?.close();
  if (chromium?.pid && chromium.exitCode === null && chromium.signalCode === null) {
    chromium.kill('SIGTERM');
    const closed = await Promise.race([chromiumClosed.then(() => true), delay(3000).then(() => false)]);
    if (!closed) {
      chromium.kill('SIGKILL');
      assert.equal(await Promise.race([chromiumClosed.then(() => true), delay(3000).then(() => false)]), true, 'Chromium did not terminate; parent must clean its owned process group');
    }
  }
}
