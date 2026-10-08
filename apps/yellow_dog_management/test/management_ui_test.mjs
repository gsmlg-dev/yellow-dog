import assert from 'node:assert/strict';
import { Blob } from 'node:buffer';
import { readFileSync } from 'node:fs';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import vm from 'node:vm';

// Execute the current entry point with browser/package boundaries stubbed. CI's
// Node-only job has no Hex dependencies or DOM, and needs no import loader flags.
const source = readFileSync(new URL('../assets/app.js', import.meta.url), 'utf8')
  .replace(/^import .*;\r?$/gm, '');

function browser(overrides = {}) {
  const frames = [];
  const storage = new Map();
  const errors = [];
  const context = vm.createContext({
    window: {},
    document: {
      documentElement: { setAttribute() {} },
      querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
    },
    localStorage: { getItem: () => null },
    sessionStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
    },
    requestAnimationFrame: callback => frames.push(callback),
    navigator: {},
    Blob,
    URL,
    console: { error: (...args) => errors.push(args) },
    Socket: class {},
    LiveSocket: class {
      constructor(path, socket, options) {
        Object.assign(this, { path, socket, options });
      }
      connect() { this.connected = true; }
    },
    DuskmoonHooks: { PackageHook: {} },
    ...overrides,
  });
  new vm.Script(source, { filename: 'assets/app.js' }).runInContext(context);

  return {
    hooks: context.window.liveSocket.options.hooks,
    socket: context.window.liveSocket,
    storage,
    errors,
    renderFrame() {
      for (const callback of frames.splice(0)) callback();
    },
  };
}

function mount(hook, el) {
  const handlers = new Map();
  const events = [];
  const instance = {
    ...hook,
    el,
    handleEvent: (name, callback) => handlers.set(name, callback),
    pushEvent: (name, payload) => events.push({ name, payload }),
  };
  instance.mounted();
  return { instance, events, send: (name, payload) => handlers.get(name)(payload) };
}

function element(id, dataset = {}) {
  return Object.assign(new EventTarget(), { id, dataset, scrollTop: 0 });
}

test('entry point connects LiveView with CSRF and package/custom hooks', () => {
  const { socket, hooks } = browser();
  assert.equal(socket.path, '/live');
  assert.equal(socket.connected, true);
  assert.equal(socket.options.params._csrf_token, 'csrf-fixture');
  assert.ok(hooks.PackageHook);
  assert.equal(typeof hooks.ResetForm.mounted, 'function');
});

test('ResetForm resets only the requested form and updates named fields', () => {
  const { hooks } = browser();
  const name = { value: 'typed' };
  const identity = { value: 'previous-id' };
  const fields = new Map([['worker[name]', name], ['id', identity]]);
  let resets = 0;
  const { send } = mount(hooks.ResetForm, {
    id: 'worker-form',
    reset: () => { resets++; },
    elements: { namedItem: key => fields.get(key) },
  });
  send('reset_form', { id: 'other-form' });
  send('set_form_values', { id: 'other-form', values: { id: 'wrong' } });
  assert.equal(resets, 0);
  assert.equal(identity.value, 'previous-id');
  send('reset_form', { id: 'worker-form' });
  assert.equal(resets, 1);
  send('set_form_values', {
    id: 'worker-form',
    values: { 'worker[name]': 'saved', id: '', missing: 'ignored' },
  });
  assert.equal(name.value, 'saved');
  assert.equal(identity.value, '');
});

test('clipboard acknowledges only after the requested content is copied', async () => {
  let complete;
  const copied = [];
  const { hooks } = browser({
    document: {
      querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
      getElementById: id => id === 'export' ? { textContent: 'exact\nTOML bytes' } : null,
    },
    navigator: {
      clipboard: {
        writeText: text => {
          copied.push(text);
          return new Promise(resolve => { complete = resolve; });
        },
      },
    },
  });
  const button = element('copy', { target: 'export' });
  const { events } = mount(hooks.CopyToClipboard, button);
  button.dispatchEvent(new Event('click'));
  assert.deepEqual(copied, ['exact\nTOML bytes']);
  assert.equal(events.length, 0);
  complete();
  await setImmediate();
  assert.equal(events.length, 1);
  assert.equal(events[0].name, 'copied');
  assert.equal(events[0].payload.target, 'export');
});

test('clipboard rejection reports failure without claiming copied', async () => {
  const { hooks, errors } = browser({
    document: {
      querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
      getElementById: () => ({ innerText: 'fallback text' }),
    },
    navigator: { clipboard: { writeText: () => Promise.reject(new Error('Permission denied')) } },
  });
  const button = element('copy', { target: 'export' });
  const { events } = mount(hooks.CopyToClipboard, button);
  button.dispatchEvent(new Event('click'));
  await setImmediate();
  assert.equal(events.length, 1);
  assert.equal(events[0].name, 'copy_failed');
  assert.equal(events[0].payload.target, 'export');
  assert.equal(events[0].payload.error, 'Permission denied');
  assert.equal(errors.length, 1);
});

test('missing clipboard target neither writes nor emits success', () => {
  const { hooks, errors } = browser({
    document: {
      querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
      getElementById: () => null,
    },
    navigator: { clipboard: { writeText: () => assert.fail('Missing target was copied') } },
  });
  const button = element('copy', { target: 'missing' });
  const { events } = mount(hooks.CopyToClipboard, button);
  button.dispatchEvent(new Event('click'));
  assert.equal(events.length, 0);
  assert.equal(errors.length, 1);
});

for (const [hook, event, filename, type, content] of [
  ['CsvDownload', 'download_csv', 'views.csv', 'text/csv;charset=utf-8;', 'Name,Status\r\noffice,Active\r\n'],
  ['TextDownload', 'download_text', 'zone.txt', 'text/plain;charset=utf-8;', 'example.test. IN TXT "你好"\n'],
]) {
  test(`${hook} downloads exact bytes and releases its link and object URL`, async () => {
    const active = new Set();
    const links = [];
    const revoked = [];
    let blob;
    const { hooks } = browser({
      document: {
        querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
        createElement: tag => {
          assert.equal(tag, 'a');
          const attributes = new Map();
          const link = {
            setAttribute: (name, value) => attributes.set(name, value),
            click() {
              assert.ok(active.has(link), 'Download link must be attached when clicked');
              assert.equal(attributes.get('href'), 'blob:fixture');
              assert.equal(attributes.get('download'), filename);
              this.clicked = true;
            },
          };
          links.push(link);
          return link;
        },
        body: {
          appendChild: link => active.add(link),
          removeChild: link => assert.ok(active.delete(link)),
        },
      },
      URL: {
        createObjectURL: value => { blob = value; return 'blob:fixture'; },
        revokeObjectURL: value => revoked.push(value),
      },
    });
    const { send } = mount(hooks[hook], element('download'));
    send(event, { content, filename });
    assert.equal(blob.type, type);
    assert.equal(await blob.text(), content);
    assert.equal(links.length, 1);
    assert.equal(links[0].clicked, true);
    assert.equal(active.size, 0);
    assert.deepEqual(revoked, ['blob:fixture']);
  });
}

test('PreserveScroll saves and restores across updates and detaches on destruction', () => {
  const { hooks, storage, renderFrame } = browser();
  storage.set('yellow-dog:sidebar:scroll-top', '125');
  const el = element('navigation', { scrollKey: 'sidebar' });
  const { instance } = mount(hooks.PreserveScroll, el);
  assert.equal(el.scrollTop, 0);
  renderFrame();
  assert.equal(el.scrollTop, 125);
  el.scrollTop = 260;
  el.dispatchEvent(new Event('scroll'));
  assert.equal(storage.get('yellow-dog:sidebar:scroll-top'), '260');
  el.scrollTop = 310;
  instance.beforeUpdate();
  el.scrollTop = 0;
  instance.updated();
  renderFrame();
  assert.equal(el.scrollTop, 310);
  el.scrollTop = 415;
  instance.destroyed();
  assert.equal(storage.get('yellow-dog:sidebar:scroll-top'), '415');
  el.scrollTop = 999;
  el.dispatchEvent(new Event('scroll'));
  assert.equal(storage.get('yellow-dog:sidebar:scroll-top'), '415');
});

test('PreserveScroll isolates element identities and ignores invalid stored positions', () => {
  const { hooks, storage, renderFrame } = browser();
  storage.set('yellow-dog:first:scroll-top', '44');
  storage.set('yellow-dog:second:scroll-top', 'invalid');
  const first = element('first');
  const second = element('second');
  second.scrollTop = 17;
  const left = mount(hooks.PreserveScroll, first);
  const right = mount(hooks.PreserveScroll, second);
  renderFrame();
  assert.equal(first.scrollTop, 44);
  assert.equal(second.scrollTop, 17);
  left.instance.destroyed();
  right.instance.destroyed();
});

test('PreserveScroll remains usable when browser storage is unavailable', () => {
  const { hooks, renderFrame } = browser({
    sessionStorage: {
      getItem: () => { throw new Error('Storage disabled'); },
      setItem: () => { throw new Error('Storage disabled'); },
    },
  });
  const el = element('navigation');
  el.scrollTop = 35;
  const { instance } = mount(hooks.PreserveScroll, el);
  renderFrame();
  el.dispatchEvent(new Event('scroll'));
  instance.beforeUpdate();
  instance.updated();
  renderFrame();
  instance.destroyed();
  assert.equal(el.scrollTop, 35);
});
