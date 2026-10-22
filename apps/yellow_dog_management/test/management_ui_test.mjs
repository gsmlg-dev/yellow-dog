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
    window: new EventTarget(),
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
    EditorGuard: { hasNewerInput: () => false },
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
  return Object.assign(new EventTarget(), { id, dataset, scrollTop: 0, querySelector: () => null });
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


test('PreserveScroll targets the nested scroll container using capture and removes that listener', () => {
  const { hooks, storage, renderFrame } = browser();
  const nested = { scrollTop: 0 };
  const el = element('outer', { scrollKey: 'nested', scrollTarget: '[data-scroll-target]' });
  let listener, removed;
  el.querySelector = selector => { assert.equal(selector, '[data-scroll-target]'); return nested; };
  el.addEventListener = (name, callback, options) => {
    assert.equal(name, 'scroll'); assert.equal(options.capture, true); listener = callback;
  };
  el.removeEventListener = (name, callback, options) => {
    assert.equal(name, 'scroll'); assert.equal(callback, listener); assert.equal(options.capture, true); removed = true;
  };
  storage.set('yellow-dog:nested:scroll-top', '72');
  const { instance } = mount(hooks.PreserveScroll, el);
  renderFrame();
  assert.equal(nested.scrollTop, 72);
  assert.equal(el.scrollTop, 0);
  nested.scrollTop = 101;
  listener();
  assert.equal(storage.get('yellow-dog:nested:scroll-top'), '101');
  instance.beforeUpdate(); nested.scrollTop = 0; instance.updated(); renderFrame();
  assert.equal(nested.scrollTop, 101);
  instance.destroyed(); assert.equal(removed, true);
});

function nodeBrowser({ positions = true, navigation = true } = {}) {
  class Listeners extends EventTarget {
    added = [];
    active = new Map();
    addEventListener(name, callback, options) {
      this.added.push(name);
      if (!this.active.has(name)) this.active.set(name, new Set());
      this.active.get(name).add(callback);
      super.addEventListener(name, callback, options);
    }
    removeEventListener(name, callback, options) {
      this.active.get(name)?.delete(callback);
      super.removeEventListener(name, callback, options);
    }
  }
  const window = new Listeners();
  const document = Object.assign(new Listeners(), {
    querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
  });
  const entries = [
    'https://fixture/server/a/dashboard',
    'https://fixture/server/a/services/dns/edit',
    'https://fixture/server/a/targets',
  ];
  const location = { href: entries[0] };
  let index = 0;
  let domIndex = 0;
  let unsavedValue = '';
  const latePops = [];
  const pending = [];
  const traversalRequests = [];
  const dispatchPop = destination => {
    assert.ok(destination >= 0 && destination < entries.length);
    index = destination;
    location.href = entries[index];
    const event = new Event('popstate');
    Object.defineProperty(event, 'state', { value: history.state });
    window.dispatchEvent(event);
  };
  const enqueueTraversal = (destination, method) => {
    traversalRequests.push({ destination, method });
    if (method === 'navigation.traverseTo') {
      // A new Navigation API traversal supersedes unfinished older traversals.
      for (const previous of pending) {
        if (!previous.canceled && previous.method === method) {
          previous.canceled = true;
          previous.reject(new Error('Traversal superseded'));
        }
      }
    }
    let complete, reject;
    const committed = new Promise((resolve, fail) => { complete = resolve; reject = fail; });
    pending.push({ destination, method, complete, reject, canceled: false });
    return { committed, finished: committed };
  };
  const history = {
    get state() { return positions ? { position: index } : {}; },
    go(distance) { enqueueTraversal(index + distance, 'history.go'); },
  };
  if (navigation) {
    window.navigation = new Listeners();
    Object.defineProperty(window.navigation, 'currentEntry', {
      get: () => ({ index, key: `entry-${index}` }),
    });
    window.navigation.entries = () => entries.map((url, entryIndex) => ({
      url, index: entryIndex, key: `entry-${entryIndex}`,
    }));
    window.navigation.traverseTo = key => {
      assert.match(key, /^entry-[0-2]$/);
      return enqueueTraversal(Number(key.slice(-1)), 'navigation.traverseTo');
    };
  }
  const decisions = [];
  let prompts = 0;
  window.confirm = () => { prompts++; return decisions.shift() ?? false; };
  const { hooks } = browser({
    window, document, location, history,
    LiveSocket: class {
      constructor(path, socket, options) { Object.assign(this, { path, socket, options }); }
      connect() {
        // Model LiveView's real window listener: it observes the changed address
        // only if the earlier application guard allows the pop to propagate.
        window.addEventListener('popstate', () => {
          latePops.push(index);
          domIndex = index;
          unsavedValue = '';
          window.dispatchEvent(new Event('phx:navigate'));
        });
      }
    },
  });
  const el = element('node-workflow', { dirty: 'false', resetKey: 'basic' });
  const { instance } = mount(hooks.NodeWorkflow, el);
  const input = (owner = instance) => {
    unsavedValue = 'local unsaved port';
    owner.el.closest = () => true;
    owner.el.dispatchEvent(new Event('input'));
  };
  return {
    window, document, instance, el, location, entries, decisions, latePops, traversalRequests,
    get prompts() { return prompts; },
    get domIndex() { return domIndex; },
    get unsavedValue() { return unsavedValue; },
    get pending() { return pending.length; },
    input,
    commit(destination) {
      index = domIndex = destination;
      location.href = entries[index];
      window.dispatchEvent(new Event('phx:navigate'));
    },
    pop(destination) { if (destination !== index) dispatchPop(destination); },
    async flushRestoration() {
      await setImmediate();
      let remaining = 20;
      while (pending.length) {
        assert.ok(remaining-- > 0, 'Restoration entered a traversal loop');
        const traversal = pending.shift();
        if (!traversal.canceled) {
          // Traversing to the current entry resolves without another popstate.
          if (traversal.destination !== index) dispatchPop(traversal.destination);
          traversal.complete({ index, key: `entry-${index}` });
        }
        await setImmediate();
      }
    },
    remount() {
      return mount(hooks.NodeWorkflow, element('next-node-workflow', { dirty: 'false', resetKey: 'next' })).instance;
    },
  };
}

for (const positions of [true, false]) {
  test(`NodeWorkflow stops late LiveView pops and restores exact history after updated ordering (positions: ${positions})`, async () => {
    const b = nodeBrowser({ positions });
    assert.deepEqual(b.window.added.filter(name => name === 'popstate'), ['popstate', 'popstate']);
    assert.equal(b.window.active.get('popstate').size, 2, 'One application and one LiveView listener');
    assert.equal(b.window.active.get('phx:before-navigate')?.size ?? 0, 0);
    assert.equal(b.window.navigation.active.get('navigate')?.size ?? 0, 0);
    // The editor hook runs before LiveView commits the corresponding address.
    b.el.dataset.resetKey = 'service';
    b.instance.updated();
    assert.equal(b.instance.path, b.entries[0]);
    b.commit(1);
    assert.equal(b.instance.path, b.entries[1]);
    assert.equal(b.instance.entryKey, 'entry-1');
    b.input(); // No validation acknowledgement or polling diff has occurred.
    b.pop(0);
    assert.equal(b.location.href, b.entries[0], 'Native traversal changes the address before popstate');
    assert.deepEqual(b.latePops, [], 'Canceled pop reached LiveView');
    assert.equal(b.domIndex, 1);
    assert.equal(b.unsavedValue, 'local unsaved port');
    assert.equal(b.instance.path, b.entries[1]);
    await b.flushRestoration();
    assert.equal(b.location.href, b.entries[1]);
    assert.deepEqual(b.latePops, [], 'Restoring pop reached LiveView');
    assert.equal(b.domIndex, 1);
    assert.equal(b.unsavedValue, 'local unsaved port');
    assert.equal(b.instance.localDirty, true);
    assert.equal(b.prompts, 1);
    assert.deepEqual(b.entries, [
      'https://fixture/server/a/dashboard',
      'https://fixture/server/a/services/dns/edit',
      'https://fixture/server/a/targets',
    ], 'Cancellation must preserve the forward entry');
    b.decisions.push(true);
    b.pop(0);
    assert.equal(b.prompts, 2);
    assert.deepEqual(b.latePops, [0]);
    assert.equal(b.domIndex, 0);
    assert.equal(b.instance.localDirty, false);
    b.pop(1);
    assert.deepEqual(b.latePops, [0, 1]);
    assert.equal(b.location.href, b.entries[1]);
    assert.equal(b.prompts, 2, 'Accepted discard should clear editor intent once');
    b.instance.destroyed();
  });
}

test('NodeWorkflow suppresses repeated differing toolbar pops while exact-entry restoration is pending', async () => {
  const b = nodeBrowser({ positions: false });
  b.commit(1);
  b.input();
  b.pop(0);
  b.pop(2);
  b.pop(0);
  assert.equal(b.prompts, 1, 'Pending restoration must not prompt again');
  assert.deepEqual(b.latePops, []);
  assert.equal(b.instance.path, b.entries[1]);
  assert.equal(b.instance.entryKey, 'entry-1');
  assert.equal(b.domIndex, 1);
  assert.equal(b.unsavedValue, 'local unsaved port');
  b.instance.updated(); // A queued observation diff must not capture the transient URL.
  assert.equal(b.instance.path, b.entries[1]);
  assert.equal(b.instance.entryKey, 'entry-1');
  await b.flushRestoration();
  assert.ok(b.traversalRequests.length > 0);
  assert.ok(b.traversalRequests.every(request => request.destination === 1));
  assert.equal(b.location.href, b.entries[1]);
  assert.equal(b.instance.path, b.entries[1]);
  assert.deepEqual(b.latePops, []);
  assert.equal(b.domIndex, 1);
  assert.equal(b.unsavedValue, 'local unsaved port');
  assert.equal(b.instance.localDirty, true);
  assert.equal(b.prompts, 1, 'Restoring pops must not produce another discard prompt');
  b.decisions.push(true);
  b.pop(2);
  assert.deepEqual(b.latePops, [2]);
  assert.equal(b.instance.localDirty, false);
  b.instance.destroyed();
});

test('NodeWorkflow restores known numeric positions when Navigation API is unavailable', async () => {
  const b = nodeBrowser({ navigation: false });
  b.commit(1);
  b.input();
  b.pop(0);
  assert.deepEqual(b.latePops, []);
  await b.flushRestoration();
  assert.equal(b.location.href, b.entries[1]);
  assert.ok(b.traversalRequests.every(request => request.method === 'history.go' && request.destination === 1));
  assert.deepEqual(b.latePops, []);
  assert.equal(b.domIndex, 1);
  assert.equal(b.instance.localDirty, true);
  b.instance.destroyed();
});

test('NodeWorkflow old destruction preserves the remounted owner and detaches instance listeners', async () => {
  const b = nodeBrowser();
  b.commit(1);
  const replacement = b.remount();
  b.instance.destroyed();
  b.input();
  assert.equal(b.instance.localDirty, false, 'Destroyed input listener leaked');
  assert.equal(b.window.active.get('popstate').size, 2, 'Hook remount must not accumulate dispatchers');
  assert.equal(b.window.active.get('phx:navigate').size, 1);
  assert.equal(b.document.active.get('click').size, 1);
  assert.equal(b.document.active.get('change').size, 1);
  b.input(replacement);
  b.pop(0);
  assert.deepEqual(b.latePops, []);
  await b.flushRestoration();
  assert.equal(b.location.href, b.entries[1]);
  assert.equal(b.domIndex, 1);
  assert.equal(replacement.localDirty, true);
  const blockedUnload = new Event('beforeunload', { cancelable: true });
  b.window.dispatchEvent(blockedUnload);
  assert.equal(blockedUnload.defaultPrevented, true);
  replacement.destroyed();
  replacement.localDirty = false;
  b.input(replacement);
  assert.equal(replacement.localDirty, false, 'Destroyed replacement input listener leaked');
  const allowedUnload = new Event('beforeunload', { cancelable: true });
  b.window.dispatchEvent(allowedUnload);
  assert.equal(allowedUnload.defaultPrevented, false);
  assert.equal(b.window.active.get('phx:navigate').size, 0);
  assert.equal(b.document.active.get('click').size, 0);
  assert.equal(b.document.active.get('change').size, 0);
  assert.equal(b.window.active.get('beforeunload').size, 0);
  b.pop(2);
  assert.deepEqual(b.latePops, [2], 'Destroyed owner still intercepted navigation');
  assert.equal(replacement.path, b.entries[1], 'Destroyed navigation listener leaked');
});


test('TransientCredential erases all textarea representations offline, blocks copying, retires on reconnect and rejects queued resurrection', async () => {
  const field = { value: 'secret fixture', defaultValue: 'secret fixture', textContent: 'secret fixture' };
  const button = element('copy', { target: 'worker-bootstrap' });
  const el = element('worker-bootstrap-secret', { issuance: 'first-result' });
  field.closest = () => el.dataset.retired === 'true' ? el : null;
  el.querySelectorAll = selector => selector === 'textarea' ? [field] : [button];
  let copies = 0;
  const { hooks } = browser({
    document: { querySelector: () => ({ getAttribute: () => 'csrf-fixture' }), getElementById: () => field },
    navigator: { clipboard: {writeText: () => { copies++; return Promise.resolve(); }} },
  });
  const secret = mount(hooks.TransientCredential, el);
  mount(hooks.CopyToClipboard, button);
  secret.instance.updated();
  assert.equal(field.value, 'secret fixture', 'ordinary polling must retain the result');
  button.dispatchEvent(new Event('click')); await setImmediate();
  assert.equal(copies, 1);
  secret.instance.disconnected();
  for (const key of ['value', 'defaultValue', 'textContent']) assert.equal(field[key], '');
  assert.equal(button.disabled, true);
  button.dispatchEvent(new Event('click')); await setImmediate();
  assert.equal(copies, 1);
  field.value = field.defaultValue = field.textContent = 'queued old result';
  secret.instance.updated();
  assert.equal(field.value, ''); assert.equal(field.defaultValue, ''); assert.equal(field.textContent, '');
  secret.instance.reconnected();
  assert.equal(secret.events[0].name, 'retire_connection');
  assert.equal(secret.events[0].payload.id, 'first-result');
  // Replacing the hook during reconnect must retain its non-secret tombstone.
  field.value = field.defaultValue = field.textContent = 'queued old result';
  const remounted = mount(hooks.TransientCredential, el);
  assert.equal(field.value, '');
  assert.equal(remounted.events[0].name, 'retire_connection');
  // A fresh explicit issuance can still be displayed.
  el.dataset.issuance = 'second-result';
  el.dataset.retired = 'false'; button.disabled = false;
  field.value = 'new explicit result';
  remounted.instance.updated();
  assert.equal(field.value, 'new explicit result');
});
