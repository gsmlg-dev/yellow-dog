import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';

const [base, directory] = process.argv.slice(2);
assert.equal(new URL(base).hostname, '127.0.0.1');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const pending = new Map();
const errors = [];
let sequence = 0;
let socket;
const browser = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${directory}/browser`, 'about:blank'], { stdio: 'ignore' });
const closed = new Promise(resolve => browser.once('close', resolve));
browser.once('error', error => errors.push(error.message));

async function until(check, message) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    assert.deepEqual(errors, [], 'Browser error');
    if (await check()) return;
    await delay(100);
  }
  throw Error(message);
}

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => { pending.delete(id); reject(Error(`CDP timeout: ${method}`)); }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
  assert.ok(!result.exceptionDetails, 'Browser evaluation failed');
  return result.result.value;
}

try {
  let port;
  await until(async () => {
    try { port = (await readFile(`${directory}/browser/DevToolsActivePort`, 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const result = JSON.parse(event.data);
    if (result.id && pending.has(result.id)) {
      const item = pending.get(result.id);
      clearTimeout(item.timeout);
      pending.delete(result.id);
      if (result.error) item.reject(Error(result.error.message));
      else item.resolve(result.result);
    } else if (result.method === 'Runtime.exceptionThrown') errors.push('Unhandled browser exception');
  });
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  await cdp('Page.enable');
  await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await cdp('Browser.grantPermissions', { origin: base, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  await cdp('Page.navigate', { url: `${base}/management/servers` });
  await cdp('Page.bringToFront');
  await until(() => evaluate(`!!document.querySelector('.phx-connected #worker-form')`), 'Worker form did not connect');
  assert.equal(await evaluate(`document.querySelector('#worker-enrollment-form input[type="checkbox"]').checked`), false);
  await evaluate(`(() => { document.querySelector('#worker-enrollment-form input[type="checkbox"]').click(); document.querySelector('#worker-enrollment-form').requestSubmit(); })()`);
  await until(() => evaluate(`document.body.textContent.includes('Worker initialization setting saved.')`), 'Enrollment toggle did not save');
  await cdp('Page.navigate', { url: `${base}/management/servers` });
  await until(() => evaluate(`!!document.querySelector('.phx-connected #worker-enrollment-form input[type="checkbox"]:checked')`), 'Enrollment toggle did not persist after reload');
  await evaluate(`(() => { document.querySelector('#worker-enrollment-form input[type="checkbox"]').click(); document.querySelector('#worker-enrollment-form').requestSubmit(); })()`);
  await until(() => evaluate(`document.body.textContent.includes('Worker initialization setting saved.')`), 'Enrollment toggle did not disable');
  await cdp('Page.navigate', { url: `${base}/management/servers` });
  await until(() => evaluate(`!!document.querySelector('.phx-connected #worker-enrollment-form') && !document.querySelector('#worker-enrollment-form input[type="checkbox"]').checked`), 'Disabled enrollment did not persist');
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('#worker-form [name^="worker["]')).map(field => field.name)`), ['worker[name]']);
  await evaluate(`(() => { const name = document.querySelector('[name="worker[name]"]'); name.value = 'Browser Worker'; document.querySelector('#worker-form').requestSubmit(); })()`);
  await until(() => evaluate(`!!document.querySelector('#worker-bootstrap')`), 'Creation did not show the configuration');
  assert.equal(await evaluate(`document.querySelector('#worker-bootstrap').value.includes('management_url = "${base}"') && /token = "[A-Za-z0-9_-]{43}"/.test(document.querySelector('#worker-bootstrap').value)`), true);
  const copyText = await evaluate(`document.querySelector('#worker-bootstrap').value`);
  await evaluate(`document.querySelector('#worker-bootstrap-copy').click()`);
  await until(() => evaluate(`document.body.textContent.includes('Connection configuration copied.')`), 'Copy hook did not succeed');
  assert.ok(await evaluate(`navigator.clipboard.readText()`) === copyText, 'Copied configuration differs');
  const workerId = await evaluate(`Array.from(document.querySelectorAll('#server-selector-records tbody tr')).find(row => row.cells[0].textContent.trim() === 'Browser Worker').id.replace('server-selector-', '')`);
  await evaluate(`document.querySelector('[phx-click="dismiss_connection"]').click()`);
  await until(() => evaluate(`!document.querySelector('#worker-bootstrap')`), 'Saved configuration was not dismissed');
  const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
  await writeFile(`${directory}/workers.png`, Buffer.from(screenshot.data, 'base64'));
  await cdp('Page.navigate', { url: `${base}/server/${workerId}/dashboard` });
  await until(() => evaluate(`!!document.querySelector('.phx-connected #service-form')`), 'Worker dashboard did not connect');
  assert.equal(await evaluate(`document.querySelector('#worker-connection-status').textContent.includes('Not connected') && document.querySelector('#service-form').elements.namedItem('service[desired_state]').value === 'stopped'`), true);
  const detailScreenshot = await cdp('Page.captureScreenshot', { format: 'png' });
  await writeFile(`${directory}/worker-detail.png`, Buffer.from(detailScreenshot.data, 'base64'));
  await cdp('Page.navigate', { url: `${base}/management/servers` });
  await until(() => evaluate(`!!document.querySelector('.phx-connected #worker-form')`), 'Worker list did not reconnect');
  assert.equal(await evaluate(`document.querySelector('#worker-bootstrap') === null`), true);
  await writeFile(`${directory}/browser-result.json`, JSON.stringify({ result: 'PASS', worker_id: workerId, checks: ['persistent anonymous enrollment toggle', 'name-only creation', 'generated configuration', 'copy hook', 'one-time token', 'empty services', 'dashboard'] }));
  console.log('Chromium Worker management: PASS');
} finally {
  socket?.close();
  browser.kill('SIGTERM');
  if (!await Promise.race([closed.then(() => true), delay(3000).then(() => false)])) browser.kill('SIGKILL');
  await closed;
  for (const item of pending.values()) clearTimeout(item.timeout);
}
