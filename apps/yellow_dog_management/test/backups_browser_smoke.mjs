import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

assert.ok(process.env.MANAGEMENT_UI_URL, 'Set MANAGEMENT_UI_URL to the disposable Management release with a seeded ready backup');
assert.equal(process.argv.length, 2, 'This script takes no arguments');
const address = new URL(process.env.MANAGEMENT_UI_URL);
assert.ok(['http:', 'https:'].includes(address.protocol) && address.pathname === '/' && !address.search && !address.hash, 'MANAGEMENT_UI_URL must be the root URL of the disposable release');
const base = address.origin;
const label = `browser_${randomUUID()}`;
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const errors = [];
const pending = new Map();
let sequence = 0;
let socket;
let chromium;
let chromiumExited;
let chromiumError;
let profile;

async function until(check, message, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (chromiumError) throw chromiumError;
    if (errors.length) throw new Error(`Browser errors: ${JSON.stringify(errors)}`);
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

async function api(path, timeout = 5000) {
  const response = await fetch(`${base}/api${path}`, { signal: AbortSignal.timeout(timeout) });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return result.data;
}

async function businessState() {
  const [workers, zones, netmans, tasks] = await Promise.all([
    api('/workers'), api('/zones'), api('/netmans'), api('/tasks'),
  ]);
  return {
    workers: await Promise.all(workers.map(worker => api(`/workers/${encodeURIComponent(worker.id)}`))),
    zones: await Promise.all(zones.map(zone => api(`/zones/${encodeURIComponent(zone.id)}`))),
    zoneVersions: await Promise.all(zones.map(zone => api(`/zones/${encodeURIComponent(zone.id)}/versions`))),
    netmans,
    netmanConfigs: await Promise.all(netmans.map(netman => api(`/netmans/${encodeURIComponent(netman.id)}/config`))),
    netmanVersions: await Promise.all(netmans.map(netman => api(`/netmans/${encodeURIComponent(netman.id)}/versions`))),
    schedules: tasks.map(task => ({ key: task.key, enabled: task.enabled, cron: task.cron, revision: task.revision })),
  };
}

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`CDP timed out: ${method}`));
    }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const response = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails));
  return response.result.value;
}

async function navigate(path, selector) {
  await cdp('Page.navigate', { url: `${base}${path}` });
  await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true, 'Backups must not require login');
}

async function click(selector) {
  await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element || element.disabled) throw new Error('Missing or disabled control: ' + ${JSON.stringify(selector)});
    element.click();
  })()`);
}

async function verifyPackage(id, proof) {
  await until(() => evaluate(`!!document.querySelector('#backup-verification[data-backup-id="${id}"]') && !document.querySelector('#backup-verifying')`), `Byte verification did not complete for ${id}`, 180000);
  assert.equal(await evaluate(`document.querySelector('#backup-error')?.textContent || null`), null, 'Package verification failed');
  const fields = await evaluate(`Object.fromEntries(Array.from(document.querySelectorAll('#backup-verification dt'), field => [field.textContent.trim(), field.nextElementSibling.textContent.trim()]))`);
  assert.equal(fields['Backup ID'], id);
  assert.equal(fields['Verification level'], 'byte_integrity');
  assert.equal(fields['Dump digest'], proof.dump_digest);
  assert.equal(Number(fields['Artifacts verified']), proof.artifact_count);
  assert.equal(Number(fields['Package row count']), proof.row_count);
  assert.match(await evaluate(`document.querySelector('#backup-verification').textContent`), /does not prove full recoverability/);
}

try {
  const seeded = (await api('/backups')).filter(backup => backup.state === 'ready');
  assert.ok(seeded.length > 0, 'Parent must seed a genuine ready backup before running this script');
  const beforeBusiness = await businessState();
  profile = await mkdtemp(join(tmpdir(), 'management-backups-browser-'));
  const downloads = join(profile, 'downloads');
  await mkdir(downloads);
  chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  chromiumExited = new Promise(resolve => chromium.once('exit', resolve));
  chromium.once('error', error => { chromiumError = error; });
  let port;
  await until(async () => {
    try {
      port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0];
      return true;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return false;
    }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(5000) })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('CDP websocket did not open')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
    socket.addEventListener('error', error => { clearTimeout(timeout); reject(error); }, { once: true });
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params);
    if (message.method === 'Log.entryAdded') {
      const entry = message.params.entry;
      if (entry.level === 'error' || (entry.source === 'security' && /content security policy|violat|refused/i.test(entry.text))) errors.push(entry);
    }
    if (message.method === 'Page.javascriptDialogOpening') {
      errors.push({ unexpectedDialog: message.params });
      cdp('Page.handleJavaScriptDialog', { accept: false }).catch(error => errors.push(error.message));
    }
    if (message.id && pending.has(message.id)) {
      const request = pending.get(message.id);
      pending.delete(message.id);
      clearTimeout(request.timeout);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    }
  });
  await cdp('Runtime.enable');
  await cdp('Log.enable');
  await cdp('Page.enable');
  await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await navigate('/system/backups', '#backups-list');
  for (const backup of seeded) assert.equal(await evaluate(`!!document.querySelector('#backup-row-${backup.id}')`), true, 'Seeded ready backup must render');

  await evaluate(`(() => {
    window.backupSmoke = { states: [], id: null };
    const observe = () => {
      const marker = Array.from(document.querySelectorAll('#backups-list [id^="backup-row-"]')).find(element => element.textContent.includes(${JSON.stringify(label)}));
      if (!marker) return;
      window.backupSmoke.id = marker.id.slice('backup-row-'.length);
      const state = marker.closest('tr').children[1].textContent.trim();
      if (!window.backupSmoke.states.includes(state)) window.backupSmoke.states.push(state);
    };
    new MutationObserver(observe).observe(document.querySelector('#backups-list'), { childList: true, subtree: true, characterData: true });
    const form = document.querySelector('#backup-create-form');
    form.elements.namedItem('label').value = ${JSON.stringify(label)};
    form.requestSubmit();
  })()`);
  await until(() => evaluate(`window.backupSmoke.states.includes('pending')`), 'New backup never rendered its genuine pending state', 180000);
  await until(() => evaluate(`window.backupSmoke.states.includes('ready') && document.querySelector('#backup-label').value === '' && !document.querySelector('#backup-create-form button').disabled`), 'Backup did not automatically progress from pending to ready and reset its create controls', 180000);
  const observed = await evaluate('window.backupSmoke');
  const id = observed.id;
  assert.match(id, /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/);
  assert.ok(observed.states.indexOf('pending') < observed.states.indexOf('ready'));
  const ready = await api(`/backups/${id}`);
  assert.equal(ready.label, label);
  assert.equal(ready.state, 'ready');
  assert.ok(ready.completed_at && ready.digest && ready.size > 0 && Number.isInteger(ready.row_count), 'Ready must describe an actual completed package');
  const proof = await api(`/backups/${id}/verify`, 180000);
  assert.equal(proof.valid, true);
  assert.equal(proof.level, 'byte_integrity');
  assert.equal(proof.row_count, ready.row_count);

  const row = `#backup-row-${id}`;
  const action = event => `#backups-list button[phx-click="${event}"][phx-value-id="${id}"]`;
  await click(action('verify'));
  await verifyPackage(id, proof);
  assert.equal(await evaluate(`document.querySelector('#backup-verification dd:nth-of-type(3)').textContent.trim()`), ready.digest);
  await click('#backup-verification button[phx-click="dismiss_verify"]');
  await until(() => evaluate(`!document.querySelector('#backup-verification')`), 'Verification did not dismiss');

  const download = `#backups-list a[href="/api/backups/${id}/download"]`;
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(download)}).closest('tr') === document.querySelector(${JSON.stringify(row)}).closest('tr')`), true, 'Download must belong to the browser-created package');
  await click(download);
  let archive;
  await until(async () => {
    try {
      archive = await readFile(join(downloads, `management-backup-${id}.tar`));
      return true;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return false;
    }
  }, 'Clicking Download did not produce the actual package', 180000);
  assert.equal(archive.length, ready.size);
  assert.equal(createHash('sha256').update(archive).digest('hex'), ready.digest, 'Downloaded package checksum must match the catalog');

  await click(action('delete'));
  await until(() => evaluate(`document.querySelector('#backup-delete-confirmation')?.textContent.includes('${id}')`), 'Delete did not open the selected confirmation');
  assert.deepEqual(await api(`/backups/${id}`), ready, 'Opening deletion confirmation must not delete anything');
  await click('#backup-delete-confirmation button[phx-click="cancel_delete"]');
  await until(() => evaluate(`!document.querySelector('#backup-delete-confirmation')`), 'Deletion cancellation did not dismiss confirmation');
  assert.deepEqual(await api(`/backups/${id}`), ready, 'Canceled deletion must leave the package unchanged');
  assert.deepEqual(await businessState(), beforeBusiness, 'Canceling deletion changed business data');

  await navigate('/system/backups/restore', '#backup-restore-page');
  assert.match(await evaluate(`document.querySelector('#backup-restore-capability').textContent`), /not available yet/);
  assert.equal(await evaluate(`document.querySelector('#backup-restore-command') === null && !document.querySelector('#workspace').textContent.includes('mix management.restore')`), true, 'An unimplemented CLI must not be presented as executable');
  await evaluate(`(() => {
    const form = document.querySelector('#backup-restore-form');
    form.elements.namedItem('id').value = '${id}';
    form.requestSubmit();
  })()`);
  await verifyPackage(id, proof);
  assert.equal(await evaluate(`document.querySelector('#backup-restore-unavailable') === null`), true, 'Restore acknowledgement must require confirmation');
  await click('#backup-confirm-restore');
  await until(() => evaluate(`!!document.querySelector('#backup-restore-unavailable')`), 'Restore acknowledgement did not render the blocked execution state');
  const restoreText = await evaluate(`document.querySelector('#backup-restore-unavailable').textContent`);
  assert.match(restoreText, /not available yet/);
  assert.match(restoreText, /No restore has run/);
  assert.match(await evaluate(`document.querySelector('#backup-restore-page').textContent`), /downtime/);
  assert.equal(await evaluate(`document.querySelector('#backup-restore-command') === null && !document.querySelector('#workspace').textContent.includes('mix management.restore')`), true);
  await click('#backup-restore-form button[phx-click="cancel_restore"]');
  await until(() => evaluate(`!document.querySelector('#backup-restore-unavailable, #backup-verification')`), 'Cancel Restore did not clear acknowledgement and verification');
  assert.deepEqual(await api(`/backups/${id}`), ready, 'Restore selection/verification/confirmation/cancellation must not mutate the package');
  assert.deepEqual(await businessState(), beforeBusiness, 'Restore preparation changed live business data');

  await navigate('/system/backups', '#backups-list');
  await click(action('delete'));
  await until(() => evaluate(`document.querySelector('#backup-confirm-delete')?.getAttribute('phx-value-id') === '${id}'`), 'Delete confirmation must select only the browser-created package');
  await click('#backup-confirm-delete');
  await until(async () => (await api(`/backups/${id}`)).state === 'deleted', 'Confirmed deletion did not actually complete', 30000);
  await until(() => evaluate(`document.querySelector(${JSON.stringify(row)}).closest('tr').children[1].textContent.trim() === 'deleted' && !document.querySelector('#backup-delete-confirmation')`), 'UI did not automatically render completed deletion', 30000);
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(download)}) === null`), true, 'Deleted packages must not retain a download link');
  assert.deepEqual(await businessState(), beforeBusiness, 'Deleting a backup changed retained business data');
  for (const backup of seeded) {
    assert.deepEqual(await api(`/backups/${backup.id}`), backup, 'Never delete or modify the parent-seeded snapshots');
    const retained = await api(`/backups/${backup.id}/verify`, 180000);
    assert.equal(retained.valid, true, 'Parent-seeded package must remain byte-verifiable');
    assert.equal(retained.level, 'byte_integrity');
  }
  assert.equal(await evaluate(`document.querySelector('#backup-error')?.textContent || null`), null);
  assert.deepEqual(errors, [], 'JavaScript, CSP or asset errors');
  console.log(`PASS real Chromium Backups: ${label} (${id}), pending -> ready/reset, byte-integrity verification, checksum-matched browser download, canceled/confirmed deletion, retained business data and seeded snapshots, restore execution honestly unavailable`);
} finally {
  for (const request of pending.values()) {
    clearTimeout(request.timeout);
    request.reject(new Error('Browser session closed'));
  }
  pending.clear();
  socket?.close();
  if (chromium && !chromiumError) {
    chromium.kill('SIGTERM');
    await Promise.race([chromiumExited, delay(2000)]);
    if (chromium.exitCode === null && chromium.signalCode === null) {
      chromium.kill('SIGKILL');
      await chromiumExited;
    }
  }
  if (profile) await rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}
