import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

for (const variable of ['YELLOW_DOG_PHASE1_PG_DATA_DIR', 'MANAGEMENT_UI_URL', 'MANAGEMENT_DNS_ACLS_EVIDENCE', 'MANAGEMENT_DNS_ACLS_BROWSER_PROFILE', 'MANAGEMENT_DNS_ACLS_SERVICE_ID', 'MANAGEMENT_DNS_ACLS_SECOND_SERVICE_ID', 'MANAGEMENT_DNS_ACLS_OTHER_SERVICE_ID']) assert.ok(process.env[variable], variable);
const address = new URL(process.env.MANAGEMENT_UI_URL);
assert.equal(address.hostname, '127.0.0.1');
const base = address.origin;
const serviceId = process.env.MANAGEMENT_DNS_ACLS_SERVICE_ID;
const secondId = process.env.MANAGEMENT_DNS_ACLS_SECOND_SERVICE_ID;
const otherId = process.env.MANAGEMENT_DNS_ACLS_OTHER_SERVICE_ID;
const evidencePath = process.env.MANAGEMENT_DNS_ACLS_EVIDENCE;
const downloadDirectory = join(dirname(evidencePath), 'downloads');
const profile = process.env.MANAGEMENT_DNS_ACLS_BROWSER_PROFILE;
const verifyOnly = process.env.MANAGEMENT_DNS_ACLS_VERIFY_ONLY === '1';
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
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(method)); }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function api(path, body, status = 200) {
  const response = await fetch(`${base}/api${path}`, {
    ...(body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() }, body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  const result = await response.json();
  assert.equal(response.status, status, JSON.stringify(result));
  return status === 200 ? result.data : result.error;
}

const aclApi = (worker, service, id) => `/workers/${worker}/dns-services/${service}/acls${id ? `/${id}` : ''}`;
const pagePath = (worker, service) => `/server/${worker}/dns/acl${service ? `/${service}` : ''}`;

async function navigate(path, selector) {
  const expected = new URL(path, base);
  const navigation = await cdp('Page.navigate', { url: expected.href });
  assert.ok(!navigation.errorText, navigation.errorText);
  if (navigation.loaderId) await until(() => loadedPages.has(navigation.loaderId), `Page load failed: ${path}`);
  await until(() => evaluate(`location.pathname === ${JSON.stringify(expected.pathname)} && location.search === ${JSON.stringify(expected.search)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true);
}

async function acknowledged(event, operation) {
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
    const form = document.querySelector('#dns-acl-form');
    for (const [key, value] of Object.entries(${JSON.stringify(fields)})) {
      const field = form.elements.namedItem(key);
      if (!field) throw new Error('Missing ACL field: ' + key);
      field.value = value;
    }
    form.elements.namedItem('acl[rules]').dispatchEvent(new Event('change', { bubbles: true }));
  })()`));
}

async function saveEditor() {
  await until(() => evaluate(`document.querySelector('#dns-acl-form button.btn-primary').disabled === false`), 'Valid ACL editor remained disabled');
  await acknowledged('save', () => evaluate(`(() => {
    const form = document.querySelector('#dns-acl-form');
    form.requestSubmit(form.querySelector('button.btn-primary'));
  })()`));
}

async function submit(name, rules, description = '', save = true) {
  await changeFields({ 'acl[name]': name, 'acl[description]': description, 'acl[rules]': rules });
  if (save) await saveEditor();
}

async function verifyRows(worker, service, expected) {
  await navigate(pagePath(worker, service), '#dns-acl-form');
  await click('#dns-acl-refresh', 'refresh');
  assert.deepEqual(await api(aclApi(worker, service)), expected);
  for (const acl of expected) {
    const row = await evaluate(`document.getElementById(${JSON.stringify(`dns-acl-${acl.id}`)})?.textContent`);
    assert.ok(row?.includes(acl.name) && row.includes(acl.description), JSON.stringify(acl));
    for (const rule of acl.rules) {
      assert.ok(row.includes(rule.action) && row.includes(rule.kind));
      for (const value of rule.networks || rule.countries || []) assert.ok(row.includes(value));
    }
  }
  assert.match(await evaluate(`document.querySelector('main').textContent`), /not enforced|not applied|not exported/i);
}

try {
  assert.deepEqual(await readdir(profile), []);
  browser = spawn('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`], { stdio: 'ignore' });
  browserClosed = new Promise(resolve => browser.once('close', resolve));
  browser.once('error', error => errors.push(error.message));
  let port;
  await until(async () => {
    try { port = (await readFile(`${profile}/DevToolsActivePort`, 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium failed to start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
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
  await mkdir(downloadDirectory, { recursive: true });
  await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloadDirectory });
  await cdp('Page.setLifecycleEventsEnabled', { enabled: true });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  let evidence;
  if (!verifyOnly) {
    for (const [worker, services] of [['acl-fixture', [serviceId, secondId]], ['acl-other', [otherId]]]) {
      await navigate(pagePath(worker), '#dns-acl-service-selector');
      assert.equal(await evaluate(`document.querySelector('#dns-acl-form') === null`), true, 'Selector must not infer any default DNS Service');
      const ids = await evaluate(`Array.from(document.querySelectorAll('#dns-acl-service-selector [data-service-id]')).map(link => link.dataset.serviceId).sort()`);
      assert.deepEqual(ids, [...services].sort());
    }
    await navigate(pagePath('acl-fixture', serviceId) + `?server_id=acl-other&service_id=${otherId}`, '#dns-acl-form');
    const before = await api(aclApi('acl-fixture', serviceId));
    await submit('office', 'deny networks 192.0.2.25/24, 2001:db8::abc/64\nallow countries US, CA, US\ndeny any', 'Office "policy", 规则');
    await until(() => evaluate(`document.querySelector('#dns-acl-form').elements.namedItem('acl[name]').value === ''`), 'Create editor did not reset');
    const created = (await api(aclApi('acl-fixture', serviceId))).find(acl => acl.name === 'office');
    assert.ok(created);
    assert.equal(created.description, 'Office "policy", 规则');
    assert.deepEqual(created.rules, [
      { action: 'deny', kind: 'networks', networks: ['192.0.2.0/24', '2001:db8::/64'] },
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] },
      { action: 'deny', kind: 'any' },
    ]);
    assert.equal(created.worker_id, 'acl-fixture');
    assert.equal(created.service_id, serviceId);
    await click(`#dns-acl-${created.id} [phx-click="edit"]`, 'edit');
    await submit('office-renamed', 'allow countries US, CA\ndeny networks 198.51.100.25/24\ndeny any', 'Updated order');
    const renamed = await api(aclApi('acl-fixture', serviceId, created.id));
    assert.equal(renamed.name, 'office-renamed');
    assert.equal(renamed.description, 'Updated order');
    assert.equal(renamed.revision, created.revision + 1);
    assert.deepEqual(renamed.rules, [
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] },
      { action: 'deny', kind: 'networks', networks: ['198.51.100.0/24'] },
      { action: 'deny', kind: 'any' },
    ]);
    await click(`#dns-acl-${created.id} [phx-click="edit"]`, 'edit');
    const concurrent = await api('/commands/update_dns_acl', { worker_id: 'acl-fixture', service_id: serviceId, id: created.id, expected_revision: renamed.revision, name: 'office-concurrent', description: renamed.description, rules: [...renamed.rules].reverse() });
    await submit('stale-must-not-save', 'deny networks 192.0.2.0/24');
    assert.deepEqual(await api(aclApi('acl-fixture', serviceId, created.id)), concurrent);
    await until(() => evaluate(`document.querySelector('#dns-acl-error')?.textContent.match(/revision|stale|changed/i)`), 'Stale conflict not shown');
    await click('#dns-acl-refresh', 'refresh');
    await submit('invalid', 'allow networks not-a-cidr', '', false);
    await until(() => evaluate(`!!document.querySelector('#dns-acl-error') || !!document.querySelector('#dns-acl-rules-error')`), 'Invalid CIDR feedback absent');
    assert.deepEqual(await api(aclApi('acl-fixture', serviceId)), [...before, concurrent].sort((left, right) => left.name.localeCompare(right.name)));
    await click('#dns-acl-cancel', 'cancel');
    await submit('temporary', 'deny networks');
    const temporary = (await api(aclApi('acl-fixture', serviceId))).find(acl => acl.name === 'temporary');
    assert.ok(temporary);
    assert.deepEqual(temporary.rules, [{ action: 'deny', kind: 'networks', networks: [] }]);
    const deleteSelector = `#dns-acl-${temporary.id} [phx-click="delete"]`;
    await click(deleteSelector, 'delete');
    assert.equal(await evaluate(`!!document.querySelector('#dns-acl-confirm-delete')`), true, 'Delete must require server-side confirmation');
    await click('#dns-acl-cancel-delete', 'cancel_delete');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-confirm-delete') === null`), true);
    assert.deepEqual(await api(aclApi('acl-fixture', serviceId, temporary.id)), temporary);
    await click(deleteSelector, 'delete');
    await click('#dns-acl-confirm-delete', 'confirm_delete');
    assert.equal((await api(aclApi('acl-fixture', serviceId, temporary.id), undefined, 404)).code, 'not_found');
    assert.equal((await api(aclApi('acl-other', otherId, created.id), undefined, 404)).code, 'not_found');
    assert.deepEqual(await api(aclApi('acl-fixture', secondId)), []);
    assert.deepEqual(await api(aclApi('acl-other', otherId)), []);

    await click('#dns-acl-cancel', 'cancel');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-form button[type=submit]').classList.contains('btn-primary')`), true, 'The primary save, not a preset action, must be the form default');
    await changeFields({ 'acl[name]': 'geo-picker', 'acl[description]': '=2+3, "quoted"', 'acl[rules]': 'deny networks 192.0.2.7' });
    await click('#dns-acl-country-US', 'toggle_country');
    await changeFields({ country_search: 'Canada' });
    assert.equal(await evaluate(`!!document.querySelector('[data-selected-country-code="US"]')`), true, 'Search discarded selected countries');
    assert.equal(await evaluate(`!!document.querySelector('#dns-acl-country-US')`), false);
    await click('#dns-acl-country-CA', 'toggle_country');
    await click('[phx-click="clear_country_search"]', 'clear_country_search');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-country-US').checked && document.querySelector('#dns-acl-country-CA').checked`), true);
    await click('[data-selected-country-code="US"]', 'toggle_country');
    await click('#dns-acl-country-US', 'toggle_country');
    await changeFields({ 'acl[rules]': 'deny networks 192.0.2.7\ndeny networks ::1', country_action: 'allow' });
    await click('#dns-acl-add-countries', 'save');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-rules').value`), 'deny networks 192.0.2.7\ndeny networks ::1\nallow countries CA, US');
    await saveEditor();
    const geo = (await api(aclApi('acl-fixture', serviceId))).find(acl => acl.name === 'geo-picker');
    assert.deepEqual(geo.rules, [
      { action: 'deny', kind: 'networks', networks: ['192.0.2.7/32'] },
      { action: 'deny', kind: 'networks', networks: ['::1/128'] },
      { action: 'allow', kind: 'countries', countries: ['CA', 'US'] },
    ]);
    await changeFields({ 'acl[name]': 'localhost-preset', preset: 'localhost' });
    await click('#dns-acl-apply-preset', 'save');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-rules').value`), 'allow networks 127.0.0.1/32, ::1/128');
    await changeFields({ preset: 'any' });
    await click('#dns-acl-apply-preset', 'save');
    assert.equal(await evaluate(`document.querySelector('#dns-acl-rules').value`), 'allow networks 127.0.0.1/32, ::1/128');
    assert.match(await evaluate(`document.querySelector('#dns-acl-error').textContent`), /retained|empty/i);
    await saveEditor();
    const preset = (await api(aclApi('acl-fixture', serviceId))).find(acl => acl.name === 'localhost-preset');
    assert.deepEqual(preset.rules, [{ action: 'allow', kind: 'networks', networks: ['127.0.0.1/32', '::1/128'] }]);
    await acknowledged('filter', () => evaluate(`(() => {
      const form = document.querySelector('#dns-acl-filter-form');
      form.elements.namedItem('filter').value = 'quoted';
      form.requestSubmit();
    })()`));
    assert.equal(await evaluate(`document.querySelectorAll('#dns-acls-table tbody > tr').length`), 1);
    const allAcls = await api(aclApi('acl-fixture', serviceId));
    await click('#dns-acl-export', 'export_csv');
    const csvName = `dns_acls_acl-fixture_${serviceId}.csv`;
    await until(async () => (await readdir(downloadDirectory)).includes(csvName), 'CSV download missing');
    const csv = await readFile(join(downloadDirectory, csvName), 'utf8');
    assert.ok(csv.startsWith('Name,Description,Rules\r\n'));
    for (const acl of allAcls) assert.ok(csv.includes(`${acl.name},`), `Filtered CSV omitted ${acl.name}`);
    assert.ok(csv.includes(`"'=2+3, ""quoted"""`), 'CSV formula/quote escaping missing');
    assert.deepEqual(await api(aclApi('acl-fixture', serviceId)), allAcls, 'CSV mutated ACL data');
    evidence = { main: await api(aclApi('acl-fixture', serviceId)), secondary: [], other: [] };
    await writeFile(evidencePath, JSON.stringify(evidence));
  } else evidence = JSON.parse(await readFile(evidencePath, 'utf8'));
  for (const viewport of [{ width: 1440, height: 1000, mobile: false }, { width: 390, height: 844, mobile: true }]) {
    await cdp('Emulation.setDeviceMetricsOverride', { ...viewport, deviceScaleFactor: 1 });
    await verifyRows('acl-fixture', secondId, evidence.secondary);
    await verifyRows('acl-other', otherId, evidence.other);
    await verifyRows('acl-fixture', serviceId, evidence.main);
    const style = await evaluate(`({ overflow: document.documentElement.scrollWidth > innerWidth + 1, padding: parseFloat(getComputedStyle(document.querySelector('#dns-acl-form input')).paddingLeft) })`);
    assert.equal(style.overflow, false);
    assert.ok(style.padding > 0);
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(`${evidencePath}.${viewport.width}.png`, Buffer.from(screenshot.data, 'base64'));
  }
  assert.deepEqual(errors, []);
  console.log(`PASS Chromium DNS ACL ${verifyOnly ? 'read-only restart replay' : 'ordered create/edit/reset/CAS/validation/confirm-delete, countries/presets/filter/all-Service CSV'}: explicit Service scoping, noauth, mobile styles`);
} finally {
  socket?.close();
  if (browser?.pid && browser.exitCode === null && browser.signalCode === null) {
    browser.kill('SIGTERM');
    if (!(await Promise.race([browserClosed.then(() => true), delay(3000).then(() => false)]))) browser.kill('SIGKILL');
    assert.equal(await Promise.race([browserClosed.then(() => true), delay(3000).then(() => false)]), true);
  }
}
