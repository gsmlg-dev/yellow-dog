import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const base = process.env.MANAGEMENT_UI_URL;
assert.ok(base, 'Set MANAGEMENT_UI_URL to the disposable Management instance from tasks_release_smoke.py');
assert.ok(process.argv.slice(2).every(argument => argument === '--restart-check'), 'Only --restart-check is supported');
const restartCheck = process.argv.includes('--restart-check');
const fixture = Buffer.from(await readFile(new URL('./fixtures/geoip/GeoIP2-City-Test.mmdb.base64', import.meta.url), 'utf8'), 'base64');
const expectedDigest = createHash('sha256').update(fixture).digest('hex');
const profile = await mkdtemp(join(tmpdir(), 'management-tasks-browser-'));
const chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
const chromiumExited = new Promise(resolve => chromium.once('exit', resolve));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const errors = [];
const pending = new Map();
let chromiumError;
let socket;
let sequence = 0;
chromium.once('error', error => { chromiumError = error; });

async function until(check, message) {
  for (let attempt = 0; attempt < 150; attempt++) {
    if (chromiumError) throw chromiumError;
    if (errors.length) throw new Error(`Browser errors: ${JSON.stringify(errors)}`);
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

async function api(path) {
  const response = await fetch(`${base}/api${path}`, { signal: AbortSignal.timeout(5000) });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return result.data;
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

async function connected(path, selector) {
  const pathname = new URL(path, base).pathname;
  await until(() => evaluate(`location.pathname === ${JSON.stringify(pathname)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), `LiveView did not connect: ${path}`);
  assert.equal(await evaluate(`document.querySelector('input[type=password], #login') === null`), true, 'Tasks must not require login');
}

async function navigate(path, selector) {
  await cdp('Page.navigate', { url: `${base}${path}` });
  await connected(path, selector);
}

async function click(selector) {
  await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element || element.disabled) throw new Error('Missing or disabled control: ' + ${JSON.stringify(selector)});
    element.click();
  })()`);
}

async function verifyLoadedArtifact() {
  await navigate('/system/ip-database', '#ip-database-city');
  await until(() => evaluate(`(() => {
    const city = document.querySelector('#ip-database-city');
    if (city.querySelector('[data-status]').dataset.status === 'loaded') return true;
    document.querySelector('#ip-database-refresh').click();
    return false;
  })()`), 'Persisted city artifact did not load');
  const cityText = await evaluate(`document.querySelector('#ip-database-city').innerText`);
  assert.ok(cityText.includes(`${expectedDigest}.mmdb`), 'Loaded city path must identify the exact persisted fixture digest');
  assert.match(cityText, /GeoIP2-City/);

  await navigate('/tool/geoip', '#geoip-lookup-form');
  await evaluate(`(() => {
    const form = document.querySelector('#geoip-lookup-form');
    form.elements.namedItem('ip').value = '81.2.69.160';
    form.elements.namedItem('type').value = 'city';
    form.requestSubmit();
  })()`);
  await until(() => evaluate(`!!document.querySelector('#geoip-lookup-result') || !!document.querySelector('#geoip-lookup-error')`), 'Actual GeoIP lookup did not complete');
  assert.equal(await evaluate(`document.querySelector('#geoip-lookup-error')?.innerText || null`), null, 'Persisted artifact lookup failed');
  const location = await evaluate(`Object.fromEntries(Array.from(document.querySelectorAll('#geoip-lookup-result dt'), field => [field.textContent.trim(), field.nextElementSibling.textContent.trim()]))`);
  assert.equal(location.City, 'London');
  assert.match(location.Country, /United Kingdom/);
  assert.equal(location.Timezone, 'Europe/London');
}

try {
  let port;
  await until(async () => {
    try {
      port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0];
      return true;
    } catch {
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
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });

  if (restartCheck) {
    const beforeHistory = await api('/task-history');
    const beforeSchedule = await api('/tasks/ip_city');
    await verifyLoadedArtifact();
    const afterHistory = await api('/task-history');
    assert.deepEqual(afterHistory.map(job => job.id).sort((first, second) => first - second), beforeHistory.map(job => job.id).sort((first, second) => first - second), 'Restart inspection must not enqueue downloads');
    assert.equal((await api('/tasks/ip_city')).revision, beforeSchedule.revision, 'Restart inspection changed the schedule');
    assert.deepEqual(errors, [], 'JavaScript, CSP or asset errors');
    console.log('PASS real Chromium Tasks restart: persisted city artifact digest and actual London lookup, no new queued download');
  } else {
    await navigate('/system/tasks', '#tasks-overview');
    assert.equal(await evaluate(`document.querySelectorAll('#tasks-table tbody > tr').length`), 3);
    const original = await api('/tasks/ip_city');
    assert.equal(original.available, true);
    const cron = '17 3 2 * *';
    await evaluate(`(() => {
      const form = document.querySelector('#task-schedule-ip_city');
      const enabled = form.querySelector('input[type=checkbox][name="task[enabled]"]');
      enabled.checked = false;
      enabled.dispatchEvent(new Event('change', { bubbles: true }));
      const cron = form.elements.namedItem('task[cron]');
      cron.value = ${JSON.stringify(cron)};
      cron.dispatchEvent(new Event('input', { bubbles: true }));
      cron.dispatchEvent(new Event('change', { bubbles: true }));
      form.requestSubmit();
    })()`);
    await until(async () => {
      const saved = await api('/tasks/ip_city');
      return saved.revision === original.revision + 1 && saved.enabled === false && saved.cron === cron;
    }, 'DOM schedule edit did not persist its unchecked checkbox and UTC cron');
    await until(() => evaluate(`document.querySelector('#task-action-result')?.textContent.includes('schedule updated')`), 'Schedule save did not render its result');
    assert.equal(await evaluate(`document.querySelector('#task-schedule-ip_city input[type=checkbox]').checked`), false);
    assert.equal(await evaluate(`document.querySelector('#task-run-ip_city').disabled`), false, 'Manual run must remain available with the schedule disabled');
    assert.equal(await evaluate(`document.querySelector('#task-run-mac').disabled`), true);

    const previousJobs = await api('/tasks/ip_city/jobs');
    await click('#task-run-ip_city');
    await until(() => evaluate(`document.querySelector('#task-action-result')?.textContent.includes('Task queued (job ')`), 'DOM manual run did not report a queued job');
    const queueResult = await evaluate(`document.querySelector('#task-action-result').textContent`);
    const jobId = Number(queueResult.match(/job (\d+)/)[1]);
    assert.ok(!previousJobs.some(job => job.id === jobId), 'Manual run must queue a new durable job');
    await until(() => evaluate(`(() => {
      const text = document.querySelector('#task-row-ip_city').textContent;
      return text.includes('Last job #${jobId}') && text.includes('completed');
    })()`), 'Tasks overview did not automatically observe actual job completion within 15 seconds');
    const job = (await api('/tasks/ip_city/jobs')).find(entry => entry.id === jobId);
    assert.equal(job.state, 'completed');
    assert.ok(job.attempt > 0 && job.completed_at && job.attempted_at, 'Completed job must record a genuine attempt');
    assert.equal(job.result.digest, expectedDigest);
    assert.equal(job.result.size, fixture.length);
    assert.equal(job.result.metadata.database_type, 'GeoIP2-City');
    if (process.env.YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL) assert.equal(job.result.source_url, process.env.YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL);

    await click('#task-row-ip_city a');
    await connected('/system/tasks/ip_city', '#task-detail[data-task-key="ip_city"]');
    await click(`#task-job-${jobId} details summary`);
    await until(() => evaluate(`document.querySelector('#task-job-${jobId}')?.innerText.includes(${JSON.stringify(expectedDigest)})`), 'Detail history did not render the actual completed receipt');
    assert.deepEqual(await evaluate(`JSON.parse(document.querySelector('#task-job-${jobId} details pre').textContent)`), job.result);
    const detail = await evaluate(`document.querySelector('#task-job-${jobId}').innerText`);
    assert.ok(detail.includes('completed') && detail.includes(job.completed_at) && detail.includes(job.attempted_at));
    await click('a[href="/system/logs/tasks"]');
    await connected('/system/logs/tasks', '#task-logs');
    await click(`#task-job-${jobId} details summary`);
    assert.equal(await evaluate(`document.querySelector('#task-job-${jobId}').innerText.includes(${JSON.stringify(expectedDigest)})`), true);
    const failedCountry = (await api('/tasks/ip_country/jobs')).find(entry => entry.errors.length > 0);
    assert.ok(failedCountry, 'Parent fixture must retain a genuine failed Country attempt');
    await click(`#task-job-${failedCountry.id} details summary`);
    assert.deepEqual(await evaluate(`JSON.parse(document.querySelector('#task-job-${failedCountry.id} details pre').textContent)`), failedCountry.errors, 'Task Logs must render the actual failed attempts');

    await navigate('/system/tasks/mac', '#task-detail[data-task-key="mac"]');
    assert.equal(await evaluate(`document.querySelector('#task-run-mac').disabled`), true);
    assert.match(await evaluate(`document.querySelector('#task-detail').textContent`), /unavailable|blocked/i);
    assert.match(await evaluate(`document.querySelector('#task-detail').textContent`), /gsmlg_umbrella#8/);
    assert.deepEqual(await api('/tasks/mac/jobs'), [], 'Unavailable MAC task must not have queued work');
    await navigate('/system/ip-database', '#ip-database-download-city');
    assert.equal(await evaluate(`document.querySelector('#ip-database-download-country').textContent.trim()`), 'Queue IP Country');
    const directPrevious = await api('/tasks/ip_city/jobs');
    await click('#ip-database-download-city');
    await until(() => evaluate(`!!document.querySelector('#ip-database-download-result')?.dataset.jobId`), 'IP Database direct queue did not report a real job');
    const directJobId = Number(await evaluate(`document.querySelector('#ip-database-download-result').dataset.jobId`));
    assert.equal(await evaluate(`document.querySelector('#ip-database-download-result').dataset.taskKey`), 'ip_city');
    assert.match(await evaluate(`document.querySelector('#ip-database-download-result').textContent`), /Queueing is not successful completion/);
    assert.ok(!directPrevious.some(job => job.id === directJobId));
    await until(async () => (await api('/tasks/ip_city/jobs')).find(job => job.id === directJobId)?.state === 'completed', 'Direct IP Database city sync did not finish');
    const directCompleted = (await api('/tasks/ip_city/jobs')).find(job => job.id === directJobId);
    assert.equal(directCompleted.result.digest, expectedDigest);
    assert.ok(directCompleted.attempted_at && directCompleted.completed_at && directCompleted.attempt > 0);
    assert.equal((await api('/tasks/ip_city')).enabled, false, 'Direct enqueue must not enable the schedule');
    await verifyLoadedArtifact();
    assert.deepEqual(errors, [], 'JavaScript, CSP or asset errors');
    console.log('PASS real Chromium Tasks/IP Database: disabled UTC schedule, manual and direct city queue with real completion receipts, Task Logs errors, MAC unavailable, persisted MMDB/London lookup');
  }
} finally {
  for (const request of pending.values()) {
    clearTimeout(request.timeout);
    request.reject(new Error('Browser session closed'));
  }
  pending.clear();
  socket?.close();
  chromium.kill('SIGTERM');
  await Promise.race([chromiumExited, delay(2000)]);
  if (chromium.exitCode === null && chromium.signalCode === null && !chromiumError) {
    chromium.kill('SIGKILL');
    await chromiumExited;
  }
  await rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
}
