import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export async function browser(base, gatewayAssertion, work) {
  const profile = await mkdtemp(join(tmpdir(), 'management-mcp-browser-'));
  const chromium = spawn('chromium', ['--headless', '--disable-gpu', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  let socket;
  try {
    let port;
    await until(async () => { try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return true; } catch { return false; } }, 'Chromium startup');
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
    await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
    let sequence = 0;
    const pending = new Map();
    const loaded = new Set();
    const errors = [];
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const call = pending.get(message.id); pending.delete(message.id);
        if (message.error) call?.reject(message.error); else call?.resolve(message.result);
      }
      if (message.method === 'Page.lifecycleEvent' && message.params.name === 'load') loaded.add(message.params.loaderId);
      if (message.method === 'Runtime.exceptionThrown') errors.push(message.params);
      if (message.method === 'Page.javascriptDialogOpening') cdp('Page.handleJavaScriptDialog', { accept: true });
    });
    const cdp = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++sequence; pending.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params }));
    });
    const evaluate = async expression => {
      const result = await cdp('Runtime.evaluate', { expression, returnByValue: true });
      assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
      return result.result.value;
    };
    await cdp('Page.enable');
    await cdp('Runtime.enable');
    await cdp('Network.enable');
    await cdp('Page.setLifecycleEventsEnabled', { enabled: true });
    await cdp('Network.setExtraHTTPHeaders', { headers: { 'x-yellow-dog-gateway-assertion': gatewayAssertion } });
    const navigate = async path => {
      const response = await cdp('Page.navigate', { url: `${base}${path}` });
      if (response.loaderId) await until(() => loaded.has(response.loaderId), `Page load ${path}`);
      await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected')`), `LiveView ${path}`);
    };
    const change = (selector, values) => evaluate(`(() => {
      const form = document.querySelector(${JSON.stringify(selector)});
      for (const [name,value] of Object.entries(${JSON.stringify(values)})) {
        const field = form.elements.namedItem(name);
        if (!field) throw new Error('Missing form field '+name);
        field.value = value; field.dispatchEvent(new Event('input',{bubbles:true})); field.dispatchEvent(new Event('change',{bubbles:true}));
      }
    })()`);
    const click = selector => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
    const submit = async (selector, values) => {
      await change(selector, values);
      await until(() => evaluate(`!document.querySelector(${JSON.stringify(selector)}).querySelector('[type="submit"]').disabled`), `Form enabled ${selector}`);
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).requestSubmit()`);
    };
    await work({ cdp, evaluate, navigate, change, click, submit, until });
    assert.deepEqual(errors, [], 'Browser runtime errors');
  } finally {
    socket?.close();
    const stopped = new Promise(resolve => chromium.once('exit', resolve));
    chromium.kill('SIGTERM'); await stopped;
    await rm(profile, { recursive: true, force: true });
  }
}
export async function until(check, message, attempts = 150) {
  for (let n = 0; n < attempts; n++) {
    if (await check()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out: ${message}`);
}
