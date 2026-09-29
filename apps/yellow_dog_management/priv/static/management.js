'use strict';
// Credentials remain in memory. The browser never sends authenticated cookies.
let token = '', workers = [], zones = [], selectedWorker = null;
const pending = new Map();
const $ = id => document.getElementById(id);
const notice = message => { $('notice').textContent = message; };
const renderError = error => notice(error.message || String(error));
function run(fn) { return event => { event?.preventDefault(); Promise.resolve().then(fn).catch(renderError); }; }
async function request(path, options = {}) {
  const response = await fetch('/api' + path, { ...options, headers: { Authorization: 'Bearer ' + token, ...(options.headers || {}) } });
  if (!response.ok) {
    const body = await response.json();
    const error = body.error || body;
    throw new Error(`${error.code}: ${error.message}${error.details ? '\n' + JSON.stringify(error.details) : ''}`);
  }
  return response;
}
async function read(path) { return (await (await request(path)).json()).data; }
async function mutate(operation, params) {
  const body = JSON.stringify(params), fingerprint = operation + body;
  // A network failure keeps the same key for an explicit retry of the same form.
  const key = pending.get(fingerprint) || crypto.randomUUID();
  pending.set(fingerprint, key);
  const response = await request('/commands/' + operation, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key }, body });
  pending.delete(fingerprint);
  return (await response.json()).data;
}
function option(select, value, label) { const item = document.createElement('option'); item.value = value; item.textContent = label; select.append(item); }
function populate(id, items, label, empty) { const element = $(id), previous = element.value; element.replaceChildren(); if (empty) option(element, '', empty); items.forEach(item => option(element, item.id, label(item))); element.value = previous; if (element.selectedIndex < 0 && !empty) element.selectedIndex = 0; }
function fill(form, data) { [...form.elements].forEach(input => { if (input.name && data[input.name] !== undefined) input.value = data[input.name]; }); }
function value(form, name) { return form.elements.namedItem(name).value; }
function recordRow(record = { name: '', type: 'A', ttl: 300, data: { address: '' } }) {
  const row = document.createElement('tr');
  const name = document.createElement('input'); name.value = record.name; name.required = true; name.setAttribute('aria-label', 'Record name');
  const type = document.createElement('select'); ['SOA', 'NS', 'A'].forEach(t => option(type, t, t)); type.value = record.type; type.setAttribute('aria-label', 'Record type');
  const ttl = document.createElement('input'); ttl.type = 'number'; ttl.min = '0'; ttl.max = '2147483647'; ttl.value = record.ttl; ttl.required = true; ttl.setAttribute('aria-label', 'TTL');
  const data = document.createElement('input'); data.size = 70; data.required = true; data.setAttribute('aria-label', 'Record value');
  data.value = record.type === 'SOA' ? ['mname', 'rname', 'serial', 'refresh', 'retry', 'expire', 'minimum'].map(k => record.data[k]).join(' ') : record.data.host || record.data.address;
  const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove'; remove.onclick = () => row.remove();
  [name, type, ttl, data, remove].forEach(control => { const cell = document.createElement('td'); cell.append(control); row.append(cell); });
  row.record = () => { let content; const text = data.value.trim(); if (type.value === 'SOA') { const parts = text.split(/\s+/); if (parts.length !== 7) throw new Error('SOA requires seven values.'); content = Object.fromEntries(['mname', 'rname', 'serial', 'refresh', 'retry', 'expire', 'minimum'].map((k, i) => [k, i > 1 ? Number(parts[i]) : parts[i]])); } else content = { [type.value === 'A' ? 'address' : 'host']: text }; return { name: name.value, type: type.value, ttl: Number(ttl.value), data: content }; };
  $('records').append(row);
}
async function refresh() {
  [workers, zones] = await Promise.all([read('/workers'), read('/zones')]);
  populate('zone-select', zones, z => `${z.name} (draft ${z.revision})`, 'New zone');
  populate('assign-zone', zones, z => z.name);
  populate('worker-select', workers, w => w.name, 'New Worker');
  populate('target-worker', workers, w => w.name);
  const checked = new Set([...$('assignment-workers').querySelectorAll('input:checked')].map(i => i.value));
  $('assignment-workers').replaceChildren();
  workers.forEach(worker => { const label = document.createElement('label'), input = document.createElement('input'); input.type = 'checkbox'; input.value = worker.id; input.checked = checked.has(worker.id); label.append(input, document.createTextNode(worker.name + ' ')); $('assignment-workers').append(label); });
  await Promise.all([loadTarget(), loadAssignmentVersions()]);
}
async function loadZone() {
  const id = $('zone-select').value, form = $('zone-form'); form.reset(); $('records').replaceChildren(); $('versions').replaceChildren();
  if (!id) { recordRow(); return; }
  const zone = await read('/zones/' + encodeURIComponent(id)); fill(form, { ...zone, expected_revision: zone.revision }); zone.records.forEach(recordRow);
  const versions = await read('/zones/' + encodeURIComponent(id) + '/versions');
  versions.forEach(version => { const li = document.createElement('li'); li.textContent = `Version ${version.version} — ${version.digest}`; $('versions').append(li); });
}
async function loadAssignmentVersions() { const id = $('assign-zone').value; populate('assign-version', id ? await read('/zones/' + encodeURIComponent(id) + '/versions') : [], v => `Version ${v.version} (${v.digest.slice(0, 12)})`); }
async function loadTarget() {
  const id = $('target-worker').value; selectedWorker = id ? await read('/workers/' + encodeURIComponent(id)) : null;
  $('worker-state').textContent = selectedWorker ? `Desired-state revision ${selectedWorker.revision}. Unconnected. Actual state: unknown.` : 'Create a logical Worker to allocate resources.';
  populate('service-select', selectedWorker?.services || [], s => `${s.instance_id}: desired ${s.desired_state}`, 'New service');
  loadService();
  $('assignments').replaceChildren(); $('preview-output').textContent = ''; $('prepared-state').textContent = '';
  (selectedWorker?.assignments || []).forEach(assignment => { const li = document.createElement('li'), button = document.createElement('button'); button.textContent = 'Unassign'; button.onclick = run(async () => { await mutate('unassign', { worker_id: id, service_id: assignment.service_id, resource_version_id: assignment.resource_version_id, resource_id: assignment.resource_id, expected_revision: selectedWorker.revision }); await refresh(); notice('Resource unassigned from the next target. Actual state remains unknown.'); }); li.append(document.createTextNode(`${assignment.service_id}: ${assignment.resource_id || assignment.resource_version_id} `), button); $('assignments').append(li); });
}
function requireWorker() { if (!selectedWorker) throw new Error('Select a logical Worker first.'); return selectedWorker; }
$('login').onsubmit = run(async () => { token = $('token').value; await refresh(); $('token').value = ''; $('login').hidden = true; $('logout').hidden = false; $('workspace').hidden = false; notice('Signed in as operator.'); });
$('logout').onclick = () => { token = ''; pending.clear(); location.reload(); };
$('zone-select').onchange = run(loadZone);
$('assign-zone').onchange = run(loadAssignmentVersions);
$('target-worker').onchange = run(loadTarget);
$('add-record').onclick = () => recordRow();
$('zone-form').onsubmit = run(async () => { const form = $('zone-form'), id = value(form, 'id'); const params = { name: value(form, 'name'), records: [...$('records').children].map(row => row.record()) }; if (id) Object.assign(params, { id, expected_revision: Number(value(form, 'expected_revision')) }); const zone = await mutate(id ? 'update_zone' : 'create_zone', params); await refresh(); $('zone-select').value = zone.id; await loadZone(); notice('Draft saved in PostgreSQL.'); });
$('confirm-zone').onclick = run(async () => { const form = $('zone-form'); await mutate('confirm_zone', { id: value(form, 'id'), expected_revision: Number(value(form, 'expected_revision')) }); await Promise.all([loadZone(), loadAssignmentVersions()]); notice('Immutable version confirmed. Assign it explicitly to target services.'); });
$('delete-zone').onclick = run(async () => { if (!confirm('Delete this unassigned draft? Unassign it from every Worker first. Retained immutable targets remain available.')) return; const form = $('zone-form'); await mutate('delete_zone', { id: value(form, 'id'), expected_revision: Number(value(form, 'expected_revision')) }); await refresh(); $('zone-select').value = ''; await loadZone(); notice('Draft deleted; historical versions retained.'); });
$('worker-select').onchange = run(async () => { const id = $('worker-select').value, form = $('worker-form'); form.reset(); form.elements.id.readOnly = Boolean(id); if (id) { const worker = await read('/workers/' + encodeURIComponent(id)); fill(form, { ...worker, expected_revision: worker.revision }); } });
$('worker-form').onsubmit = run(async () => { const form = $('worker-form'), editing = Boolean($('worker-select').value); const params = { id: value(form, 'id'), name: value(form, 'name'), expected_capabilities: ['dns'] }; if (editing) params.expected_revision = Number(value(form, 'expected_revision')); const worker = await mutate(editing ? 'update_worker' : 'create_worker', params); await refresh(); $('worker-select').value = worker.id; fill(form, { ...worker, expected_revision: worker.revision }); form.elements.id.readOnly = true; notice('Logical Worker saved. Actual state: unknown.'); });
function loadService() { const service = selectedWorker?.services.find(s => s.id === $('service-select').value); if (service) fill($('service-form'), { ...service, ...service.config, id: service.instance_id }); else $('service-form').reset(); }
$('service-select').onchange = loadService;
$('service-form').onsubmit = run(async () => { const worker = requireWorker(), form = $('service-form'); await mutate('put_service', { worker_id: worker.id, id: value(form, 'id'), type: 'dns', desired_state: value(form, 'desired_state'), config: { listen_address: value(form, 'listen_address'), port: Number(value(form, 'port')) }, expected_revision: worker.revision }); await refresh(); notice('Desired service state saved. Actual runtime state is unknown.'); });
$('assignment-form').onsubmit = run(async () => { const ids = [...$('assignment-workers').querySelectorAll('input:checked')].map(input => input.value); if (!ids.length) throw new Error('Select at least one Worker.'); let completed = 0; try { for (const id of ids) { const worker = await read('/workers/' + encodeURIComponent(id)); await mutate('assign', { worker_id: id, service_id: value($('assignment-form'), 'service_id'), resource_version_id: $('assign-version').value, expected_revision: worker.revision }); completed++; } } catch (error) { await refresh(); throw new Error(`${completed} of ${ids.length} assignments completed. ${error.message}`); } await refresh(); notice(`Version assigned to ${completed} logical Workers. No configuration was applied.`); });
$('preview').onclick = run(async () => { const worker = requireWorker(); $('preview-output').textContent = JSON.stringify(await read('/workers/' + encodeURIComponent(worker.id) + '/preview'), null, 2); });
$('confirm-target').onclick = run(async () => { const worker = requireWorker(); const target = await mutate('confirm_target', { worker_id: worker.id, expected_revision: worker.revision }); await refresh(); $('export-form').elements.revision.value = target.revision; $('prepared-state').textContent = `Target revision ${target.revision} prepared. Actual state: unknown.`; notice('Complete target confirmed for export.'); });
$('export-form').onsubmit = run(async () => { const worker = requireWorker(), revision = value($('export-form'), 'revision'); const response = await request('/workers/' + encodeURIComponent(worker.id) + '/targets/' + encodeURIComponent(revision) + '/export'); const url = URL.createObjectURL(await response.blob()), a = document.createElement('a'); a.href = url; a.download = `${worker.id}-target-${revision}.toml`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); notice('Prepared TOML exported. Physical Worker state remains unknown.'); });
recordRow();
