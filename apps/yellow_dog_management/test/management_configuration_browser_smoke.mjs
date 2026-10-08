import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

for (const name of ['YELLOW_DOG_PHASE1_PG_DATA_DIR', 'MANAGEMENT_UI_URL', 'MANAGEMENT_CONFIGURATION_EVIDENCE', 'MANAGEMENT_CONFIGURATION_BROWSER_PROFILE', 'MANAGEMENT_CONFIGURATION_PHASE']) {
  assert.ok(process.env[name], `Missing disposable harness input: ${name}`);
}
await readFile(join(process.env.YELLOW_DOG_PHASE1_PG_DATA_DIR, 'PG_VERSION'));
const address = new URL(process.env.MANAGEMENT_UI_URL);
assert.equal(address.hostname, '127.0.0.1');
const base = address.origin;
const profile = process.env.MANAGEMENT_CONFIGURATION_BROWSER_PROFILE;
const evidencePath = process.env.MANAGEMENT_CONFIGURATION_EVIDENCE;
const phase = process.env.MANAGEMENT_CONFIGURATION_PHASE;
const p1Only = process.env.MANAGEMENT_CONFIGURATION_P1_ONLY === '1';
const digests = JSON.parse(process.env.MANAGEMENT_CONFIGURATION_DIGESTS);
const pending = new Map();
const actions = [];
const requests = new Map();
const errors = [];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let sequence = 0;
let socket;
let browser;
let closed;

async function until(check, message, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    assert.deepEqual(errors, [], 'Unexpected browser error');
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function api(path, body) {
  assert.ok(phase !== 'verify' || body === undefined, 'Restart verification cannot mutate through the API');
  const response = await fetch(`${base}/api${path}`, {
    ...(body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() }, body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return result.data;
}

async function navigate(path, selector) {
  await cdp('Page.navigate', { url: base + path });
  await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
}

async function action(event, expression) {
  const start = actions.length;
  await evaluate(expression);
  let received;
  await until(() => { received = actions.slice(start).find(item => item.event === event && item.reply); return !!received; }, `Missing LiveView acknowledgement: ${event}`);
  assert.equal(received.reply.status, 'ok');
}

const click = (selector, event) => action(event, `document.querySelector(${JSON.stringify(selector)}).click()`);

async function change(formSelector, fields, event = 'validate') {
  await action(event, `(() => {
    const form = document.querySelector(${JSON.stringify(formSelector)});
    const entries = Object.entries(${JSON.stringify(fields)});
    for (const [name, value] of entries) {
      const field = form.elements.namedItem(name);
      if (!field) throw new Error('Missing editor field: ' + name);
      field.value = value;
    }
    form.elements.namedItem(entries.at(-1)[0]).dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
}

async function submit(form, button, event) {
  await until(() => evaluate(`document.querySelector(${JSON.stringify(button)}).disabled === false`), `Submit remained disabled: ${button}`);
  await action(event, `document.querySelector(${JSON.stringify(form)}).requestSubmit(document.querySelector(${JSON.stringify(button)}))`);
}

const zonePath = id => `/management/zones/${id}/edit`;
const assignments = id => api(`/zones/${id}/assignments`);

function submissionCounts(operation = 'update_zone') {
  assert.ok(['update_zone', 'update_dns_view'].includes(operation));
  const result = execFileSync('psql', [process.env.YELLOW_DOG_MANAGEMENT_DATABASE_URL,
    '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c',
    `SELECT (SELECT count(*) FROM management_idempotency), (SELECT count(*) FROM management_audits WHERE operation = '${operation}')`], { encoding: 'utf8' });
  return result.trim().split('|').map(Number);
}

async function verifyAssignments(saved, workers) {
  const snapshot = await assignments(saved.zone_id);
  assert.deepEqual(snapshot.assignments.map(row => row.worker_id), workers);
  assert.ok(snapshot.assignments.every(row => row.resource_version_id === saved.version_id));
  await navigate(zonePath(saved.zone_id), '#zone-assignments-form');
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('#zone-assignments-form fieldset')).map(row => row.dataset.workerId)`), workers);
  for (const worker of saved.workers) {
    await navigate(`/server/${worker}/dashboard`, '#resource-assignments');
    if (!p1Only) {
      assert.equal(await evaluate(`document.querySelector('#target-export-scope').textContent.includes('DNS Views and IP database artifacts are not serialized')`), true);
    }
    const data = await api(`/workers/${worker}`);
    assert.equal(data.actual_state, 'unknown');
    assert.equal(data.status, 'not_yet_connected');
    assert.equal(data.assignments.length, workers.includes(worker) ? 1 : 0);
    assert.equal(await evaluate(`document.querySelector('#resource-assignments').textContent.includes(${JSON.stringify(saved.zone_id)})`), workers.includes(worker));
  }
}

async function verifyCatalog() {
  await navigate('/system/ip-database', '#ip-database-city');
  await click('#ip-database-refresh', 'refresh');
  for (const kind of ['city', 'country']) {
    assert.equal(await evaluate(`document.querySelector('#ip-database-${kind} div[data-digest]').dataset.digest`), digests[kind]);
    await until(() => evaluate(`document.querySelector('#ip-database-${kind} [data-status]').dataset.status === 'Available'`), `Selected ${kind} artifact did not finish verification`);
    assert.equal(await evaluate(`document.querySelector('#ip-database-${kind} [data-status]').dataset.status`), 'Available');
  }
  assert.equal(await evaluate(`document.querySelector('[id^="ip-database-reload"], [id^="ip-database-unload"]') === null`), true);
}

async function queue(kind, expectedState) {
  await navigate('/system/ip-database', '#ip-database-city');
  await click(`#ip-database-download-${kind}`, 'download');
  const id = Number(await evaluate(`document.querySelector('#ip-database-download-result').dataset.jobId`));
  assert.ok(Number.isInteger(id) && id > 0);
  await until(async () => {
    const job = (await api('/task-history')).find(job => job.id === id);
    if (!job || !expectedState.includes(job.state)) return false;
    if (job.state === 'completed') assert.equal(job.result.digest, digests[kind]);
    else assert.ok(job.errors.length > 0 && job.result === null);
    return true;
  }, `Job ${id} did not reach ${expectedState}`, 30000);
}

try {
  assert.deepEqual(await readdir(profile), [], 'Browser profile must be fresh');
  browser = spawn('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`], { detached: true, stdio: 'ignore' });
  closed = new Promise(resolve => browser.once('close', resolve));
  browser.once('error', error => errors.push(error.message));
  if (browser.pid) await writeFile(join(profile, 'browser.pid'), String(browser.pid));
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params);
    if (['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(message.method)) {
      let frame;
      try { frame = JSON.parse(message.params.response.payloadData); } catch { frame = null; }
      if (Array.isArray(frame)) {
        const key = JSON.stringify([message.params.requestId, frame[0], frame[1], frame[2]]);
        if (message.method === 'Network.webSocketFrameSent' && frame[3] === 'event') {
          const item = { event: frame[4].event };
          actions.push(item);
          requests.set(key, item);
        }
        if (message.method === 'Network.webSocketFrameReceived' && frame[3] === 'phx_reply' && requests.has(key)) requests.get(key).reply = frame[4];
      }
    }
    const request = pending.get(message.id);
    if (request) {
      clearTimeout(request.timeout);
      pending.delete(message.id);
      message.error ? request.reject(new Error(JSON.stringify(message.error))) : request.resolve(message.result);
    }
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('CDP websocket did not open')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
  });
  for (const domain of ['Runtime', 'Page', 'Network']) await cdp(`${domain}.enable`);
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  let saved;

  if (phase === 'create') {
    assert.deepEqual(await api('/workers'), []);
    await navigate('/management/zones/new', '#zone-form');
    await click('[phx-click="add_record"]', 'add_record');
    const fields = { 'zone[name]': 'configuration.example.test.' };
    const name = fields['zone[name]'];
    const records = [
      { name, type: 'SOA', ttl: 300, data: { mname: `ns.${name}`, rname: `hostmaster.${name}`, serial: 1, refresh: 3600, retry: 600, expire: 86400, minimum: 300 } },
      { name, type: 'NS', ttl: 300, data: { host: `ns.${name}` } },
      { name: `ns.${name}`, type: 'A', ttl: 300, data: { address: '192.0.2.10' } },
    ];
    records.forEach((record, index) => {
      for (const field of ['name', 'type', 'ttl']) fields[`zone[records][${index}][${field}]`] = String(record[field]);
      for (const [field, value] of Object.entries(record.data)) fields[`zone[records][${index}][data][${field}]`] = String(value);
    });
    await change('#zone-form', fields);
    await submit('#zone-form', '#zone-save', 'save');
    await until(async () => (await api('/zones')).length === 1, 'Zone draft did not persist');
    const zone = (await api('/zones'))[0];
    assert.equal(zone.name, name);
    assert.deepEqual(await api('/workers'), []);
    assert.equal(zone.records.length, 3);
    const workers = ['configuration-a', 'configuration-b'];
    const services = [];
    for (const [index, worker_id] of workers.entries()) {
      const worker = await api('/commands/create_worker', { id: worker_id, name: `Configuration Worker ${index + 1}` });
      services.push(await api('/commands/put_service', { worker_id, expected_revision: worker.revision, id: 'dns', type: 'dns', desired_state: 'stopped', config: { listen_address: '127.0.0.1', port: 15353 + index } }));
    }
    await navigate('/management/dns/views', '#dns-view-worker-selector');
    await change('#dns-view-worker-selector', { 'scope[worker_id]': workers[0] }, 'select_worker');
    await until(() => evaluate(`!!document.querySelector('#dns-view-form')`), 'Single DNS Service was not preselected');
    await change('#dns-view-form', { 'view[name]': 'configured', 'view[priority]': '7' });
    await submit('#dns-view-form', '#dns-view-save', 'save');
    const viewPath = `/workers/${workers[0]}/dns-services/${services[0].id}/views`;
    await until(async () => (await api(viewPath)).some(view => view.name === 'configured'), 'Scoped View did not persist');
    const viewsBeforeSwitch = await api(viewPath);
    const originalView = viewsBeforeSwitch.find(view => view.name === 'configured');
    const receiptCounts = () => execFileSync('psql', [process.env.YELLOW_DOG_MANAGEMENT_DATABASE_URL,
      '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c',
      "SELECT (SELECT count(*) FROM management_idempotency), (SELECT count(*) FROM management_audits WHERE operation = 'create_dns_view')"], { encoding: 'utf8' }).trim().split('|').map(Number);
    await click(`#dns-view-${originalView.id} [phx-click="delete"]`, 'delete');
    await click('#dns-view-confirm-delete', 'confirm_delete');
    assert.equal((await api(viewPath)).some(view => view.id === originalView.id), false);
    const beforeRecreation = receiptCounts();
    await change('#dns-view-form', { 'view[name]': 'configured', 'view[priority]': '7' });
    await submit('#dns-view-form', '#dns-view-save', 'save');
    const recreatedViews = await api(viewPath);
    const view = recreatedViews.find(view => view.name === 'configured');
    assert.ok(view, 'Identical creation after deletion must persist in the same mounted LiveView');
    assert.notEqual(view.id, originalView.id);
    assert.equal(recreatedViews.some(view => view.id === originalView.id), false);
    assert.deepEqual(receiptCounts(), beforeRecreation.map(count => count + 1));
    await click('#dns-view-refresh', 'refresh');
    assert.equal(await evaluate(`!!document.querySelector('#dns-view-${view.id}')`), true);
    await writeFile(join(dirname(evidencePath), 'view-recreation.json'), JSON.stringify({ original_id: originalView.id, recreated_id: view.id, before: beforeRecreation, after: receiptCounts() }, null, 2));
    const viewsAfterRecreation = await api(viewPath);
    await change('#dns-view-form', { 'view[name]': 'unsaved' });
    await change('#dns-view-worker-selector', { 'scope[worker_id]': workers[1] }, 'select_worker');
    assert.equal(await evaluate(`!!document.querySelector('#dns-view-unsaved-scope')`), true);
    await click('[phx-click="cancel_scope"]', 'cancel_scope');
    assert.equal(await evaluate(`document.querySelector('[name="view[name]"]').value`), 'unsaved');
    await change('#dns-view-worker-selector', { 'scope[worker_id]': workers[1] }, 'select_worker');
    await click('[phx-click="confirm_scope"]', 'confirm_scope');
    assert.deepEqual(await api(viewPath), viewsAfterRecreation);
    await navigate(zonePath(zone.id), '#zone-form');
    await click(`[phx-click="confirm_zone"][phx-value-id="${zone.id}"]`, 'confirm_zone');
    const version = (await api(`/zones/${zone.id}/versions`))[0];
    for (const worker of workers) await click(`[phx-click="add_assignment_worker"][phx-value-id="${worker}"]`, 'add_assignment_worker');
    await submit('#zone-assignments-form', '#zone-save-assignments', 'save_assignments');
    await until(async () => (await assignments(zone.id)).assignments.length === 2, 'Both assignments did not persist');
    const worker = await api(`/workers/${workers[0]}`);
    const target = await api('/commands/confirm_target', { worker_id: workers[0], expected_revision: worker.revision });
    assert.equal(target.status, 'prepared');
    assert.equal(target.actual_state, 'unknown');
    saved = { zone_id: zone.id, version_id: version.id, workers, service_ids: services.map(service => service.id), view_id: view.id, target_path: `/workers/${workers[0]}/targets/${target.revision}` };
    await verifyAssignments(saved, workers);
    await writeFile(evidencePath, JSON.stringify(saved, null, 2));
  } else {
    saved = JSON.parse(await readFile(evidencePath, 'utf8'));
    if (phase === 'verify') {
      await verifyAssignments(saved, saved.workers);
      await navigate(`/server/${saved.workers[0]}/dns/views/${saved.service_ids[0]}`, '#dns-views-table');
      assert.equal(await evaluate(`!!document.querySelector('#dns-view-${saved.view_id}')`), true);
      if (!p1Only) {
        await verifyCatalog();
        const limited = await fetch(`${base}/api${saved.target_path}/export?scope=dns_zones`);
        assert.equal(limited.headers.get('x-yellow-dog-export-scope'), 'dns_zones');
        const full = await fetch(`${base}/api${saved.target_path}/export?scope=full`);
        assert.equal(full.status, 422);
        assert.equal((await full.json()).error.code, 'unsupported_export');
      }
    } else if (phase === 'editor-failures') {
      const original = await api(`/zones/${saved.zone_id}`);
      await navigate(zonePath(saved.zone_id), '#zone-form');
      const addressName = await evaluate(`Array.from(document.querySelectorAll('#zone-form [name$="[address]"]')).map(input => input.name)[0]`);
      assert.ok(addressName);
      const before = submissionCounts();
      await change('#zone-form', { [addressName]: 'not-an-ip' });
      assert.equal(await evaluate(`document.querySelector('[name=${JSON.stringify(addressName)}]').value`), 'not-an-ip');
      assert.equal(await evaluate(`document.querySelector('#zone-save').disabled`), true);
      assert.deepEqual(await api(`/zones/${saved.zone_id}`), original);
      assert.deepEqual(submissionCounts(), before);
      await change('#zone-form', { [addressName]: '192.0.2.99' });
      await submit('#zone-form', '#zone-save', 'save');
      assert.equal(await evaluate(`document.querySelector('[name=${JSON.stringify(addressName)}]').value`), '192.0.2.99');
      assert.equal(await evaluate(`document.body.textContent.includes('Database constraint')`), true);
      assert.equal(await evaluate(`document.body.textContent.includes('Zone draft saved')`), false);
      assert.deepEqual(await api(`/zones/${saved.zone_id}`), original);
      const failed = submissionCounts();
      assert.deepEqual(failed, before.map(count => count + 1));
      await submit('#zone-form', '#zone-save', 'save');
      assert.deepEqual(submissionCounts(), failed);
      // A real user can submit an edit before the preceding change reply patches the form.
      await action('save', `(() => {
        const form = document.querySelector('#zone-form');
        const field = form.elements.namedItem(${JSON.stringify(addressName)});
        field.value = '192.0.2.100';
        field.dispatchEvent(new Event('change', { bubbles: true }));
        form.requestSubmit(document.querySelector('#zone-save'));
      })()`);
      assert.equal(await evaluate(`document.querySelector('[name=${JSON.stringify(addressName)}]').value`), '192.0.2.100');
      assert.equal(await evaluate(`document.body.textContent.includes('Zone draft saved')`), false);
      const edited = submissionCounts();
      assert.deepEqual(edited, failed.map(count => count + 1));
      assert.deepEqual(await api(`/zones/${saved.zone_id}`), original);
      const viewPath = `/workers/${saved.workers[0]}/dns-services/${saved.service_ids[0]}/views`;
      const originalViews = await api(viewPath);
      await navigate(`/server/${saved.workers[0]}/dns/views/${saved.service_ids[0]}`, '#dns-views-table');
      await click(`#dns-view-${saved.view_id} [phx-click="edit"]`, 'edit');
      const viewBefore = submissionCounts('update_dns_view');
      await change('#dns-view-form', { 'view[priority]': '8' });
      await submit('#dns-view-form', '#dns-view-save', 'save');
      assert.equal(await evaluate(`document.querySelector('#dns-view-error').textContent.includes('Database constraint')`), true);
      const viewFailed = submissionCounts('update_dns_view');
      assert.deepEqual(viewFailed, viewBefore.map(count => count + 1));
      assert.equal(await evaluate(`document.querySelector('[name="view[name]"]').disabled`), true);
      await action('save', `(() => {
        const form = document.querySelector('#dns-view-form');
        const field = form.elements.namedItem('view[priority]');
        field.value = '9';
        field.dispatchEvent(new Event('change', { bubbles: true }));
        form.requestSubmit(document.querySelector('#dns-view-save'));
      })()`);
      const viewEdited = submissionCounts('update_dns_view');
      assert.deepEqual(viewEdited, viewFailed.map(count => count + 1));
      assert.equal(await evaluate(`document.querySelector('[name="view[priority]"]').value`), '9');
      assert.deepEqual(await api(viewPath), originalViews);
      await writeFile(join(dirname(evidencePath), 'editor-failures.json'), JSON.stringify({ before, failed, retry: failed, edited, unchanged_zone: original, view_before: viewBefore, view_failed: viewFailed, view_edited: viewEdited, unchanged_views: originalViews }, null, 2));
    } else if (phase === 'advance') {
      const before = await assignments(saved.zone_id);
      await navigate(zonePath(saved.zone_id), '#zone-form');
      const addressName = await evaluate(`Array.from(document.querySelectorAll('#zone-form [name$="[address]"]')).map(input => input.name)[0]`);
      assert.ok(addressName);
      await change('#zone-form', { [addressName]: '192.0.2.20' });
      await submit('#zone-form', '#zone-save', 'save');
      await until(async () => (await api(`/zones/${saved.zone_id}`)).revision === 2, 'Edited draft did not persist');
      await click(`[phx-click="confirm_zone"][phx-value-id="${saved.zone_id}"]`, 'confirm_zone');
      await until(async () => (await api(`/zones/${saved.zone_id}/versions`)).length === 2, 'Second immutable version did not persist');
      assert.deepEqual((await assignments(saved.zone_id)).assignments, before.assignments);
      const workerSelector = `#zone-assignments-form fieldset[data-worker-id="${saved.workers[0]}"]`;
      await click(`${workerSelector} [phx-click="remove_assignment_row"]`, 'remove_assignment_row');
      await submit('#zone-assignments-form', '#zone-save-assignments', 'save_assignments');
      await until(async () => (await assignments(saved.zone_id)).assignments.length === 1, 'Removal did not persist');
      await verifyAssignments(saved, [saved.workers[1]]);
    } else if (phase === 'sync') {
      for (const kind of ['city', 'country']) await queue(kind, ['completed']);
      await verifyCatalog();
    } else if (phase === 'failed-sync') {
      await verifyCatalog();
      await queue('city', ['retryable', 'discarded']);
      await verifyCatalog();
    } else throw new Error(`Unknown browser phase: ${phase}`);
  }
  const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(dirname(evidencePath), `${phase}.png`), Buffer.from(screenshot.data, 'base64'));
  assert.deepEqual(errors, []);
  console.log(`PASS Management configuration browser ${phase}: acknowledged LiveView events and fresh backend reads`);
} finally {
  socket?.close();
  for (const item of pending.values()) clearTimeout(item.timeout);
  if (browser?.pid) {
    try { process.kill(-browser.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await Promise.race([closed, delay(3000)]);
    if (browser.exitCode === null) {
      try { process.kill(-browser.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      await closed;
    }
  }
}
