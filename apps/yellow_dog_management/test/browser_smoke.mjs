// Native CDP smoke test using installed Chromium and Node >= 22; no package install.
// Run against an empty disposable database with the Management HTTP server running.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
const base = process.env.MANAGEMENT_UI_URL || 'http://127.0.0.1:14281';
const token = process.env.YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN;
assert(token, 'Set the disposable operator token');
const profile = await mkdtemp(join(tmpdir(), 'management-browser-'));
const download = await mkdtemp(join(tmpdir(), 'management-download-'));
const child = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'], { stdio: 'ignore' });
let socket;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(fn, message) { for (let i = 0; i < 100; i++) { try { const result = await fn(); if (result) return result; } catch {} await delay(100); } throw new Error(message); }
try {
  const port = await until(async () => (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0], 'Chromium did not start');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(base)}`, { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
  let counter = 0; const waiting = new Map(), exceptions = [];
  socket.addEventListener('message', event => { const message = JSON.parse(event.data); if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params); if (message.id) { const request = waiting.get(message.id); waiting.delete(message.id); message.error ? request.reject(message.error) : request.resolve(message.result); } });
  function cdp(method, params = {}) { return new Promise((resolve, reject) => { const id = ++counter; waiting.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params })); }); }
  async function evaluate(expression) { const response = await cdp('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }); if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails)); return response.result.value; }
  await cdp('Runtime.enable');
  await cdp('Page.enable');
  await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: download });
  await until(() => evaluate('document.readyState === "complete" && typeof recordRow === "function"'), 'UI did not load');
  assert.match(await evaluate('document.body.innerText'), /Actual runtime state is unknown/);
  await evaluate(`document.getElementById('token').value=${JSON.stringify(token)}; document.getElementById('login').requestSubmit()`);
  const notice = text => until(() => evaluate(`document.getElementById('notice').textContent.includes(${JSON.stringify(text)})`), 'Missing UI notice: ' + text);
  await notice('Signed in');
  assert.equal(await evaluate('workers.length'), 0);
  await evaluate(`
    document.querySelector('#zone-form [name=name]').value='browser.test.';
    document.getElementById('add-record').click(); document.getElementById('add-record').click();
    const rows=[...document.querySelectorAll('#records tr')];
    const values=[['browser.test.','SOA','ns.browser.test. hostmaster.browser.test. 1 3600 600 86400 300'],['browser.test.','NS','ns.browser.test.'],['ns.browser.test.','A','192.0.2.90']];
    rows.forEach((row,i)=>{const inputs=row.querySelectorAll('input');inputs[0].value=values[i][0];row.querySelector('select').value=values[i][1];inputs[1].value='300';inputs[2].value=values[i][2];});
    document.getElementById('zone-form').requestSubmit();
  `);
  await notice('Draft saved');
  await evaluate(`document.getElementById('notice').textContent=''; [...document.querySelectorAll('#records tr')].find(r=>r.querySelector('select').value==='A').querySelectorAll('input')[2].value='192.0.2.91';document.getElementById('zone-form').requestSubmit()`);
  await notice('Draft saved');
  assert.equal(await evaluate('workers.length'), 0);
  await evaluate("document.getElementById('confirm-zone').click()"); await notice('Immutable version confirmed');
  await evaluate("document.querySelector('#worker-form [name=id]').value='browser-worker';document.querySelector('#worker-form [name=name]').value='Browser Worker';document.getElementById('worker-form').requestSubmit()");
  await notice('Logical Worker saved');
  await evaluate("document.querySelector('#worker-form [name=name]').value='Edited Browser Worker';document.getElementById('notice').textContent='';document.getElementById('worker-form').requestSubmit()");
  await notice('Logical Worker saved');
  await evaluate("document.getElementById('service-form').requestSubmit()"); await notice('Desired service state saved');
  await evaluate("document.querySelector('#assignment-workers input').checked=true;document.getElementById('assignment-form').requestSubmit()"); await notice('Version assigned to 1');
  await evaluate("document.getElementById('preview').click()");
  const preview = await until(async () => { const text = await evaluate("document.getElementById('preview-output').textContent"); return text && JSON.parse(text); }, 'No preview');
  assert.equal(preview.plan.resources.length, 1); assert.equal(preview.plan.services[0].desired_state, 'stopped');
  await evaluate("document.getElementById('confirm-target').click()"); await notice('Complete target confirmed');
  await evaluate("document.getElementById('export-form').requestSubmit()"); await notice('Prepared TOML exported');
  const files = await until(async () => { const files = await readdir(download); return files.some(f => f.endsWith('.toml')) && files; }, 'No TOML download');
  assert.match(await readFile(join(download, files.find(f => f.endsWith('.toml'))), 'utf8'), /192\.0\.2\.91/);
  await evaluate("document.querySelector('#assignments button').click()"); await notice('Resource unassigned');
  await evaluate("document.getElementById('preview').click()");
  const empty = await until(async () => { const text = await evaluate("document.getElementById('preview-output').textContent"); return text && JSON.parse(text); }, 'No empty preview');
  assert.equal(empty.plan.resources.length, 0); assert.equal(empty.plan.services[0].desired_state, 'stopped');
  const screenshot = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  const { writeFile } = await import('node:fs/promises');
  await writeFile('/tmp/yellow-dog-management-ui.png', Buffer.from(screenshot.data, 'base64'));
  assert.deepEqual(exceptions, []);
  console.log('BROWSER SMOKE PASSED: sign-in, zero-Worker DNS create/edit/confirm, Worker create/edit, service desired state, assignment, preview, target confirmation, TOML download, unassignment; no JS exceptions');
} finally {
  socket?.close(); child.kill('SIGTERM'); await new Promise(resolve => child.once('exit', resolve));
  await rm(profile, { recursive: true, force: true }); await rm(download, { recursive: true, force: true });
}
