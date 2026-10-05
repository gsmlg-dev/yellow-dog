import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';

for (const variable of ['YELLOW_DOG_PHASE1_PG_DATA_DIR', 'YELLOW_DOG_PHASE1_PG_PORT', 'MANAGEMENT_UI_URL', 'MANAGEMENT_DNS_CATALOG_EVIDENCE', 'MANAGEMENT_DNS_CATALOG_BROWSER_PROFILE', 'MANAGEMENT_DNS_CATALOG_ZONE_ID', 'MANAGEMENT_DNS_CATALOG_OTHER_ZONE_ID']) assert.ok(process.env[variable], variable);
const base = new URL(process.env.MANAGEMENT_UI_URL);
assert.equal(base.hostname, '127.0.0.1');
const zoneId = process.env.MANAGEMENT_DNS_CATALOG_ZONE_ID;
const otherId = process.env.MANAGEMENT_DNS_CATALOG_OTHER_ZONE_ID;
const profile = process.env.MANAGEMENT_DNS_CATALOG_BROWSER_PROFILE;
const evidencePath = process.env.MANAGEMENT_DNS_CATALOG_EVIDENCE;
const downloads = join(dirname(evidencePath), 'downloads');
const verifyOnly = process.env.MANAGEMENT_DNS_CATALOG_VERIFY_ONLY === '1';
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const executeFile = promisify(execFile);
const pending = new Map();
const replies = new Map();
const events = [];
const dialogs = [];
const downloadStarts = [];
const downloadProgress = new Map();
const errors = [];
let nextDialogDecision = null;
let sequence = 0;
let socket;
let browser;

async function until(check, message) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    assert.deepEqual(errors, [], 'Browser errors');
    if (await check()) return;
    await delay(100);
  }
  throw new Error(message);
}

function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(method)); }, 10000);
    pending.set(id, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

async function evaluate(expression) {
  const result = await cdp('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function api(path, body) {
  const response = await fetch(new URL('/api' + path, base), {
    ...(body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() }, body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  return result.data;
}

async function navigate(path, selector) {
  await cdp('Page.navigate', { url: new URL(path, base).href });
  await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected') && !!document.querySelector(${JSON.stringify(selector)})`), 'LiveView did not connect: ' + path);
  assert.equal(await evaluate('document.querySelector("input[type=password], #login") === null'), true);
}

async function action(event, expression) {
  const start = events.length;
  await evaluate(expression);
  return acknowledgedSince(event, start);
}

async function acknowledgedSince(event, start) {
  let result;
  await until(() => {
    result = events.slice(start).find(item => item.event === event && replies.has(item.key));
    return !!result;
  }, 'Missing LiveView reply: ' + event);
  assert.equal(replies.get(result.key).status, 'ok');
  return result;
}

async function click(selector, event) {
  await action(event, `document.querySelector(${JSON.stringify(selector)}).click()`);
}

async function filter(formSelector, fields) {
  await action('filter', `(() => {
    const form = document.querySelector(${JSON.stringify(formSelector)});
    for (const [name, value] of Object.entries(${JSON.stringify(fields)})) form.elements.namedItem(name).value = value;
    form.requestSubmit();
  })()`);
}

async function submit(formSelector, fields, event) {
  await action(event, `(() => {
    const form = document.querySelector(${JSON.stringify(formSelector)});
    for (const [name, value] of Object.entries(${JSON.stringify(fields)})) form.elements.namedItem(name).value = value;
    form.requestSubmit();
  })()`);
}

async function previewBulk(records) {
  await action('preview_bulk', `(() => {
    const input = document.querySelector('#bulk-record-form textarea[name="bulk[records]"]');
    input.value = ${JSON.stringify(records)};
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
}

async function databaseSnapshot() {
  const options = {
    env: { ...process.env, PGHOST: '127.0.0.1', PGPORT: process.env.YELLOW_DOG_PHASE1_PG_PORT, PGUSER: 'postgres', PGDATABASE: 'yellow_dog_phase1', PGOPTIONS: '-c default_transaction_read_only=on' },
    timeout: 10000,
    maxBuffer: 16 * 1024 * 1024,
  };
  const catalog = await executeFile('psql', ['-XAt', '-v', 'ON_ERROR_STOP=1', '-c', "SELECT json_agg(json_build_array(schemaname, tablename) ORDER BY schemaname, tablename) FROM pg_tables WHERE schemaname IN ('public', 'management_jobs') AND tablename <> 'oban_peers'"], options);
  const tables = JSON.parse(catalog.stdout);
  assert.ok(Array.isArray(tables) && tables.length > 0, 'Missing disposable tables');
  const identifier = value => '"' + value.replaceAll('"', '""') + '"';
  const literal = value => "'" + value.replaceAll("'", "''") + "'";
  const rows = tables.map(([schema, table]) => `SELECT ${literal(schema + '.' + table)} AS name,
    (SELECT COALESCE(jsonb_agg(to_jsonb(stored) ORDER BY to_jsonb(stored)::text), '[]'::jsonb) FROM ${identifier(schema)}.${identifier(table)} AS stored) AS data`);
  const result = await executeFile('psql', ['-XAt', '-v', 'ON_ERROR_STOP=1', '-c', `SELECT jsonb_object_agg(name, data) FROM (${rows.join(' UNION ALL ')}) AS snapshots`], options);
  const snapshot = JSON.parse(result.stdout);
  assert.ok(snapshot['public.management_zones'] && snapshot['public.management_resource_versions'], 'Missing disposable business tables');
  return snapshot;
}

async function zoneFormValues() {
  return evaluate(`Object.fromEntries(Array.from(document.querySelector('#zone-form').elements)
    .filter(input => input.name.startsWith('zone[')).map(input => [input.name, input.value]))`);
}

async function validateZoneField(name, value) {
  await action('validate', `(() => {
    const input = document.querySelector('#zone-form').elements.namedItem(${JSON.stringify(name)});
    input.value = ${JSON.stringify(value)};
    input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  assert.equal((await zoneFormValues())[name], value, 'Validation discarded the entered field');
}

async function zoneValidation(evidence, viewport) {
  const draft = evidence.recordEffects.afterDelete;
  const before = await databaseSnapshot();
  const beforeVersions = await api(`/zones/${zoneId}/versions`);
  const beforeExport = await download('#record-export-bind', 'export_bind');
  const eventStart = events.length;
  const editorPath = `/management/zones/${zoneId}/edit`;
  await navigate(editorPath, '#zone-form');
  const initial = await zoneFormValues();
  assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), false);
  assert.equal(await evaluate('document.querySelector("#zone-validation-errors") === null'), true);
  const addressOrdinal = draft.records.findIndex(record => record.type === 'A');
  const soaOrdinal = draft.records.findIndex(record => record.type === 'SOA');
  assert.ok(addressOrdinal >= 0 && soaOrdinal >= 0);
  const fields = [
    ['zone[name]', 'invalid..example.test.', /name/i],
    [`zone[records][${addressOrdinal}][data][address]`, '999.0.2.1', /address/i],
    [`zone[records][${addressOrdinal}][ttl]`, '-1', /ttl/i],
    [`zone[records][${soaOrdinal}][data][serial]`, '-1', /serial/i],
    [`zone[records][${addressOrdinal}][name]`, 'outside.example.invalid.', /name/i],
  ];
  for (const [name, invalid, fieldPattern] of fields) {
    await validateZoneField(name, invalid);
    assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), true, 'Invalid candidate left Save enabled');
    const error = await evaluate('document.querySelector("#zone-validation-errors[role=alert]")?.textContent');
    assert.ok(error, 'Invalid candidate has no accessible validation message');
    assert.match(error, fieldPattern, 'Validation did not identify the invalid field path');
    await evaluate('document.querySelector("#zone-save").click()');
    assert.deepEqual(await api('/zones/' + zoneId), draft, 'Inline validation changed the draft');
    if (name === 'zone[name]') {
      assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true, 'Zone validation horizontal overflow');
      await evaluate('document.querySelector("#zone-validation-errors").scrollIntoView({ block: "center" })');
      const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
      await writeFile(`${evidencePath}.${verifyOnly ? 'restart' : 'initial'}.zone-validation.${viewport.width}.png`, Buffer.from(screenshot.data, 'base64'));
    }
    await validateZoneField(name, initial[name]);
    assert.equal(await evaluate('document.querySelector("#zone-validation-errors") === null'), true, 'Corrected candidate retained validation errors');
    assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), false, 'Corrected candidate left Save disabled');
  }
  await click('#zone-form button[phx-click="add_record"]', 'add_record');
  assert.ok(await evaluate(`!!document.querySelector('#zone-record-${draft.records.length}')`));
  assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), true, 'Blank A record must invalidate the candidate');
  assert.ok(await evaluate('document.querySelector("#zone-validation-errors[role=alert]")?.textContent'));
  await click(`#zone-record-${draft.records.length} button[phx-click="remove_record"]`, 'remove_record');
  assert.equal(await evaluate('document.querySelector("#zone-validation-errors") === null'), true);
  assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), false);
  assert.deepEqual(await zoneFormValues(), initial, 'Removing the blank record changed existing form fields');
  const pendingTtl = `zone[records][${addressOrdinal}][ttl]`;
  await validateZoneField(pendingTtl, String(Number(initial[pendingTtl]) + 1));
  assert.equal(await evaluate('document.querySelector("#zone-save").disabled'), false);
  await click('#zone-form a[href="/management/zones"]', 'live_patch');
  await until(() => evaluate('location.pathname === "/management/zones" && !!document.querySelector("#zones-table")'), 'Zone Cancel did not return to the catalog');
  await click(`#zone-${zoneId} a[href="${editorPath}"]`, 'live_patch');
  await until(() => evaluate(`location.pathname === ${JSON.stringify(editorPath)} && !!document.querySelector('#zone-form')`), 'Zone editor did not reopen');
  assert.deepEqual(await zoneFormValues(), initial, 'Cancel/reopen retained an unsaved edit');
  assert.equal(events.slice(eventStart).filter(item => item.event === 'save').length, 0, 'Read-only validation submitted Save');
  assert.deepEqual(await api('/zones/' + zoneId), draft);
  assert.deepEqual(await api(`/zones/${zoneId}/versions`), beforeVersions);
  assert.deepEqual(beforeVersions, evidence.versions);
  await navigate(`/management/zones/${zoneId}/records`, '#records-table');
  const afterExport = await download('#record-export-bind', 'export_bind');
  assert.equal(afterExport.content, beforeExport.content, 'Validation/cancellation changed BIND export bytes');
  assert.deepEqual(await databaseSnapshot(), before, 'Validation/cancellation wrote persistent data or receipts');
}

function recordSignatures(records) {
  return records.map(record => JSON.stringify([record.name, record.type, record.ttl, Object.entries(record.data).sort(([left], [right]) => left.localeCompare(right))])).sort();
}

function assertRecords(zone, records) {
  assert.deepEqual(recordSignatures(zone.records), recordSignatures(records));
}

async function deleteRecord(ordinal, accept) {
  const selector = `#record-${ordinal} button[phx-click="delete_record"]`;
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(selector)}).getAttribute('phx-value-rr_index')`), String(ordinal));
  assert.ok(await evaluate(`document.querySelector(${JSON.stringify(selector)}).hasAttribute('data-confirm')`));
  assert.equal(nextDialogDecision, null);
  const dialogStart = dialogs.length;
  const eventStart = events.length;
  nextDialogDecision = accept;
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  await until(() => dialogs.length > dialogStart && dialogs[dialogStart].handled && dialogs[dialogStart].closed !== undefined, 'Native record confirmation did not complete');
  assert.equal(dialogs.length, dialogStart + 1, 'Record deletion must have exactly one confirmation');
  assert.equal(dialogs[dialogStart].type, 'confirm');
  assert.match(dialogs[dialogStart].message, /Delete this record from the draft/);
  assert.equal(dialogs[dialogStart].closed, accept);
  assert.equal(nextDialogDecision, null);
  if (accept) {
    const sent = await acknowledgedSince('delete_record', eventStart);
    const values = typeof sent.value === 'string' ? Object.fromEntries(new URLSearchParams(sent.value)) : sent.value;
    assert.equal(String(values.rr_index), String(ordinal), 'Filtered row sent a different original ordinal');
    assert.equal(events.slice(eventStart).filter(item => item.event === 'delete_record').length, 1, 'Deletion silently retried');
  } else {
    await click('#record-refresh', 'refresh');
    assert.equal(events.slice(eventStart).filter(item => item.event === 'delete_record').length, 0, 'Cancelled confirmation dispatched deletion');
  }
}

async function download(selector, event) {
  const start = downloadStarts.length;
  await click(selector, event);
  let started;
  await until(() => {
    started = downloadStarts[start];
    if (!started) return false;
    const progress = downloadProgress.get(started.guid);
    assert.notEqual(progress?.state, 'canceled', 'Download canceled: ' + event);
    return progress?.state === 'completed';
  }, 'Download missing: ' + event);
  assert.equal(downloadStarts.length, start + 1, 'Unexpected additional download: ' + event);
  assert.ok(started.guid && started.suggestedFilename, 'Missing fresh download identity');
  const filename = started.suggestedFilename;
  return { filename, guid: started.guid, content: await readFile(join(downloads, filename), 'utf8') };
}

try {
  assert.deepEqual(await readdir(profile), []);
  browser = spawn('chromium', ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0', `--user-data-dir=${profile}`], { stdio: 'ignore', detached: true });
  browser.once('error', error => errors.push(error.message));
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return !!port; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'Chromium startup');
  const page = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.addEventListener('message', event => {
    const result = JSON.parse(event.data);
    if (result.id && pending.has(result.id)) {
      const request = pending.get(result.id);
      pending.delete(result.id);
      clearTimeout(request.timeout);
      if (result.error) request.reject(new Error(JSON.stringify(result.error)));
      else request.resolve(result.result);
    }
    if (result.method === 'Runtime.exceptionThrown') errors.push(result.params);
    if (result.method === 'Runtime.consoleAPICalled' && result.params.type === 'error') errors.push(result.params);
    if (result.method === 'Browser.downloadWillBegin') downloadStarts.push(result.params);
    if (result.method === 'Browser.downloadProgress') downloadProgress.set(result.params.guid, result.params);
    if (result.method === 'Page.javascriptDialogOpening') {
      if (nextDialogDecision === null) errors.push({ unexpectedDialog: result.params });
      const dialog = { ...result.params, decision: nextDialogDecision, handled: false };
      dialogs.push(dialog);
      nextDialogDecision = null;
      cdp('Page.handleJavaScriptDialog', { accept: dialog.decision === true })
        .then(() => { dialog.handled = true; })
        .catch(error => errors.push(error.message));
    }
    if (result.method === 'Page.javascriptDialogClosed') {
      const dialog = dialogs.findLast(item => item.closed === undefined);
      if (dialog) dialog.closed = result.params.result;
      else errors.push({ unexpectedDialogClose: result.params });
    }
    if (['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(result.method)) {
      let frame;
      try { frame = JSON.parse(result.params.response.payloadData); } catch { return; }
      if (!Array.isArray(frame)) return;
      const key = `${result.params.requestId}:${frame[1]}`;
      if (frame[3] === 'event' && result.method.endsWith('Sent')) events.push({ key, event: frame[4].event, value: frame[4].value });
      if (frame[3] === 'live_patch' && result.method.endsWith('Sent')) events.push({ key, event: 'live_patch', value: frame[4] });
      if (frame[3] === 'phx_reply' && result.method.endsWith('Received')) replies.set(key, frame[4]);
    }
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('CDP connection')), 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timeout); reject(new Error('CDP connection')); }, { once: true });
  });
  for (const domain of ['Page', 'Runtime', 'Network']) await cdp(`${domain}.enable`);
  await mkdir(downloads, { recursive: true });
  await cdp('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads, eventsEnabled: true });
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  let evidence;
  if (!verifyOnly) {
    await navigate('/management/zones', '#zones-table');
    const before = await api('/zones');
    await filter('#zones-filter-form', { 'filter[name]': 'ALPHA' });
    assert.equal(await evaluate('document.querySelectorAll("#zones-table tbody tr").length'), 1);
    assert.match(await evaluate('document.querySelector("#zone-count").textContent'), /1.*2/);
    await click('#zone-refresh', 'refresh');
    assert.equal(await evaluate('document.querySelectorAll("#zones-table tbody tr").length'), 1);
    const zoneCsv = await download('#zone-export', 'export_csv');
    assert.match(zoneCsv.content, /alpha\.example\.test\./);
    assert.ok(!zoneCsv.content.includes('beta.example.test.'));
    assert.deepEqual(await api('/zones'), before);

    await navigate(`/management/zones/${zoneId}/records`, '#records-table');
    const original = await api('/zones/' + zoneId);
    const originalVersions = await api(`/zones/${zoneId}/versions`);
    const ordinal = original.records.findIndex(record => record.name === 'www.alpha.example.test.' && record.type === 'A');
    assert.ok(ordinal >= 0);
    assert.notEqual(ordinal, 0, 'Fixture must prove filtering does not renumber records');
    await filter('#record-filter-form', { filter: 'WWW', type: 'A' });
    assert.equal(await evaluate('document.querySelectorAll("#records-table tbody tr").length'), 1);
    assert.equal(await evaluate(`document.querySelector('#record-${ordinal} a').getAttribute('href')`), `/management/zones/${zoneId}/records/${ordinal}/edit`);
    const recordCsv = await download('#record-export-csv', 'export_csv');
    assert.match(recordCsv.content, /www\.alpha\.example\.test\./);
    assert.match(recordCsv.content, /192\.0\.2\.20/);
    assert.ok(!recordCsv.content.includes('SOA') && !recordCsv.content.includes('ns1.alpha'));
    const bind = await download('#record-export-bind', 'export_bind');
    assert.match(bind.content, /\bSOA\b/);
    assert.match(bind.content, /\bNS\b/);
    for (const record of original.records) assert.ok(bind.content.includes(record.name));
    assert.match(bind.content, /192\.0\.2\.10/);
    assert.match(bind.content, /192\.0\.2\.20/);
    await click('#record-refresh', 'refresh');
    assert.equal(await evaluate('document.querySelectorAll("#records-table tbody tr").length'), 1);
    assert.deepEqual(await api('/zones/' + zoneId), original);

    const bulkRecord = { name: 'bulk.alpha.example.test.', type: 'A', ttl: 300, data: { address: '192.0.2.1' } };
    await navigate(`/management/zones/${zoneId}/records/bulk`, '#bulk-record-form');
    assert.equal(await evaluate('document.querySelector("#bulk-record-save").disabled'), true);
    const bulkInput = JSON.stringify([{ ...bulkRecord, name: bulkRecord.name.toUpperCase() }]);
    await previewBulk(bulkInput);
    await until(() => evaluate('!!document.querySelector("#bulk-record-preview") && !document.querySelector("#bulk-record-save").disabled'), 'Canonical bulk preview missing');
    const preview = await evaluate('document.querySelector("#bulk-record-preview").textContent');
    assert.ok(preview.includes(bulkRecord.name) && preview.includes(bulkRecord.data.address), 'Preview must show canonical candidate records');
    const previewCount = await evaluate('document.querySelector("#bulk-record-count").textContent.replace(/\\s+/g, " ").trim()');
    assert.ok(previewCount.includes(`Append 1 records to ${original.records.length} existing records; total ${original.records.length + 1}. Draft revision ${original.revision}`), previewCount);
    const previewTypes = await evaluate('document.querySelector("#bulk-record-types").textContent');
    assert.match(previewTypes, /\bA\b/);
    assert.ok(!previewTypes.includes('SOA') && !previewTypes.includes('NS'), 'Preview types must count appended records only');
    assert.equal(await evaluate('document.querySelectorAll("#bulk-record-preview-table tbody tr").length'), 1, 'Preview must contain appended records only');
    assert.ok(await evaluate(`document.querySelector('#bulk-record-preview-table tbody tr').textContent.includes(${JSON.stringify(bulkRecord.name)})`));
    assert.deepEqual(await api('/zones/' + zoneId), original, 'Preview mutated the draft');
    await previewBulk('[invalid-json');
    assert.equal(await evaluate('document.querySelector("#bulk-record-save").disabled'), true, 'Invalidated preview left Save enabled');
    assert.equal(await evaluate('document.querySelector("#bulk-record-preview") === null'), true, 'Invalid input retained the previous candidate');
    assert.ok(await evaluate('document.querySelector("#record-error")?.textContent'));
    assert.deepEqual(await api('/zones/' + zoneId), original, 'Invalid preview mutated the draft');
    const invalidSaveStart = events.length;
    await evaluate('document.querySelector("#bulk-record-save").click()');
    await previewBulk(bulkInput);
    assert.equal(events.slice(invalidSaveStart).filter(item => item.event === 'save_bulk').length, 0, 'Disabled invalid preview submitted Save');
    assert.equal(await evaluate('document.querySelector("#bulk-record-save").disabled'), false);
    await click('#bulk-record-save', 'save_bulk');
    await until(() => evaluate(`location.pathname === '/management/zones/${zoneId}/records' && !!document.querySelector('#records-table')`), 'Bulk append did not return to records');
    const afterBulk = await api('/zones/' + zoneId);
    assert.equal(afterBulk.revision, original.revision + 1);
    assertRecords(afterBulk, [...original.records, bulkRecord]);
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), originalVersions);

    const editOrdinal = afterBulk.records.findIndex(record => record.name === 'www.alpha.example.test.' && record.type === 'A');
    await navigate(`/management/zones/${zoneId}/records/${editOrdinal}/edit`, '#record-form');
    await submit('#record-form', { 'record[data][address]': '192.0.2.21' }, 'save');
    await until(() => evaluate(`location.pathname === '/management/zones/${zoneId}/records' && !!document.querySelector('#records-table')`), 'Record edit did not return to records');
    const afterEdit = await api('/zones/' + zoneId);
    const editedRecord = { ...afterBulk.records[editOrdinal], data: { address: '192.0.2.21' } };
    assert.equal(afterEdit.revision, afterBulk.revision + 1);
    assertRecords(afterEdit, afterBulk.records.map((record, index) => index === editOrdinal ? editedRecord : record));
    await filter('#record-filter-form', { filter: 'WWW', type: 'A' });
    const cachedOrdinal = afterEdit.records.findIndex(record => record.name === editedRecord.name && record.type === 'A');
    assert.equal(await evaluate('document.querySelectorAll("#records-table tbody tr").length'), 1);
    assert.equal(await evaluate(`document.querySelector('#record-${cachedOrdinal}').dataset.rrIndex`), String(cachedOrdinal));
    await deleteRecord(cachedOrdinal, false);
    assert.deepEqual(await api('/zones/' + zoneId), afterEdit, 'Cancelled deletion changed the draft');
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), originalVersions);

    const concurrentRecord = { name: 'concurrent.alpha.example.test.', type: 'A', ttl: 300, data: { address: '192.0.2.11' } };
    const afterConcurrent = await api('/commands/update_zone', { id: zoneId, name: afterEdit.name, expected_revision: afterEdit.revision, records: [...afterEdit.records, concurrentRecord] });
    assert.equal(afterConcurrent.revision, afterEdit.revision + 1);
    assertRecords(afterConcurrent, [...afterEdit.records, concurrentRecord]);
    await deleteRecord(cachedOrdinal, true);
    await until(() => evaluate('!!document.querySelector("#record-error")'), 'Stale deletion did not show a revision error');
    assert.match(await evaluate('document.querySelector("#record-error").textContent'), /revision/i);
    assert.deepEqual(await api('/zones/' + zoneId), afterConcurrent, 'Stale deletion discarded concurrent records or retried');
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), originalVersions);
    assert.ok(await evaluate(`document.querySelector('#record-${cachedOrdinal}').textContent.includes(${JSON.stringify(editedRecord.name)})`), 'Stale rejection discarded the selected cached row');
    await click('#record-refresh', 'refresh');
    assert.equal(await evaluate('document.querySelector("#record-owner-filter").value'), 'WWW');
    const acceptedOrdinal = afterConcurrent.records.findIndex(record => record.name === editedRecord.name && record.type === 'A');
    assert.notEqual(acceptedOrdinal, cachedOrdinal, 'Concurrent fixture must change canonical ordinals');
    assert.equal(await evaluate('document.querySelectorAll("#records-table tbody tr").length'), 1);
    await deleteRecord(acceptedOrdinal, true);
    const afterDelete = await api('/zones/' + zoneId);
    assert.equal(afterDelete.revision, afterConcurrent.revision + 1);
    assertRecords(afterDelete, afterConcurrent.records.filter((_record, index) => index !== acceptedOrdinal));
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), originalVersions, 'Draft record workflows changed immutable history');
    assert.deepEqual(await api('/workers'), [], 'Global catalog inferred a Worker');
    const recordEffects = { original, afterBulk, afterEdit, afterConcurrent, afterDelete, bulkRecord, editedRecord, concurrentRecord, cachedOrdinal, acceptedOrdinal, preview, dialogs };

    await navigate('/management/zones', '#zones-table');
    const beforeZoneDelete = await api('/zones');
    await click(`#zone-${otherId} [phx-click="delete_zone"]`, 'delete_zone');
    await click('#zone-cancel-delete', 'cancel_delete');
    assert.deepEqual(await api('/zones'), beforeZoneDelete);
    await click(`#zone-${otherId} [phx-click="delete_zone"]`, 'delete_zone');
    await click('#zone-delete-confirm', 'confirm_delete');
    assert.deepEqual((await api('/zones')).map(zone => zone.id), [zoneId]);
    assert.equal((await api(`/zones/${otherId}/versions`)).length, 1, 'Deleted draft lost confirmed history');
    evidence = { zones: await api('/zones'), versions: originalVersions, deletedVersions: await api(`/zones/${otherId}/versions`), zoneCsv, recordCsv, bind, recordEffects };
    await writeFile(evidencePath, JSON.stringify(evidence));
  } else evidence = JSON.parse(await readFile(evidencePath, 'utf8'));

  for (const viewport of [{ width: 1440, height: 1000, mobile: false }, { width: 390, height: 844, mobile: true }]) {
    await cdp('Emulation.setDeviceMetricsOverride', { ...viewport, deviceScaleFactor: 1 });
    await navigate('/management/zones', '#zones-table');
    await click('#zone-refresh', 'refresh');
    assert.deepEqual(await api('/zones'), evidence.zones);
    await navigate(`/management/zones/${zoneId}/records`, '#records-table');
    await click('#record-refresh', 'refresh');
    assert.deepEqual(await api('/zones/' + zoneId), evidence.recordEffects.afterDelete);
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), evidence.versions);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true, 'Horizontal overflow');
    const screenshot = await cdp('Page.captureScreenshot', { format: 'png' });
    await writeFile(`${evidencePath}.${verifyOnly ? 'restart' : 'initial'}.${viewport.width}.png`, Buffer.from(screenshot.data, 'base64'));
    await navigate(`/management/zones/${zoneId}/records/bulk`, '#bulk-record-form');
    await previewBulk(JSON.stringify([{ name: 'probe.alpha.example.test.', type: 'A', ttl: 300, data: { address: '192.0.2.30' } }]));
    assert.equal(await evaluate('document.querySelector("#bulk-record-save").disabled'), false);
    assert.equal(await evaluate('document.querySelectorAll("#bulk-record-preview-table tbody tr").length'), 1);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true, 'Bulk preview horizontal overflow');
    assert.deepEqual(await api('/zones/' + zoneId), evidence.recordEffects.afterDelete, 'Viewport preview wrote the draft');
    assert.deepEqual(await api(`/zones/${zoneId}/versions`), evidence.versions);
    await evaluate('document.querySelector("#bulk-record-preview").scrollIntoView({ block: "center" })');
    const bulkScreenshot = await cdp('Page.captureScreenshot', { format: 'png' });
    await writeFile(`${evidencePath}.${verifyOnly ? 'restart' : 'initial'}.bulk.${viewport.width}.png`, Buffer.from(bulkScreenshot.data, 'base64'));
    await navigate(`/management/zones/${zoneId}/records`, '#records-table');
    await zoneValidation(evidence, viewport);
  }
  assert.deepEqual(errors, []);
  console.log(`PASS Chromium DNS catalog ${verifyOnly ? 'read-only restart' : 'filtered CSV, BIND export, canonical JSON preview/append, edit, native delete cancel/accept, stale CAS and immutable history'}; read-only Zone validation/cancel/reopen with SQL and export checks; no BIND import claim; no login; desktop/mobile`);
} finally {
  socket?.close();
  for (const request of pending.values()) clearTimeout(request.timeout);
  if (browser?.pid) {
    try { process.kill(-browser.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    await delay(500);
    try { process.kill(-browser.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
  }
}
