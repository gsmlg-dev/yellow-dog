import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';

const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function credentialLifetime({ cdp, evaluate, until, base, resetIssued = false }) {
  // Keep secret material inside Chromium; only booleans and audit counts leave it.
  const resetCount = () => evaluate(`(async () => {
    const html = await (await fetch('/management/events')).text();
    return new DOMParser().parseFromString(html, 'text/html').querySelectorAll('[data-operation="rotate_worker_token"]').length;
  })()`);
  const path = await evaluate('location.pathname');
  const before = await resetCount();
  if (resetIssued) assert.ok(before > 0, 'Explicit reset audit record missing before disconnect');
  await evaluate(`(async () => {
    const text = document.querySelector('#worker-bootstrap').value;
    window.nodeBootstrapDigest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))).join(',');
  })()`);
  await delay(5200);
  const pollingRetained = await evaluate(`(async () => {
    const field = document.querySelector('#worker-bootstrap');
    return !!field && Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(field.value)))).join(',') === window.nodeBootstrapDigest;
  })()`);
  await cdp('Browser.grantPermissions', { origin: base, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  await evaluate(`navigator.clipboard.writeText('node-workflow-no-secret')`);
  await evaluate('window.liveSocket.disconnect()');
  await until(() => evaluate('!window.liveSocket.isConnected()'), 'LiveView socket did not disconnect');
  const erasedOffline = await evaluate(`(() => {
    const field = document.querySelector('#worker-bootstrap');
    return !field || (field.value === '' && field.defaultValue === '' && field.textContent === '');
  })()`);
  const copyDisabled = await evaluate(`!document.querySelector('#worker-bootstrap-copy') || document.querySelector('#worker-bootstrap-copy').disabled`);
  await evaluate(`document.querySelector('#worker-bootstrap-copy')?.click()`);
  await delay(100);
  const cannotCopyOffline = await evaluate(`(async () => (await navigator.clipboard.readText()) === 'node-workflow-no-secret')()`);
  await evaluate('window.liveSocket.connect()');
  await until(() => evaluate('window.liveSocket.isConnected() && !!document.querySelector(".phx-connected")'), 'LiveView socket did not reconnect');
  await delay(5200);
  assert.equal(await evaluate('location.pathname'), path, 'Reconnect changed the credential operation scope');
  const notRestored = await evaluate(`!document.querySelector('#worker-bootstrap') || document.querySelector('#worker-bootstrap').value === ''`);
  const after = await resetCount();
  await evaluate('delete window.nodeBootstrapDigest');
  assert.deepEqual({ pollingRetained, erasedOffline, copyDisabled, cannotCopyOffline, notRestored, noRotation: after === before }, {
    pollingRetained: true, erasedOffline: true, copyDisabled: true, cannotCopyOffline: true, notRestored: true, noRotation: true,
  }, 'Transient bootstrap lifetime across real socket disconnect/reconnect');
  console.log('PASS credential lifetime: polling retained, offline DOM/default text/copy erased, reconnect retired, no extra reset audit');
}

async function dirtyHistory({ cdp, evaluate, navigate, until, confirmNext, worker, service }) {
  const basic = `/server/${worker}/dashboard`;
  const editor = `/server/${worker}/services/${service}/edit`;
  const target = `/server/${worker}/targets`;
  await navigate(basic);
  // The public navigation event runs after history commits, immediately after the
  // editor hook update. Delay validation acknowledgment, then traverse in that turn.
  await evaluate(`document.querySelector('#worker-tabs a[href="/server/${worker}/services"]').click()`);
  // Services is an intermediate patch; install the timing probe for the actual editor.
  await until(() => evaluate(`location.pathname === '/server/${worker}/services'`), 'Services patch failed');
  confirmNext(false);
  await evaluate(`(() => {
    window.nodeHistoryProbe = null;
    window.addEventListener('phx:navigate', () => {
      if (location.pathname !== '${editor}') return;
      window.liveSocket.enableLatencySim(1200);
      window.nodeHistoryProbe = { length: history.length, key: navigation.currentEntry.key };
      const field = document.querySelector('[name="service[port]"]');
      field.value = '15456';
      field.dispatchEvent(new Event('input', { bubbles: true }));
      history.back();
    }, { once: true });
    document.querySelector('#dns-services a[href="${editor}"]').click();
  })()`);
  await until(() => evaluate('window.nodeHistoryProbe !== null'), 'Editor timing probe did not run');
  await delay(300);
  assert.deepEqual(await evaluate(`({
    address: location.pathname === '${editor}',
    scope: document.querySelector('#server-selection-form-select').value === '${worker}' && !!document.querySelector('[name="service[id]"][readonly]'),
    value: document.querySelector('[name="service[port]"]')?.value === '15456',
    entry: navigation.currentEntry.key === window.nodeHistoryProbe.key,
    length: history.length === window.nodeHistoryProbe.length,
  })`), { address: true, scope: true, value: true, entry: true, length: true }, 'Cancelled immediate dirty Back retains address, editor, value and history');
  const cancelledBackHistory = await cdp('Page.getNavigationHistory');
  assert.ok(cancelledBackHistory.currentIndex > 0, 'Browser Back cancellation entry missing');
  confirmNext(false);
  await cdp('Page.navigateToHistoryEntry', { entryId: cancelledBackHistory.entries[cancelledBackHistory.currentIndex - 1].id });
  await delay(300);
  assert.deepEqual(await evaluate(`({
    address: location.pathname === '${editor}',
    scope: document.querySelector('#server-selection-form-select')?.value === '${worker}',
    value: document.querySelector('[name="service[port]"]')?.value === '15456',
    entry: navigation.currentEntry.key === window.nodeHistoryProbe.key,
    length: history.length === window.nodeHistoryProbe.length,
  })`), { address: true, scope: true, value: true, entry: true, length: true }, 'Cancelled browser Back retains address, editor, value and history');
  // Rapid repeated traversals must retain the same dirty editor and history entry.
  confirmNext([false, false]);
  await evaluate('history.back(); history.back()');
  await delay(300);
  assert.equal(await evaluate(`location.pathname === '${editor}' && document.querySelector('[name="service[port]"]')?.value === '15456' && navigation.currentEntry.key === window.nodeHistoryProbe.key`), true, 'Repeated Back escaped the dirty editor');
  await evaluate('window.liveSocket.disableLatencySim()');
  await delay(2600);
  confirmNext(true);
  const backHistory = await cdp('Page.getNavigationHistory');
  assert.ok(backHistory.currentIndex > 0, 'Browser Back entry missing after repeated cancellation');
  await cdp('Page.navigateToHistoryEntry', { entryId: backHistory.entries[backHistory.currentIndex - 1].id });
  await until(() => evaluate(`location.pathname === '/server/${worker}/services' && !document.querySelector('#service-form')`), 'Accepted Back failed');
  await evaluate('history.forward()');
  await until(() => evaluate(`location.pathname === '${editor}' && !!document.querySelector('#service-form')`), 'Cancelled traversal discarded the editor forward entry');
  assert.equal(await evaluate(`document.querySelector('[name="service[port]"]').value`), '15453', 'Discard was not limited to unsaved input');
  // Leave a forward target entry, remove LiveView positions, and verify
  // cancellation preserves the original entry without synthesizing history.
  await evaluate(`document.querySelector('#worker-tabs a[href="${target}"]').click()`);
  await until(() => evaluate(`location.pathname === '${target}'`), 'Target patch failed');
  await evaluate(`(() => {
    const state = {...history.state}; delete state.position; history.replaceState(state, '', location.href); history.back();
  })()`);
  await until(() => evaluate(`location.pathname === '${editor}' && !!document.querySelector('#service-form')`), 'Editor Back from target failed');
  await evaluate(`(() => {
    const state = {...history.state}; delete state.position; history.replaceState(state, '', location.href);
    window.nodeForwardProbe = { length: history.length, key: navigation.currentEntry.key };
    window.liveSocket.enableLatencySim(1200);
    const field = document.querySelector('[name="service[port]"]'); field.value = '15457'; field.dispatchEvent(new Event('input', {bubbles:true}));
  })()`);
  confirmNext(false);
  await evaluate('history.forward()');
  await delay(300);
  assert.equal(await evaluate(`location.pathname === '${editor}' && document.querySelector('#server-selection-form-select')?.value === '${worker}' && document.querySelector('[name="service[port]"]')?.value === '15457' && navigation.currentEntry.key === window.nodeForwardProbe.key && history.length === window.nodeForwardProbe.length`), true, 'Missing positions lost dirty Forward scope');
  const cancelledForwardHistory = await cdp('Page.getNavigationHistory');
  const cancelledTargetEntry = cancelledForwardHistory.entries.find((entry, index) => index > cancelledForwardHistory.currentIndex && new URL(entry.url).pathname === target);
  assert.ok(cancelledTargetEntry, 'Browser Forward cancellation entry missing');
  confirmNext(false);
  await cdp('Page.navigateToHistoryEntry', { entryId: cancelledTargetEntry.id });
  await delay(300);
  assert.deepEqual(await evaluate(`({
    address: location.pathname === '${editor}',
    scope: document.querySelector('#server-selection-form-select')?.value === '${worker}',
    value: document.querySelector('[name="service[port]"]')?.value === '15457',
    entry: navigation.currentEntry.key === window.nodeForwardProbe.key,
    length: history.length === window.nodeForwardProbe.length,
  })`), { address: true, scope: true, value: true, entry: true, length: true }, 'Cancelled browser Forward without positions retains address, editor, value and history');
  await evaluate('window.liveSocket.disableLatencySim()');
  await delay(2600);
  confirmNext(true);
  // Exercise the actual browser Forward action after the rejected traversal.
  const browserHistory = await cdp('Page.getNavigationHistory');
  const targetEntry = browserHistory.entries.find((entry, index) => index > browserHistory.currentIndex && new URL(entry.url).pathname === target);
  assert.ok(targetEntry, JSON.stringify({ finding: 'Browser target forward entry missing', currentIndex: browserHistory.currentIndex, targetIndices: browserHistory.entries.flatMap((entry, index) => new URL(entry.url).pathname === target ? [index] : []) }));
  await cdp('Page.navigateToHistoryEntry', { entryId: targetEntry.id });
  await delay(300);
  await until(() => evaluate(`location.pathname === '${target}' && !!document.querySelector('[phx-click="preview"]')`), 'Accepted Forward did not preserve the target entry');
  assert.equal(await evaluate('history.length === window.nodeForwardProbe.length'), true, 'Forward cancellation replaced browser history');
  await evaluate('delete window.nodeHistoryProbe; delete window.nodeForwardProbe');
  console.log('PASS history cancellation: immediate unacknowledged input, repeated Back, missing positions, Forward, retained address/scope/value and accepted discard');
}

export async function nodeWorkflowSmoke({ api, cdp, evaluate, navigate, until, submit, confirmNext, base, restart = false }) {
  const stateFile = process.env.MANAGEMENT_NODE_STATE_FILE;
  assert.ok(stateFile, 'Node scope requires a disposable state artifact path');
  if (restart) {
    const state = JSON.parse(await readFile(stateFile, 'utf8'));
    assert.deepEqual(await api(`/workers/${state.a}`), state.worker, 'Restart changed persisted configuration');
    assert.equal(await (await fetch(`${base}/api/workers/${state.a}/targets/1/export`)).text(), state.toml);
    await navigate(`/server/${state.a}/services/${state.service}/edit`);
    assert.equal(await evaluate(`document.querySelector('[name="service[port]"]').value`), '15455');
    await navigate(`/server/${state.a}/targets/1`);
    assert.equal(await evaluate(`!!document.querySelector('#selected-target')`), true);
    assert.equal(await evaluate(`!!document.querySelector('#worker-bootstrap')`), false);
    console.log('PASS fresh Chromium after Management restart: canonical service, assignments, immutable target and exact earlier TOML');
    return;
  }
  await navigate('/management/servers/enrollment');
  assert.equal(await evaluate(`!!document.querySelector('#worker-enrollment-form')`), true);
  await navigate('/management/servers');
  assert.equal(await evaluate(`!!document.querySelector('#worker-enrollment-form')`), false);
  await submit('#worker-form', { 'worker[name]': '   ' });
  await until(() => evaluate(`document.body.textContent.includes('Name must')`), 'Invalid registration not rejected');
  confirmNext(false);
  await evaluate(`document.querySelector('a[href="/management/servers/enrollment"]').click()`);
  await delay(300);
  assert.equal(await evaluate('location.pathname'), '/management/servers', 'Failed registration lost dirty guard');
  assert.equal(await evaluate(`document.querySelector('[name="worker[name]"]').value`), '   ');
  assert.deepEqual(await evaluate(`(() => {
    const expected = document.querySelector('#workers-workflow').dataset.resetKey.split(':')[0];
    const intent = document.querySelector('#worker-form [name="_submission"]');
    return { value: intent.value === expected, attribute: intent.getAttribute('value') === expected };
  })()`), { value: true, attribute: true }, 'Registration form must reflect the retired attempt intent');
  const ids = [];
  const reviewFailures = [];
  for (const name of ['Node Workflow A', 'Node Workflow B']) {
    await submit('#worker-form', { 'worker[name]': name });
    await until(() => evaluate(`!!document.querySelector('#worker-bootstrap')`), 'Registration result absent');
    let id;
    await until(async () => { id = (await api('/workers')).find(worker => worker.name === name)?.id; return !!id; }, 'Canonical registration missing');
    ids.push(id);
    const worker = await api(`/workers/${id}`);
    assert.deepEqual(worker.services, []);
    assert.deepEqual(worker.assignments, []);
    assert.deepEqual(await api(`/workers/${id}/targets`), []);
    // Credential text stays in Chromium; no token is returned to diagnostics/artifacts.
    assert.equal(await evaluate(`document.querySelector('#worker-bootstrap').value.includes('management_url = "${base}"')`), true);
    if (ids.length === 1) {
      try { await credentialLifetime({ cdp, evaluate, until, base }); }
      catch (error) { reviewFailures.push({ finding: 'R3', message: error.message }); }
    }
    if (await evaluate(`!!document.querySelector('[phx-click="dismiss_connection"]')`)) {
      await evaluate(`document.querySelector('[phx-click="dismiss_connection"]').click()`);
    }
    await until(() => evaluate(`!document.querySelector('#worker-bootstrap')`), 'Secret not dismissed');
  }
  const [a, b] = ids;
  for (const [id, port, desired] of [[a, '15453', 'running'], [b, '15454', 'stopped']]) {
    await navigate(`/server/${id}/services/new`);
    await submit('#service-form', { 'service[id]': 'dns', 'service[listen_address]': '127.0.0.1', 'service[port]': port, 'service[desired_state]': desired });
    await until(async () => (await api(`/workers/${id}`)).services.length === 1, 'DNS desired service missing');
    await until(() => evaluate(`document.querySelector('#node-workflow').dataset.dirty === 'false'`), 'Saved service remains dirty');
    await navigate(`/server/${id}/services`);
    assert.match(await evaluate(`document.querySelector('#dns-services').innerText`), new RegExp(desired));
    assert.deepEqual(await api(`/workers/${id}/targets`), []);
  }
  let worker = await api(`/workers/${a}`);
  const service = worker.services[0].id;
  const other = (await api(`/workers/${b}`)).services[0].id;
  assert.notEqual(service, other, 'DB identity cannot be instance label');
  try { await dirtyHistory({ cdp, evaluate, navigate, until, confirmNext, worker: a, service }); }
  catch (error) { reviewFailures.push({ finding: 'R1', message: error.message }); }
  console.log('Node review regression outcomes', JSON.stringify(reviewFailures));
  assert.deepEqual(reviewFailures, [], 'Node review regressions');
  await navigate(`/server/${a}/connection`);
  confirmNext(true);
  await evaluate(`document.querySelector('[phx-click="rotate_token"]').click()`);
  await until(() => evaluate(`!!document.querySelector('#worker-bootstrap')`), 'Reset bootstrap absent');
  await credentialLifetime({ cdp, evaluate, until, base, resetIssued: true });
  // A fresh explicit reset remains usable after retirement; changing tabs clears it.
  confirmNext(true);
  await evaluate(`document.querySelector('[phx-click="rotate_token"]').click()`);
  await until(() => evaluate(`!!document.querySelector('#worker-bootstrap')`), 'Explicit fresh reset absent');
  await evaluate(`document.querySelector('#worker-tabs a[href="/server/${a}/dashboard"]').click()`);
  await until(() => evaluate(`location.pathname === '/server/${a}/dashboard' && !document.querySelector('#worker-bootstrap')`), 'Tab navigation retained bootstrap');
  await evaluate(`document.querySelector('#worker-tabs a[href="/server/${a}/connection"]').click()`);
  await until(() => evaluate(`location.pathname === '/server/${a}/connection'`), 'Connection tab return failed');
  assert.equal(await evaluate(`!!document.querySelector('#worker-bootstrap')`), false, 'Returning to connection restored retired bootstrap');

  await cdp('Page.navigate', {url:`${base}/server/${a}/services/${other}/edit`});
  await until(() => evaluate(`location.pathname === '/server/${a}/services' && !!document.querySelector('.phx-connected')`), 'Cross-Worker edit did not reject scope');
  assert.equal(await evaluate(`!!document.querySelector('#service-form')`), false, 'Cross-Worker service editor exposed');
  await navigate(`/server/${a}/dashboard`);
  confirmNext(false);
  await evaluate(`(() => { const field = document.querySelector('[name="worker[name]"]'); field.value = 'Retain rapid input'; field.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('#worker-tabs a[aria-current="page"]').click(); })()`);
  assert.equal(await evaluate(`document.querySelector('[name="worker[name]"]').value`), 'Retain rapid input', 'Active tab discarded rapid input');
  await submit('#worker-edit-form', { 'worker[name]': 'Node Workflow A saved', 'worker[profile_name]': 'custom' });
  await until(async () => (await api(`/workers/${a}`)).name === 'Node Workflow A saved', 'Metadata not saved');
  assert.deepEqual((await api(`/workers/${a}`)).services, worker.services, 'Profile enabled/replaced services');
  await navigate(`/server/${a}/services/${service}/edit`);
  await evaluate(`(() => { const field = document.querySelector('[name="service[port]"]'); field.value = '15455'; field.dispatchEvent(new Event('input', {bubbles:true})); })()`);
  await until(() => evaluate(`document.querySelector('#node-workflow').dataset.dirty === 'true'`), 'Form not dirty');
  confirmNext(false);
  await evaluate(`document.querySelector('a[href="/server/${a}/targets"]').click()`);
  assert.equal(await evaluate('location.pathname'), `/server/${a}/services/${service}/edit`, 'Cancelled discard navigated');
  confirmNext(false);
  await evaluate(`(() => {const select = document.querySelector('#server-selection-form-select'); select.value = '${b}'; select.dispatchEvent(new Event('change', {bubbles:true}));})()`);
  assert.equal(await evaluate(`document.querySelector('#server-selection-form-select').value`), a, 'Cancelled Worker selection changed scope');
  await new Promise(resolve => setTimeout(resolve, 5200));
  assert.equal(await evaluate(`document.querySelector('[name="service[port]"]').value`), '15455', 'Polling discarded input');
  await submit('#service-form', { 'service[port]': '15455' });
  await until(async () => (await api(`/workers/${a}`)).services[0].config.port === 15455, 'Edit did not persist');
  await until(() => evaluate(`document.querySelector('#node-workflow').dataset.dirty === 'false'`), 'Save not canonical');
  await evaluate(`document.querySelector('#worker-tabs a[href="/server/${a}/targets"]').click()`);
  await until(() => evaluate(`location.pathname === '/server/${a}/targets'`), 'Target tab navigation failed');
  await evaluate('history.back()');
  await until(() => evaluate(`location.pathname === '/server/${a}/services/${service}/edit' && !!document.querySelector('#service-form')`), 'Node browser back failed');
  await evaluate('history.forward()');
  await until(() => evaluate(`location.pathname === '/server/${a}/targets' && !!document.querySelector('[phx-click="preview"]')`), 'Node browser forward failed');
  // Use existing Data editor for create, confirm and assignment.
  await navigate('/management/zones/new');
  await evaluate(`document.querySelector('[phx-click="add_record"]').click()`);
  await until(() => evaluate(`!!document.querySelector('[name="zone[records][2][data][address]"]')`), 'A record row missing');
  await submit('#zone-form', {
    'zone[name]': 'node.test.', 'zone[records][0][name]': 'node.test.',
    'zone[records][0][data][mname]': 'ns.node.test.', 'zone[records][0][data][rname]': 'hostmaster.node.test.',
    'zone[records][1][name]': 'node.test.', 'zone[records][1][data][host]': 'ns.node.test.',
    'zone[records][2][name]': 'ns.node.test.', 'zone[records][2][data][address]': '192.0.2.10',
  });
  let zone;
  await until(async () => { zone = (await api('/zones')).find(item => item.name === 'node.test.'); return !!zone; }, 'Data Zone create failed');
  await until(() => evaluate(`location.pathname === '/management/zones/${zone.id}/edit' && document.querySelector('#zone-form')?.dataset.editorDirty === 'false'`), 'Data Zone save was not acknowledged in the editor');
  await navigate(`/management/zones/${zone.id}/edit`);
  await evaluate(`document.querySelector('[phx-click="confirm_zone"]').click()`);
  await until(async () => (await api(`/zones/${zone.id}/versions`)).length === 1, 'Data version confirmation failed');
  await evaluate(`document.querySelector('[phx-click="add_assignment_worker"][phx-value-id="${a}"]').click()`);
  await until(() => evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 1`), 'Assignment row missing');
  await evaluate(`document.querySelector('#zone-assignments-form').requestSubmit()`);
  await until(async () => (await api(`/workers/${a}`)).assignments.length === 1, 'Data assignment failed');
  await until(() => evaluate(`document.querySelector('#zone-assignments-form')?.dataset.editorDirty === 'false'`), 'Data assignment save was not acknowledged in the editor');
  await navigate(`/server/${a}/services/${service}/edit`);
  assert.match(await evaluate(`document.querySelector('#service-references').innerText`), /node\.test\./);
  assert.equal(await evaluate(`!!document.querySelector('#assignment-form')`), false);
  await navigate(`/server/${b}/services/${other}/edit`);
  assert.equal(await evaluate(`document.querySelector('#service-references').innerText.includes('node.test.')`), false);
  await navigate(`/server/${a}/targets`);
  await evaluate(`document.querySelector('[phx-click="preview"]').click()`);
  await until(() => evaluate(`!!document.querySelector('#target-preview')`), 'Preview missing');
  confirmNext(true);
  await evaluate(`document.querySelector('[phx-click="confirm_target"]').click()`);
  await until(async () => (await api(`/workers/${a}/targets`))[0]?.revision === 1, 'Publication missing');
  const target = await api(`/workers/${a}/targets/1`);
  assert.equal(target.actual_state, 'unknown');
  assert.equal(target.status, 'prepared');
  const toml = await (await fetch(`${base}/api/workers/${a}/targets/1/export`)).text();
  assert.match(toml, /node\.test\./);
  await evaluate(`document.querySelector('[phx-click="preview"]').click()`);
  await until(() => evaluate(`!!document.querySelector('#target-preview')`), 'Second preview missing');
  worker = await api(`/workers/${a}`);
  await api('/commands/update_service', {worker_id:a, service_id:service, instance_id:'dns', expected_revision:worker.revision, type:'dns', desired_state:'stopped', config:{listen_address:'127.0.0.1',port:15455}});
  confirmNext(true);
  await evaluate(`document.querySelector('[phx-click="confirm_target"]').click()`);
  await until(() => evaluate(`document.body.textContent.includes('revision') && !!document.querySelector('[role="alert"]')`), 'Stale preview not rejected');
  assert.equal((await api(`/workers/${a}/targets`))[0].revision, 1);
  await evaluate(`document.querySelector('[phx-click="preview"]').click()`);
  await until(() => evaluate(`document.querySelector('#target-preview')?.textContent.includes('stopped')`), 'Fresh preview missing');
  confirmNext(true);
  await evaluate(`document.querySelector('[phx-click="confirm_target"]').click()`);
  await until(async () => (await api(`/workers/${a}/targets`))[0]?.revision === 2, 'Fresh publication missing');
  assert.equal(await (await fetch(`${base}/api/workers/${a}/targets/1/export`)).text(), toml);
  await navigate(`/server/${a}/targets/1`);
  assert.equal(await evaluate(`!!document.querySelector('a[href="/api/workers/${a}/targets/1/export"]')`), true);
  if (process.env.MANAGEMENT_SCREENSHOT_PREFIX) {
    const desktop = await cdp('Page.captureScreenshot', {format:'png'});
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-node-desktop.png`, Buffer.from(desktop.data,'base64'));
    await cdp('Emulation.setDeviceMetricsOverride', {width:390,height:844,deviceScaleFactor:1,mobile:true});
    await navigate(`/server/${a}/services`);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Node mobile overflow');
    assert.equal(await evaluate(`document.querySelector('#dns-services').getBoundingClientRect().width >= 640 && document.querySelector('#dns-services').parentElement.scrollWidth > document.querySelector('#dns-services').parentElement.clientWidth`), true, 'Mobile service table must scroll with readable columns');
    await evaluate(`document.querySelector('#worker-tabs a[href="/server/${a}/dashboard"]').click()`);
    await until(() => evaluate(`location.pathname === '/server/${a}/dashboard' && !!document.querySelector('#worker-edit-form')`), 'Mobile Basic tab failed');
    await evaluate(`document.querySelector('#worker-tabs a[href="/server/${a}/services"]').click()`);
    await until(() => evaluate(`location.pathname === '/server/${a}/services' && !!document.querySelector('#dns-services')`), 'Mobile Services tab failed');
    const mobile = await cdp('Page.captureScreenshot', {format:'png'});
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-node-mobile.png`, Buffer.from(mobile.data,'base64'));
  }
  await writeFile(stateFile, JSON.stringify({a,b,service,worker:await api(`/workers/${a}`),toml}));
  console.log('PASS Chromium node workflow: two registrations, offline DNS edit, stop/start desired state, dirty polling/discard, Data create/confirm/assign, scoped references, stale preview rejection, immutable historical export, desktop/mobile');
}
