import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

assert.ok(process.env.YELLOW_DOG_PHASE1_PG_DATA_DIR && process.env.MANAGEMENT_UI_URL && process.env.MANAGEMENT_OVERVIEW_EVIDENCE, 'Use the disposable management_overview.sh harness');
const base = new URL(process.env.MANAGEMENT_UI_URL).origin;
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const pending = new Map();
const errors = [];
const refreshRequests = new Set();
const refreshReplies = new Set();
let sequence = 0;
let socket;
let chromium;
let chromiumExited;
let profile;

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
    ...(body ? { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() }, body: JSON.stringify(body) } : {}),
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
  await cdp('Page.navigate', { url: `${base}${path}` });
  await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true);
}

async function refresh(selector) {
  const before = refreshReplies.size;
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  await until(() => refreshReplies.size > before, 'LiveView refresh was not acknowledged by the server');
}

async function eventRows() {
  await navigate('/management/events', '#management-events');
  return evaluate(`Array.from(document.querySelectorAll('#management-events tbody tr')).slice(0, 5).map(row => ({
    id: row.querySelector('button[phx-click="show"]').getAttribute('phx-value-id'),
    actor: row.children[1].textContent.trim(), operation: row.children[2].textContent.trim(), inserted_at: row.children[0].textContent.trim()
  }))`);
}

async function verifyOutcomes() {
  await navigate('/management/events', '#management-command-outcomes');
  const auditIds = await evaluate(`Array.from(document.querySelectorAll('#management-events tbody tr button[phx-click="show"]')).map(button => button.getAttribute('phx-value-id'))`);
  const outcomes = await evaluate(`Array.from(document.querySelectorAll('#management-command-outcomes [data-event-id]')).map(row => ({ id: row.dataset.eventId, outcome: row.dataset.outcome, operation: row.dataset.operation }))`);
  assert.deepEqual(outcomes.map(row => row.id), auditIds);
  assert.ok(outcomes.some(row => row.outcome === 'committed' && row.operation === 'create_netman'));
  assert.ok(outcomes.some(row => row.outcome === 'rejected' && row.operation === 'create_worker'));
  assert.ok(outcomes.some(row => row.outcome === 'rejected' && row.operation === 'create_zone'));
  for (const id of ['management-worker-events', 'management-netman-events']) {
    assert.equal(await evaluate(`!!document.querySelector('#${id}')`), true);
  }
  const rejected = outcomes.find(row => row.outcome === 'rejected' && row.operation === 'create_worker');
  await evaluate(`document.querySelector('#management-events button[phx-value-id="${rejected.id}"]').click()`);
  await until(() => evaluate(`!!document.querySelector('#event-details')`), 'Rejected command details did not open');
  const details = await evaluate(`JSON.parse(document.querySelector('#event-details').textContent)`);
  assert.equal(details.id, rejected.id);
  assert.equal(details.result.error.code, 'conflict');
  assert.equal(details.operation, 'create_worker');
  await refresh('#management-events-refresh');
  await until(() => evaluate(`document.querySelector('#event-details') === null`), 'Read-only Events refresh did not clear prior selection');
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('#management-command-outcomes [data-event-id]')).map(row => ({ id: row.dataset.eventId, outcome: row.dataset.outcome, operation: row.dataset.operation }))`), outcomes);
  return outcomes;
}

async function verifyOverview(events) {
  const [workers, netmans, zones] = await Promise.all([api('/workers'), api('/netmans'), api('/zones')]);
  const result = await evaluate(`({
    worker_count: Number(document.querySelector('#management-worker-count').textContent.trim()),
    netman_count: Number(document.querySelector('#management-netman-count').textContent.trim()),
    zone_count: Number(document.querySelector('#management-zone-count').textContent.trim()),
    profile_count: Number(document.querySelector('#management-profile-count').textContent.trim()),
    event_count: Number(document.querySelector('#management-recent-event-count').textContent.trim()),
    event_ids: Array.from(document.querySelectorAll('#management-recent-events [data-event-id]')).map(row => row.dataset.eventId),
    events: Array.from(document.querySelectorAll('#management-recent-events [data-event-id]')).map(row => ({ id: row.dataset.eventId, operation: row.children[0].textContent.trim(), actor: row.children[1].textContent.trim(), inserted_at: row.children[2].textContent.trim() }))
  })`);
  assert.equal(result.worker_count, workers.length);
  assert.equal(result.netman_count, netmans.length);
  assert.equal(result.zone_count, zones.length);
  assert.equal(result.profile_count, 13);
  assert.equal(result.event_count, events.length);
  assert.deepEqual(result.event_ids, events.map(event => event.id));
  assert.deepEqual(result.events, events);
  for (const event of events) {
    const text = await evaluate(`document.querySelector('#management-recent-events [data-event-id="${event.id}"]').textContent`);
    assert.ok(text.includes(event.operation) && text.includes(event.actor), JSON.stringify(event));
  }
  for (const path of ['/management/profiles', '/management/events', '/management/servers', '/management/netman', '/management/zones', '/management/config']) {
    assert.equal(await evaluate(`!!document.querySelector('#management-overview a[href="${path}"]')`), true, `Missing overview link: ${path}`);
  }
  return result;
}

try {
  profile = process.env.MANAGEMENT_OVERVIEW_BROWSER_PROFILE || await mkdtemp(join(tmpdir(), 'management-overview-browser-'));
  await mkdir(profile, { recursive: true, mode: 0o700 });
  chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  chromiumExited = new Promise(resolve => chromium.once('exit', resolve));
  chromium.once('error', error => errors.push(error.message));
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return true; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(5000) })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params);
    if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') errors.push(message.params);
    if (['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(message.method)) {
      let frame;
      try { frame = JSON.parse(message.params.response.payloadData); } catch { frame = null; }
      if (Array.isArray(frame)) {
        const identity = `${frame[2]}:${frame[1]}`;
        if (message.method === 'Network.webSocketFrameSent' && frame[3] === 'event' && frame[4]?.event === 'refresh') refreshRequests.add(identity);
        if (message.method === 'Network.webSocketFrameReceived' && frame[3] === 'phx_reply' && refreshRequests.has(identity)) {
          if (frame[4]?.status === 'ok') refreshReplies.add(identity);
          else errors.push({ refreshFailed: frame });
        }
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
  await cdp('Runtime.enable');
  await cdp('Log.enable');
  await cdp('Page.enable');
  await cdp('Network.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });

  if (process.env.MANAGEMENT_OVERVIEW_VERIFY_ONLY !== '1') {
    const suffix = randomUUID().slice(0, 8);
    const workerId = `overview-ui-${suffix}`;
    await navigate('/management/servers', '#worker-form');
    await evaluate(`(() => { const form = document.querySelector('#worker-form'); form.elements.namedItem('worker[id]').value = '${workerId}'; form.elements.namedItem('worker[name]').value = 'Overview Browser Worker'; form.requestSubmit(); })()`);
    await until(() => evaluate(`!!document.querySelector('#server-selector-${workerId}')`), 'Worker UI registration did not complete');
    const netmanId = `overview-netman-${suffix}`;
    await navigate('/management/netman', '#netman-form');
    await evaluate(`(() => { const form = document.querySelector('#netman-form'); form.elements.namedItem('netman[id]').value = '${netmanId}'; form.elements.namedItem('netman[name]').value = 'Overview Browser Netman'; form.requestSubmit(); })()`);
    await until(async () => (await api('/netmans')).some(node => node.id === netmanId), 'Netman UI registration did not complete');
    const node = await api(`/netmans/${netmanId}`);
    assert.equal(node.actual_state, 'unknown');
    assert.equal(node.status, 'not_yet_connected');
    assert.equal(node.last_seen_at, null);
  }

  let events = await eventRows();
  await navigate('/management', '#management-overview');
  await verifyOverview(events);
  if (process.env.MANAGEMENT_OVERVIEW_VERIFY_ONLY === '1') {
    await refresh('#management-overview-refresh');
    await verifyOverview(events);
  }
  if (process.env.MANAGEMENT_OVERVIEW_VERIFY_ONLY !== '1') {
    const worker = (await api('/workers')).find(item => item.id.startsWith('overview-ui-'));
    await api('/commands/update_worker', { id: worker.id, name: 'Refreshed Overview Worker', expected_revision: worker.revision });
    const rejected = await api('/commands/create_worker', { id: worker.id, name: 'Duplicate Worker', expected_capabilities: ['dns'] }, 409);
    assert.equal(rejected.code, 'conflict');
    const invalidZone = await api('/commands/create_zone', { name: { invalid: 'not text' }, records: [] }, 422);
    assert.equal(typeof invalidZone.code, 'string');
    const oldIds = events.map(event => event.id);
    assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('#management-recent-events [data-event-id]')).map(row => row.dataset.eventId)`), oldIds, 'Overview invents an unobserved event instead of refreshing');
    await refresh('#management-overview-refresh');
    await until(async () => JSON.stringify(await evaluate(`Array.from(document.querySelectorAll('#management-recent-events [data-event-id]')).map(row => row.dataset.eventId)`)) !== JSON.stringify(oldIds), 'Overview refresh did not discover actual committed audit');
    events = await evaluate(`(async () => { const response = await fetch('/management/events'); if (!response.ok) throw new Error('Failed read-only event inspection'); const document = new DOMParser().parseFromString(await response.text(), 'text/html'); return Array.from(document.querySelectorAll('#management-events tbody tr')).slice(0, 5).map(row => ({ id: row.querySelector('button[phx-click="show"]').getAttribute('phx-value-id'), actor: row.children[1].textContent.trim(), operation: row.children[2].textContent.trim(), inserted_at: row.children[0].textContent.trim() })); })()`);
    await verifyOverview(events);
  }
  const evidence = await verifyOverview(events);
  const outcomes = await verifyOutcomes();
  await navigate('/management', '#management-overview');
  await evaluate(`document.querySelector('#management-overview a[href="/management/profiles"]').click()`);
  await until(() => evaluate(`location.pathname === '/management/profiles' && !!document.querySelector('#management-server-profiles') && !!document.querySelector('.phx-connected')`), 'Overview Profiles navigation did not connect');
  assert.equal(await evaluate(`document.querySelectorAll('#management-server-profiles > tr').length + document.querySelectorAll('#management-netman-profiles > tr').length`), 13);
  await navigate('/management', '#management-overview');
  await evaluate(`document.querySelector('#management-overview a[href="/management/events"]').click()`);
  await until(() => evaluate(`location.pathname === '/management/events' && !!document.querySelector('#management-events') && !!document.querySelector('.phx-connected')`), 'Overview Events navigation did not connect');
  await navigate('/management', '#management-overview');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  assert.equal(await evaluate(`document.documentElement.scrollWidth <= innerWidth + 1`), true, 'Overview overflows mobile viewport');
  assert.deepEqual(await verifyOverview(events), evidence, 'Overview fields changed during read-only navigation');
  assert.deepEqual(errors, []);
  await writeFile(process.env.MANAGEMENT_OVERVIEW_EVIDENCE, JSON.stringify({ ...evidence, outcomes }));
  console.log('PASS Chromium Overview/Events: actual counts, 13 presets, latest-five audits, grouped desired events, committed/rejected commands and details, read-only refresh/navigation, mobile/noauth and unknown runtime state');
} finally {
  for (const request of pending.values()) { clearTimeout(request.timeout); request.reject(new Error('Browser closed')); }
  socket?.close();
  if (chromium && chromium.exitCode === null) {
    chromium.kill('SIGTERM');
    await Promise.race([chromiumExited, delay(3000)]);
    if (chromium.exitCode === null) { chromium.kill('SIGKILL'); await chromiumExited; }
  }
  if (profile) await rm(profile, { recursive: true, force: true });
}
