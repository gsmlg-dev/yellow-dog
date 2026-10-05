import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join } from 'node:path';

for (const variable of ['YELLOW_DOG_PHASE1_PG_DATA_DIR', 'MANAGEMENT_UI_URL', 'MANAGEMENT_DNS_VIEWS_SERVICE_ID', 'MANAGEMENT_DNS_VIEWS_SECOND_SERVICE_ID', 'MANAGEMENT_DNS_VIEWS_OTHER_SERVICE_ID', 'MANAGEMENT_DNS_VIEWS_EVIDENCE', 'MANAGEMENT_DNS_VIEWS_BROWSER_PROFILE']) {
  assert.ok(process.env[variable], `Required disposable harness input: ${variable}`);
}
await readFile(join(process.env.YELLOW_DOG_PHASE1_PG_DATA_DIR, 'PG_VERSION'), 'utf8');
const address = new URL(process.env.MANAGEMENT_UI_URL);
assert.equal(address.hostname, '127.0.0.1', 'Only the disposable loopback release may be tested');
assert.equal(address.username + address.password, '', 'No URL credentials');
const base = address.origin;
const serviceId = process.env.MANAGEMENT_DNS_VIEWS_SERVICE_ID;
const secondId = process.env.MANAGEMENT_DNS_VIEWS_SECOND_SERVICE_ID;
const otherId = process.env.MANAGEMENT_DNS_VIEWS_OTHER_SERVICE_ID;
const evidencePath = process.env.MANAGEMENT_DNS_VIEWS_EVIDENCE;
const profile = process.env.MANAGEMENT_DNS_VIEWS_BROWSER_PROFILE;
assert.ok(isAbsolute(profile), 'Parent must provide an absolute fresh browser profile directory');
const verifyOnly = process.env.MANAGEMENT_DNS_VIEWS_VERIFY_ONLY === '1';
const downloadDirectory = join(dirname(evidencePath), 'view-downloads');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const pending = new Map();
const loadedPages = new Set();
const actions = [];
const actionRequests = new Map();
const errors = [];
let sequence = 0;
let socket;
let browser;
let browserClosed;

async function until(check, message) {
  const deadline = Date.now() + 15000;
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

async function api(path, body, expected = 200) {
  assert.ok(!verifyOnly || body === undefined, 'Verify-only mode cannot send API mutations');
  const response = await fetch(`${base}/api${path}`, {
    ...(body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() }, body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  assert.equal(response.headers.get('www-authenticate'), null);
  const result = await response.json();
  assert.equal(response.status, expected, JSON.stringify(result));
  return expected === 200 ? result.data : result.error;
}

const viewsApi = (worker, service, id) => `/workers/${worker}/dns-services/${service}/views${id ? `/${id}` : ''}`;
const pagePath = (worker, service) => `/server/${worker}/dns/views${service ? `/${service}` : ''}`;

async function navigate(path, selector) {
  const expected = new URL(path, base);
  const navigation = await cdp('Page.navigate', { url: expected.href });
  assert.ok(!navigation.errorText, navigation.errorText);
  if (navigation.loaderId) await until(() => loadedPages.has(navigation.loaderId), `Page load failed: ${path}`);
  await until(() => evaluate(`location.pathname === ${JSON.stringify(expected.pathname)} && location.search === ${JSON.stringify(expected.search)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true, 'Fresh browser must work without login');
}

async function acknowledged(event, operation) {
  assert.ok(!verifyOnly || event === 'refresh', `Verify-only browser event is not read-only refresh: ${event}`);
  const start = actions.length;
  await operation();
  let action;
  await until(() => { action = actions.slice(start).find(item => item.event === event && item.reply); return !!action; }, `No LiveView acknowledgement: ${event}`);
  assert.equal(action.reply.status, 'ok');
}

async function click(selector, event) {
  await acknowledged(event, () => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`));
}

async function changeFields(fields) {
  await acknowledged('validate', () => evaluate(`(() => {
    const form = document.querySelector('#dns-view-form');
    for (const [key, value] of Object.entries(${JSON.stringify(fields)})) {
      const field = form.elements.namedItem(key);
      if (!field) throw new Error('Missing View field: ' + key);
      field.value = value;
    }
    form.elements.namedItem('view[fallback_forwarders]').dispatchEvent(new Event('change', { bubbles: true }));
  })()`));
}

async function saveEditor() {
  await until(() => evaluate(`document.querySelector('#dns-view-save').disabled === false`), 'Valid View editor remained disabled');
  await acknowledged('save', () => evaluate(`document.querySelector('#dns-view-form').requestSubmit(document.querySelector('#dns-view-save'))`));
}

async function selectorCheck(worker, services) {
  await navigate(pagePath(worker) + `?service_id=${serviceId}`, '#dns-view-service-selector');
  assert.equal(await evaluate(`document.querySelector('#dns-view-form') === null`), services.length !== 1, 'Only a single eligible Service preselects');
  const ids = await evaluate(`Array.from(document.querySelectorAll('#dns-view-service-selector [data-service-id]')).map(link => link.dataset.serviceId).sort()`);
  assert.deepEqual(ids, [...services].sort());
}

async function verifyRows(worker, service, expected) {
  await navigate(pagePath(worker, service), '#dns-view-form');
  await click('#dns-view-refresh', 'refresh');
  assert.deepEqual(await api(viewsApi(worker, service)), expected);
  const rows = await evaluate(`Array.from(document.querySelectorAll('#dns-views-table tbody tr')).map(row => ({ id: row.id.slice('dns-view-'.length), name: row.dataset.viewName, revision: Number(row.dataset.viewRevision), enabled: row.dataset.viewEnabled === 'true', priority: row.dataset.viewPriority, rules: JSON.parse(row.dataset.viewRules) }))`);
  assert.deepEqual(rows, expected.map(view => ({ id: view.id, name: view.name, revision: view.revision, enabled: view.enabled, priority: view.is_default ? 'infinity' : String(view.priority), rules: view.client_rules })));
  assert.match(await evaluate(`document.querySelector('main').textContent`), /Desired configuration only.*do not execute DNS/s);
  assert.equal(rows.at(-1).name, 'default');
  for (const view of expected) {
    const defaultDelete = await evaluate(`!!document.querySelector(${JSON.stringify(`#dns-view-${view.id} [phx-click="delete"]`)})`);
    assert.equal(defaultDelete, !view.is_default);
    const rowText = await evaluate(`document.getElementById(${JSON.stringify(`dns-view-${view.id}`)}).textContent`);
    for (const rule of view.client_rules) {
      assert.ok(rowText.includes(rule.action) && rowText.includes(rule.kind));
      for (const value of rule.networks || rule.countries || []) assert.ok(rowText.includes(value));
    }
  }
}

function signalBrowser(signal) {
  if (!browser?.pid) return;
  try { process.kill(-browser.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}

try {
  assert.deepEqual(await readdir(profile), [], 'Browser profile must be fresh');
  browser = spawn('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`], { stdio: 'ignore', detached: true });
  browserClosed = new Promise(resolve => browser.once('close', resolve));
  browser.once('error', error => errors.push(error.message));
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium failed to start');
  const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(10000) });
  assert.ok(response.ok);
  const page = await response.json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const result = JSON.parse(event.data);
    if (result.method === 'Runtime.exceptionThrown') errors.push(result.params);
    if (result.method === 'Runtime.consoleAPICalled' && result.params.type === 'error') errors.push(result.params);
    if (result.method === 'Page.lifecycleEvent' && result.params.name === 'load') loadedPages.add(result.params.loaderId);
    if (['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(result.method)) {
      let frame;
      try { frame = JSON.parse(result.params.response.payloadData); } catch { frame = null; }
      if (Array.isArray(frame)) {
        const identity = JSON.stringify([result.params.requestId, frame[0], frame[1], frame[2]]);
        if (result.method === 'Network.webSocketFrameSent' && frame[3] === 'event') {
          const action = { event: frame[4]?.event };
          actions.push(action);
          actionRequests.set(identity, action);
        }
        if (result.method === 'Network.webSocketFrameReceived' && frame[3] === 'phx_reply' && actionRequests.has(identity)) actionRequests.get(identity).reply = frame[4];
      }
    }
    const request = pending.get(result.id);
    if (request) {
      clearTimeout(request.timeout);
      pending.delete(result.id);
      if (result.error) request.reject(new Error(JSON.stringify(result.error)));
      else request.resolve(result.result);
    }
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('CDP websocket failed')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timeout); reject(new Error('CDP connection failed')); }, { once: true });
  });
  for (const domain of ['Runtime', 'Page', 'Network']) await cdp(`${domain}.enable`);
  await cdp('Page.setLifecycleEventsEnabled', { enabled: true });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await selectorCheck('view-fixture', [serviceId, secondId]);
  await selectorCheck('view-other', [otherId]);
  let evidence;
  if (!verifyOnly) {
    const secondaryBefore = await api(viewsApi('view-fixture', secondId));
    const otherBefore = await api(viewsApi('view-other', otherId));
    for (const views of [await api(viewsApi('view-fixture', serviceId)), secondaryBefore, otherBefore]) {
      assert.equal(views.length, 1);
      assert.equal(views[0].name, 'default');
      assert.equal(views[0].is_default, true);
      assert.equal(views[0].priority, null);
      assert.deepEqual(views[0].client_rules, [{ action: 'allow', kind: 'any' }]);
    }
    await navigate(pagePath('view-fixture', serviceId) + `?server_id=view-other&service_id=${otherId}`, '#dns-view-form');
    assert.equal(await evaluate(`document.querySelector('#dns-view-form button[type=submit]').id`), 'dns-view-save', 'Save must be the default submitter');
    await changeFields({
      'view[name]': 'office', 'view[priority]': '7', 'view[recursion_enabled]': 'false', 'view[ecs_enabled]': 'true',
      'view[client_rules]': 'deny networks 192.0.2.99/24, 2001:db8::123/64\nallow countries US, CA, US\ndeny any',
      'view[fallback_forwarders]': '192.0.2.53\n198.51.100.53:5353\n2001:db8::53\n[2001:db8::54]:5354',
      'view[fallback_timeout]': '3000', 'view[fallback_retries]': '2',
    });
    await saveEditor();
    await until(() => evaluate(`document.querySelector('#dns-view-form').elements.namedItem('view[name]').value === ''`), 'Create did not reset editor');
    const created = (await api(viewsApi('view-fixture', serviceId))).find(view => view.name === 'office');
    assert.ok(created);
    assert.equal(created.worker_id, 'view-fixture');
    assert.equal(created.service_id, serviceId);
    assert.equal(created.priority, 7);
    assert.equal(created.recursion_enabled, false);
    assert.equal(created.ecs_enabled, true);
    assert.equal(created.fallback_timeout, 3000);
    assert.equal(created.fallback_retries, 2);
    assert.deepEqual(created.client_rules, [
      { action: 'deny', kind: 'networks', networks: ['192.0.2.0/24', '2001:db8::/64'] },
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] }, { action: 'deny', kind: 'any' },
    ]);
    assert.deepEqual(created.fallback_forwarders, [
      { address: '192.0.2.53', port: 53 }, { address: '198.51.100.53', port: 5353 },
      { address: '2001:db8::53', port: 53 }, { address: '2001:db8::54', port: 5354 },
    ]);
    await click(`#dns-view-${created.id} [phx-click="edit"]`, 'edit');
    assert.equal(await evaluate(`document.querySelector('#dns-view-form').elements.namedItem('view[name]').disabled`), true);
    assert.equal(await evaluate(`document.querySelector('#dns-view-forwarders').value`), '192.0.2.53\n198.51.100.53:5353\n2001:db8::53\n[2001:db8::54]:5354');
    await changeFields({ 'view[client_rules]': 'allow countries CA, US\ndeny networks ::1\ndeny any', 'view[priority]': '3', 'view[enabled]': 'false' });
    await saveEditor();
    const edited = await api(viewsApi('view-fixture', serviceId, created.id));
    assert.equal(edited.name, 'office');
    assert.equal(edited.priority, 3);
    assert.equal(edited.enabled, false);
    assert.equal(edited.revision, created.revision + 1);
    assert.deepEqual(edited.fallback_forwarders, created.fallback_forwarders);
    assert.deepEqual(edited.client_rules, [
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] },
      { action: 'deny', kind: 'networks', networks: ['::1/128'] }, { action: 'deny', kind: 'any' },
    ]);
    await click(`#dns-view-${created.id} [phx-click="edit"]`, 'edit');
    const concurrent = await api('/commands/update_dns_view', { worker_id: 'view-fixture', service_id: serviceId, id: edited.id, expected_revision: edited.revision, fallback_timeout: 4000 });
    await changeFields({ 'view[priority]': '99' });
    await saveEditor();
    await until(() => evaluate(`!!document.querySelector('#dns-view-error')?.textContent.match(/revision|stale|changed/i)`), 'Stale conflict not shown');
    assert.deepEqual(await api(viewsApi('view-fixture', serviceId, edited.id)), concurrent);
    await click('#dns-view-refresh', 'refresh');
    await changeFields({ 'view[name]': 'invalid', 'view[client_rules]': 'allow networks bad-cidr' });
    assert.equal(await evaluate(`!!document.querySelector('#dns-view-client_rules-error')`), true);
    assert.equal(await evaluate(`document.querySelector('#dns-view-save').disabled`), true);
    assert.deepEqual(await api(viewsApi('view-fixture', serviceId, edited.id)), concurrent);
    await evaluate(`document.querySelector('#dns-view-rules').focus()`);
    await click('#dns-view-cancel', 'cancel');
    assert.equal(await evaluate(`document.querySelector('#dns-view-rules').value`), 'allow any', 'Cancel must replace focused dirty rules with authoritative defaults');
    assert.equal(await evaluate(`document.querySelector('#dns-view-forwarders').value`), '');
    await evaluate(`document.querySelector('#dns-view-rules').blur()`);

    const defaultView = (await api(viewsApi('view-fixture', serviceId))).find(view => view.is_default);
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`#dns-view-${defaultView.id} [phx-click="delete"]`)}) === null`), true);
    await click(`#dns-view-${defaultView.id} [phx-click="edit"]`, 'edit');
    assert.equal(await evaluate(`document.querySelector('#dns-view-rules').readOnly`), true);
    assert.equal(await evaluate(`document.querySelector('[name="view[priority]"], #dns-view-apply-preset') === null`), true);
    await changeFields({ 'view[ecs_enabled]': 'true', 'view[fallback_forwarders]': '[::1]:5353' });
    await saveEditor();
    const defaultEdited = await api(viewsApi('view-fixture', serviceId, defaultView.id));
    assert.equal(defaultEdited.priority, null);
    assert.deepEqual(defaultEdited.client_rules, [{ action: 'allow', kind: 'any' }]);
    assert.equal(defaultEdited.ecs_enabled, true);
    assert.deepEqual(defaultEdited.fallback_forwarders, [{ address: '::1', port: 5353 }]);
    await click(`#dns-view-${defaultView.id} [phx-click="toggle_enabled"]`, 'toggle_enabled');
    const defaultToggled = await api(viewsApi('view-fixture', serviceId, defaultView.id));
    assert.equal(defaultToggled.enabled, false);
    assert.deepEqual(defaultToggled.client_rules, defaultEdited.client_rules);
    assert.deepEqual(defaultToggled.fallback_forwarders, defaultEdited.fallback_forwarders);

    await changeFields({ 'view[name]': 'geo-picker', 'view[client_rules]': 'deny networks ::1', 'view[fallback_forwarders]': '[2001:db8::1]:5353' });
    await click('#dns-view-country-US', 'toggle_country');
    await changeFields({ country_search: 'Canada' });
    assert.equal(await evaluate(`!!document.querySelector('[data-selected-country-code="US"]')`), true);
    assert.equal(await evaluate(`document.querySelector('#dns-view-country-US') === null`), true);
    await click('#dns-view-country-CA', 'toggle_country');
    await click('[phx-click="clear_country_search"]', 'clear_country_search');
    assert.equal(await evaluate(`document.querySelector('#dns-view-country-US').checked && document.querySelector('#dns-view-country-CA').checked`), true);
    await click('[data-selected-country-code="US"]', 'toggle_country');
    await click('#dns-view-country-US', 'toggle_country');
    await changeFields({ country_action: 'allow' });
    await evaluate(`document.querySelector('#dns-view-rules').value = ${JSON.stringify('deny networks ::1\nallow networks 192.0.2.7')}`);
    await click('#dns-view-add-countries', 'save');
    assert.equal(await evaluate(`document.querySelector('#dns-view-rules').value`), 'deny networks ::1\nallow networks 192.0.2.7\nallow countries CA, US', 'Append lost unsent typed text');
    await saveEditor();
    const geo = (await api(viewsApi('view-fixture', serviceId))).find(view => view.name === 'geo-picker');
    assert.deepEqual(geo.client_rules, [
      { action: 'deny', kind: 'networks', networks: ['::1/128'] },
      { action: 'allow', kind: 'networks', networks: ['192.0.2.7/32'] },
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] },
    ]);
    await changeFields({ 'view[name]': 'localhost-preset', 'view[client_rules]': '', preset: 'localhost' });
    await click('#dns-view-apply-preset', 'save');
    assert.equal(await evaluate(`document.querySelector('#dns-view-rules').value`), 'allow networks 127.0.0.1/32, ::1/128');
    await changeFields({ preset: 'any' });
    await click('#dns-view-apply-preset', 'save');
    assert.match(await evaluate(`document.querySelector('#dns-view-error').textContent`), /empty|retained/i);
    assert.equal(await evaluate(`document.querySelector('#dns-view-rules').value`), 'allow networks 127.0.0.1/32, ::1/128');
    await saveEditor();
    const preset = (await api(viewsApi('view-fixture', serviceId))).find(view => view.name === 'localhost-preset');
    assert.deepEqual(preset.client_rules, [{ action: 'allow', kind: 'networks', networks: ['127.0.0.1/32', '::1/128'] }]);
    await changeFields({ 'view[name]': 'temporary', 'view[client_rules]': 'deny networks' });
    await saveEditor();
    const temporary = (await api(viewsApi('view-fixture', serviceId))).find(view => view.name === 'temporary');
    assert.deepEqual(temporary.client_rules, [{ action: 'deny', kind: 'networks', networks: [] }]);
    await click(`#dns-view-${temporary.id} [phx-click="delete"]`, 'delete');
    assert.equal(await evaluate(`!!document.querySelector('#dns-view-delete-modal[role=dialog]')`), true);
    await click('#dns-view-cancel-delete', 'cancel_delete');
    assert.deepEqual(await api(viewsApi('view-fixture', serviceId, temporary.id)), temporary);
    await click(`#dns-view-${temporary.id} [phx-click="delete"]`, 'delete');
    await click('#dns-view-confirm-delete', 'confirm_delete');
    assert.equal((await api(viewsApi('view-fixture', serviceId, temporary.id), undefined, 404)).code, 'not_found');

    await acknowledged('filter', () => evaluate(`(() => {
      const form = document.querySelector('#dns-view-filter-form');
      form.elements.namedItem('filter').value = 'OFFICE';
      form.elements.namedItem('status').value = 'disabled';
      form.requestSubmit();
    })()`));
    assert.equal(await evaluate(`document.querySelectorAll('#dns-views-table tbody tr').length`), 1);
    assert.match(await evaluate(`document.querySelector('#dns-view-count').textContent`), /Showing 1 of 4/);
    const beforeExport = await api(viewsApi('view-fixture', serviceId));
    await mkdir(downloadDirectory, { recursive: true });
    await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloadDirectory });
    await click('#dns-view-export', 'export_csv');
    const csvName = `dns_views_view-fixture_${serviceId}.csv`;
    await until(async () => (await readdir(downloadDirectory)).includes(csvName), 'Filtered CSV download missing');
    assert.equal(await readFile(join(downloadDirectory, csvName), 'utf8'), 'View Name,Status,Priority,Recursion,ECS\r\noffice,Disabled,3,Disabled,Enabled\r\n');
    assert.deepEqual(await api(viewsApi('view-fixture', serviceId)), beforeExport);
    assert.deepEqual(await api(viewsApi('view-fixture', secondId)), secondaryBefore);
    assert.deepEqual(await api(viewsApi('view-other', otherId)), otherBefore);
    assert.equal((await api(viewsApi('view-other', otherId, created.id), undefined, 404)).code, 'not_found');
    evidence = { main: await api(viewsApi('view-fixture', serviceId)), secondary: secondaryBefore, other: otherBefore };
    await writeFile(evidencePath, JSON.stringify(evidence));
  } else evidence = JSON.parse(await readFile(evidencePath, 'utf8'));

  for (const viewport of [{ width: 1440, height: 1000, mobile: false }, { width: 390, height: 844, mobile: true }]) {
    await cdp('Emulation.setDeviceMetricsOverride', { ...viewport, deviceScaleFactor: 1 });
    await verifyRows('view-fixture', secondId, evidence.secondary);
    await verifyRows('view-other', otherId, evidence.other);
    await verifyRows('view-fixture', serviceId, evidence.main);
    const style = await evaluate(`({ overflow: document.documentElement.scrollWidth > innerWidth + 1, padding: parseFloat(getComputedStyle(document.querySelector('#dns-view-form input')).paddingLeft) })`);
    assert.equal(style.overflow, false, `Horizontal overflow at ${viewport.width}px`);
    assert.ok(style.padding > 0, 'Bundled DuskMoon input styling missing');
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(`${evidencePath}.${verifyOnly ? 'restart' : 'initial'}.${viewport.width}.png`, Buffer.from(screenshot.data, 'base64'));
  }
  assert.deepEqual(errors, []);
  console.log(`PASS Chromium DNS Views ${verifyOnly ? 'read-only restart replay' : 'rich CRUD/CAS, default protection, ordered rules/IPv6 forwarders, countries/presets, filtered CSV'}: explicit Service scope, noauth, desktop/mobile`);
} finally {
  socket?.close();
  for (const request of pending.values()) clearTimeout(request.timeout);
  pending.clear();
  if (browser?.pid) {
    signalBrowser('SIGTERM');
    if (browser.exitCode === null && browser.signalCode === null) {
      if (!(await Promise.race([browserClosed.then(() => true), delay(3000).then(() => false)]))) signalBrowser('SIGKILL');
      assert.equal(await Promise.race([browserClosed.then(() => true), delay(3000).then(() => false)]), true, 'Chromium did not terminate');
    }
    signalBrowser('SIGKILL');
  }
}
