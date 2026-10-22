import assert from 'node:assert/strict';
import test from 'node:test';
import EditorGuard from '../assets/editor_guard.js';

function element(id, dataset = {}) {
  return Object.assign(new EventTarget(), { id, dataset });
}

function mount(hook, el) {
  const instance = { ...hook, el };
  instance.mounted();
  return { instance };
}

function editorGuard({ positions = true, navigation = true } = {}) {
  const document = Object.assign(new EventTarget(), {
    querySelector: () => ({ getAttribute: () => 'csrf-fixture' }),
  });
  const window = Object.assign(new EventTarget(), { confirm: () => false });
  const location = new URL('http://localhost/management/zones');
  const entries = [location.href, `${location.href}/zone/edit`, `${location.href}/zone/versions`];
  let index = 0;
  const pending = [];
  const latePops = [];
  const pop = destination => {
    if (destination === index) return;
    index = destination;
    location.href = entries[index];
    window.dispatchEvent(new Event('popstate'));
  };
  const traverse = destination => {
    let resolve;
    const finished = new Promise(done => { resolve = done; });
    pending.push(() => { pop(destination); resolve(); });
    return {finished};
  };
  const history = {
    get state() { return positions ? { position: index } : {}; },
    go(distance) { traverse(index + distance); },
  };
  if (navigation) window.navigation = {
    get currentEntry() { return { index, key:`entry-${index}` }; },
    traverseTo(key) { return traverse(Number(key.slice(-1))); },
  };
  Object.assign(globalThis, { document, window, location, history });
  const content = element('content', { editor: 'true', editorDirty: 'false', editorReset: 'content-1' });
  const assignment = element('assignments', { editor: 'true', editorDirty: 'false', editorReset: 'assignment-1' });
  const forms = [content, assignment];
  const wrapper = element('workflow');
  wrapper.querySelectorAll = () => forms;
  wrapper.contains = form => forms.includes(form);
  const { instance } = mount(EditorGuard, wrapper);
  window.addEventListener('popstate', () => {
    latePops.push(index);
    window.dispatchEvent(new Event('phx:navigate'));
  });
  const input = form => instance.onInput({ target: { closest: () => form } });
  return { instance, input, content, assignment, forms, window, document, location, entries, latePops,
    commit(destination) {
      index = destination;
      location.href = entries[index];
      window.dispatchEvent(new Event('phx:navigate'));
    },
    pop,
    flushRestoration() {
      let remaining = 20;
      while (pending.length) {
        assert.ok(remaining-- > 0, 'Editor restoration loop');
        pending.shift()();
      }
    },
  };
}

test('EditorGuard protects unacknowledged input across clean server patches', () => {
  const { instance, input, content } = editorGuard();
  input(content);
  instance.updated();
  assert.equal(instance.allowLeave(), false);
  content.dataset.editorDirty = 'true';
  instance.updated();
  content.dataset.editorDirty = 'false';
  instance.updated();
  assert.equal(instance.allowLeave(), false, 'A stale clean patch must not acknowledge local edits');
  instance.destroyed();
});

test('EditorGuard resets each editor independently only after explicit reset', () => {
  const { instance, input, content, assignment } = editorGuard();
  input(content);
  input(assignment);
  content.dataset.editorReset = 'content-2';
  instance.updated();
  assert.equal(instance.allowLeave(), false, 'Content save must not discard assignments');
  assignment.dataset.editorReset = 'assignment-2';
  instance.updated();
  assert.equal(instance.allowLeave(), true);
  instance.destroyed();
});

test('EditorGuard keeps edits made after a submitted snapshot dirty', () => {
  const { instance, input, content } = editorGuard();
  input(content);
  instance.onSubmit({ target: content });
  assert.equal(EditorGuard.hasNewerInput(content), false);
  input(content);
  assert.equal(EditorGuard.hasNewerInput(content), true);
  content.dataset.editorReset = 'content-2';
  instance.updated();
  assert.equal(instance.allowLeave(), false);
  assert.equal(EditorGuard.hasNewerInput(content), true, 'DOM reset protection must survive the patch');
  instance.destroyed();
});

test('EditorGuard can acknowledge a source editor from its separate commit form', () => {
  const { instance, input, content } = editorGuard();
  input(content);
  instance.onSubmit({ target: { id: 'commit', dataset: { editorSubmit: 'content' } } });
  content.dataset.editorReset = 'content-2';
  instance.updated();
  assert.equal(instance.dirty('content'), false);
  instance.destroyed();
});

test('EditorGuard blocks destructive actions and restores a cancelled scope selector', () => {
  const { instance, input, content } = editorGuard();
  input(content);
  let stopped = 0;
  const button = { dataset: { editorDiscard: 'true' } };
  instance.onClick({
    target: { closest: selector => selector.includes('data-editor-discard') ? button : null },
    preventDefault: () => { stopped++; },
    stopImmediatePropagation: () => { stopped++; },
  });
  const selector = { value: 'new-scope', matches: () => true, querySelector: () => ({ value: 'old-scope' }) };
  instance.onSelection({ target: selector, stopImmediatePropagation: () => { stopped++; } });
  assert.equal(selector.value, 'old-scope');
  assert.equal(stopped, 3);
  instance.destroyed();
});

test('EditorGuard refuses confirmation of rapid unsaved content and permits preserved tabs', () => {
  const { instance, input, content, window } = editorGuard();
  input(content);
  let message;
  window.alert = text => { message = text; };
  let stopped = 0;
  instance.onClick({
    target: { closest: selector => selector === '[data-editor-confirm]' ? { dataset: { editorConfirm: 'content' } } : null },
    preventDefault: () => { stopped++; }, stopImmediatePropagation: () => { stopped++; },
  });
  assert.match(message, /Save or explicitly discard/);
  assert.equal(stopped, 2);
  instance.onClick({
    target: { closest: selector => selector.includes('data-editor-discard') ? { dataset: { editorPreserve: 'true' } } : null },
    preventDefault: () => assert.fail('Preserved tab blocked'),
    stopImmediatePropagation: () => assert.fail('Preserved tab stopped'),
  });
  assert.equal(instance.allowLeave(), false);
  instance.destroyed();
});

test('EditorGuard explicit discard clears only the requested editor', () => {
  const { instance, input, content, assignment, window } = editorGuard();
  input(content);
  input(assignment);
  window.confirm = () => true;
  const action = { dataset: { editorDiscard: 'content' } };
  instance.onClick({ target: { closest: selector => selector.includes('data-editor-discard') ? action : null } });
  assert.equal(instance.dirty('content'), false);
  assert.equal(instance.dirty('assignments'), true);
  instance.destroyed();
});

test('EditorGuard marks approved button scope changes for server fallback', () => {
  const { instance, input, content, window } = editorGuard();
  input(content);
  window.confirm = () => true;
  const attributes = new Map();
  const action = { dataset: { editorNavigation: 'true' }, setAttribute: (name, value) => attributes.set(name, value) };
  instance.onClick({ target: { closest: selector => selector.includes('data-editor-discard') ? action : null } });
  assert.equal(attributes.get('phx-value-_discard'), 'true');
  instance.destroyed();
});

test('EditorGuard scope discard approval is explicit and does not prompt twice', () => {
  const { instance, input, content, window } = editorGuard();
  input(content);
  let prompts = 0;
  window.confirm = () => { prompts++; return true; };
  const acknowledgment = { value: 'false' };
  const selector = {
    value: 'new-scope', matches: () => true,
    form: { querySelector: () => acknowledgment },
  };
  instance.onSelection({ target: selector });
  assert.equal(acknowledgment.value, 'true');
  assert.equal(instance.allowLeave(), true);
  assert.equal(prompts, 1);
  instance.onSelection({ target: selector });
  assert.equal(acknowledgment.value, 'false', 'Clean navigation must not reuse discard authorization');
  instance.destroyed();
});

for (const options of [{positions:true}, {positions:false}, {positions:true,navigation:false}]) {
  test(`EditorGuard restores noncancelable Back/Forward to the committed editor (${JSON.stringify(options)})`, () => {
    const b = editorGuard(options);
    b.instance.updated();
    b.commit(1);
    b.input(b.content);
    b.pop(0);
    assert.deepEqual(b.latePops, [], 'Rejected pop must not reach LiveView');
    b.flushRestoration();
    assert.equal(b.location.href, b.entries[1]);
    b.pop(2);
    b.flushRestoration();
    assert.equal(b.location.href, b.entries[1]);
    assert.equal(b.instance.allowLeave(), false);
    b.window.confirm = () => true;
    b.pop(0);
    assert.equal(b.location.href, b.entries[0]);
    b.instance.destroyed();
    b.input(b.content);
    b.window.confirm = () => assert.fail('Navigation listener leaked');
    b.pop(2);
    assert.equal(b.location.href, b.entries[2]);
  });
}

test('EditorGuard suppresses repeated differing pops while exact-entry restoration is pending', () => {
  const b = editorGuard();
  b.commit(1);
  b.input(b.content);
  let prompts = 0;
  b.window.confirm = () => { prompts++; return false; };
  b.pop(0);
  b.pop(2);
  b.pop(0);
  b.flushRestoration();
  assert.equal(prompts, 1);
  assert.equal(b.location.href, b.entries[1]);
  assert.deepEqual(b.latePops, []);
  assert.equal(b.instance.dirty('content'), true);
  b.instance.destroyed();
});
