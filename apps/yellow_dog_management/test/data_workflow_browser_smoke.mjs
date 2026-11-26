import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

// Runs against the disposable Management-only release started by management_browser.sh.
export async function dataWorkflowSmoke({ api, cdp, evaluate, navigate, until, submit, confirmNext, dialogHandled, base, restart = false }) {
  const stateFile = process.env.MANAGEMENT_DATA_STATE_FILE;
  assert.ok(stateFile, 'Data scope requires its disposable state artifact');
  const selectedDigest = () => execFileSync('psql', [process.env.YELLOW_DOG_MANAGEMENT_DATABASE_URL,
    '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c',
    "SELECT digest FROM management_geoip_selections WHERE type = 'city'"], { encoding: 'utf8' }).trim();
  const assignmentPath = id => `/zones/${id}/assignments`;
  const detail = (id, tab = 'edit') => `/management/zones/${id}/${tab}`;
  const viewPath = (worker, service) => `/workers/${worker}/dns-services/${service}/views`;
  const aclPath = (worker, service) => `/workers/${worker}/dns-services/${service}/acls`;
  const click = selector => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const toolbar = async direction => {
    const history = await cdp('Page.getNavigationHistory');
    const entry = history.entries[history.currentIndex + direction];
    assert.ok(entry, `Missing browser history entry ${direction}`);
    await cdp('Page.navigateToHistoryEntry', {entryId: entry.id});
  };
  const clean = id => until(() => evaluate(`document.querySelector(${JSON.stringify(id)}).dataset.editorDirty === 'false'`), `Editor did not acknowledge save: ${id}`);
  const change = (form, fields) => evaluate(`(() => {
    const form = document.querySelector(${JSON.stringify(form)});
    for (const [name, value] of Object.entries(${JSON.stringify(fields)})) {
      const field = form.elements.namedItem(name);
      if (!field) throw new Error('Missing field: ' + name);
      field.value = value;
      field.dispatchEvent(new Event('input', {bubbles:true}));
      field.dispatchEvent(new Event('change', {bubbles:true}));
    }
  })()`);
  async function save(form, button) {
    await until(() => evaluate(`!document.querySelector(${JSON.stringify(button)}).disabled`), `Save disabled: ${button}`);
    await evaluate(`document.querySelector(${JSON.stringify(form)}).requestSubmit(document.querySelector(${JSON.stringify(button)}))`);
  }
  async function tab(id, area) {
    await click(`a[data-editor-preserve][href='${detail(id, area)}']`);
    await until(() => evaluate(`location.pathname === ${JSON.stringify(detail(id, area))}`), `Zone tab failed: ${area}`);
  }
  async function rejectCommand(operation, params, expectedStatus = 422) {
    const response = await fetch(`${base}/api/commands/${operation}`, { method:'POST',
      headers:{'Content-Type':'application/json','Idempotency-Key':crypto.randomUUID()},
      body:JSON.stringify(params), signal:AbortSignal.timeout(10000) });
    const result = await response.json();
    assert.equal(response.status, expectedStatus, JSON.stringify(result));
    return result.error;
  }
  async function publish(worker) {
    const previousRevision=(await api(`/workers/${worker}/targets`))[0]?.revision || 0;
    await navigate(`/server/${worker}/targets`);
    await click('[phx-click="preview"]');
    await until(() => evaluate(`!!document.querySelector('#target-preview')`), 'Target preview missing');
    confirmNext(true);
    await click('[phx-click="confirm_target"]');
    let target;
    await until(async () => { target = (await api(`/workers/${worker}/targets`))[0]; return target?.revision > previousRevision; }, 'Target publication missing');
    assert.equal(target.status, 'prepared');
    assert.equal(target.actual_state, 'unknown');
    const response = await fetch(`${base}/api/workers/${worker}/targets/${target.revision}/export`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('x-yellow-dog-export-scope'), 'dns_zones');
    return { revision:target.revision, toml:await response.text() };
  }
  async function verifyArtifact(digest) {
    await navigate('/system/ip-database');
    await click('#ip-database-refresh');
    await until(() => evaluate(`document.querySelector('#ip-database-city [data-status]')?.dataset.status === 'Available'`), 'Selected artifact did not verify');
    assert.equal(await evaluate(`document.querySelector('#ip-database-city div[data-digest]').dataset.digest`), digest);
    assert.equal(selectedDigest(), digest, 'UI selection differs from durable PostgreSQL selection');
    assert.equal(await evaluate(`!!document.querySelector('[id^="ip-database-reload"], [id^="ip-database-unload"]')`), false);
    assert.equal(await evaluate(`document.querySelector('#ip-database-workflow').textContent.includes('not included in the current Worker target/export')`), true);
  }
  if (restart) {
    const state = JSON.parse(await readFile(stateFile, 'utf8'));
    assert.deepEqual(await api(`/zones/${state.zone.id}`), state.zone);
    assert.deepEqual(await api(assignmentPath(state.zone.id)), state.assignments);
    assert.deepEqual(await api(`/zones/${state.zone.id}/versions`), state.versions);
    for (const item of state.exports) assert.equal(await (await fetch(`${base}/api/workers/${state.workers[0]}/targets/${item.revision}/export`)).text(), item.toml);
    assert.deepEqual(await api(viewPath(state.workers[0], state.services[0].id)), state.views);
    assert.deepEqual(await api(aclPath(state.workers[0], state.services[0].id)), state.acls);
    await navigate(detail(state.zone.id, 'application'));
    assert.equal(await evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length`), state.assignments.assignments.length);
    await verifyArtifact(state.digest);
    console.log('PASS Data restart: fresh Chromium reread identical drafts, immutable versions, complete assignments, exact historical exports, scoped View/ACL and verified artifact selection');
    return;
  }

  assert.deepEqual(await api('/workers'), []);
  assert.deepEqual(await api('/zones'), []);
  await navigate('/management/zones');
  await click('a[href="/management/zones/new"]');
  await until(() => evaluate(`!!document.querySelector('#new-zone-dialog:modal #zone-form')`), 'New Zone opens as a modal');
  await change('#zone-form', {'zone[name]':'unsaved.test.'});
  confirmNext(false);
  await evaluate(`document.querySelector('#new-zone-dialog').dispatchEvent(new Event('cancel', {cancelable:true}))`);
  await until(dialogHandled, 'Modal cancel checks unsaved edits');
  assert.equal(await evaluate(`document.querySelector('#new-zone-dialog:modal #zone-name').value`), 'unsaved.test.');
  confirmNext(true);
  await click('#zone-cancel');
  await until(() => evaluate(`location.pathname === '/management/zones' && !document.querySelector('#new-zone-dialog')`), 'Cancel returns to the zone list');
  assert.deepEqual(await api('/zones'), []);
  await navigate('/management/zones/new');
  await until(() => evaluate(`!!document.querySelector('#new-zone-dialog:modal #zone-form')`), 'Direct New Zone link opens the modal');
  await click('[phx-click="add_record"]');
  await until(() => evaluate(`document.querySelectorAll('#zone-form fieldset').length === 3`), 'Zone record row missing');
  const name = 'data-workflow.test.';
  const records = [
    {name,type:'SOA',ttl:300,data:{mname:`ns.${name}`,rname:`hostmaster.${name}`,serial:1,refresh:3600,retry:600,expire:86400,minimum:300}},
    {name,type:'NS',ttl:300,data:{host:`ns.${name}`}},
    {name:`ns.${name}`,type:'A',ttl:300,data:{address:'192.0.2.10'}},
  ];
  const fields = {'zone[name]':name};
  records.forEach((record,index) => {
    for (const key of ['name','type','ttl']) fields[`zone[records][${index}][${key}]`] = String(record[key]);
    for (const [key,value] of Object.entries(record.data)) fields[`zone[records][${index}][data][${key}]`] = String(value);
  });
  await change('#zone-form', fields);
  await save('#zone-form','#zone-save');
  let zone;
  await until(async () => { zone = (await api('/zones'))[0]; return !!zone; }, 'Zero-Worker Zone save failed');
  await clean('#zone-form');
  assert.equal(await evaluate(`!!document.querySelector('#new-zone-dialog')`), false);
  const ordered = values => [...values].sort((left,right)=>`${left.name}:${left.type}`.localeCompare(`${right.name}:${right.type}`));
  assert.deepEqual(ordered(zone.records), ordered(records));
  assert.deepEqual(await api('/workers'), []);
  await navigate('/management/zones');
  const zoneRecordsLink = `#zone-${zone.id} a[href="/management/zones/${zone.id}/records"]`;
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(zoneRecordsLink)}).textContent.trim()`), zone.name);
  const actionLabels = table => evaluate(`[...document.querySelectorAll('${table} tbody tr:first-child td:last-child .btn')].map(button => [button.title, button.getAttribute('aria-label'), !!button.querySelector('svg')])`);
  assert.deepEqual(await actionLabels('#zones-table'), ['Edit zone', 'Confirm version', 'Delete zone'].map(label => [label, label, true]));
  await click(zoneRecordsLink);
  await until(() => evaluate(`document.querySelectorAll('#records-table tbody tr').length === ${records.length}`), 'Zone name opens its DNS record table');
  assert.deepEqual(await evaluate(`Object.fromEntries([...document.querySelectorAll('#records-table tbody tr')].map(row => [row.cells[1].textContent.trim(), row.cells[3].textContent.trim()]))`), {
    SOA: `ns.${name} hostmaster.${name} 1 3600 600 86400 300`,
    NS: `ns.${name}`,
    A: '192.0.2.10',
  });
  assert.deepEqual(await actionLabels('#records-table'), ['Edit record', 'Delete record'].map(label => [label, label, true]));
  await navigate(detail(zone.id));
  await tab(zone.id,'versions');
  await click('#zone-confirm-version');
  await until(async () => (await api(`/zones/${zone.id}/versions`)).length === 1, 'Zero-Worker confirmation failed');
  const v1 = (await api(`/zones/${zone.id}/versions`))[0];
  await click('#zone-confirm-version');
  assert.equal((await api(`/zones/${zone.id}/versions`)).length, 1, 'Same saved draft should reuse its version');
  assert.deepEqual(await api('/workers'), []);

  const workers = [];
  for (const workerName of ['Data Worker A','Data Worker B','Data Worker C']) {
    await navigate('/management/servers');
    await submit('#worker-form',{'worker[name]':workerName});
    let worker;
    await until(async () => { worker=(await api('/workers')).find(item=>item.name===workerName); return !!worker; },'Node registration missing');
    workers.push(worker.id);
    await until(() => evaluate(`!!document.querySelector('#worker-bootstrap')`),'Registration bootstrap missing');
    await click('[phx-click="dismiss_connection"]');
    await until(() => evaluate(`!document.querySelector('#worker-bootstrap')`),'Transient credential not dismissed');
  }
  const services = [];
  for (const [index,worker] of workers.entries()) {
    const port = String(18553 + index);
    await navigate(`/server/${worker}/dns`);
    await submit('#service-form',{'service[mode]':'all_ipv4','service[transports][udp][port]':port,'service[transports][tcp][port]':port,'service[desired_state]':false});
    let service;
    await until(async()=>{service=(await api(`/workers/${worker}`)).services[0];return !!service;},'Node DNS instance missing');
    services.push(service);
    await until(()=>evaluate(`document.querySelector('#node-workflow').dataset.dirty === 'false'`),'Service save not acknowledged');
  }
  await navigate(detail(zone.id,'application'));
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[0]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 1`),'First proposal missing');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form select[name$="[service_id]"]').value`),services[0].id);
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[1]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 2`),'Second Worker proposal missing');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form fieldset[data-worker-id="${workers[1]}"] select[name$="[service_id]"]').value`),services[1].id);
  await save('#zone-assignments-form','#zone-save-assignments');
  await until(async()=>(await api(assignmentPath(zone.id))).assignments.length===2,'Canonical assignment save failed');
  await clean('#zone-assignments-form');
  for(const worker of workers) assert.deepEqual(await api(`/workers/${worker}/targets`),[],'Data save must not publish');
  const exports = [await publish(workers[0])];
  assert.match(exports[0].toml,/data-workflow\.test\./);

  // A concurrent HTTP write proves stale UI drafts cannot overwrite canonical data.
  await navigate(detail(zone.id));
  const current = await api(`/zones/${zone.id}`);
  const apiRecords = structuredClone(current.records);
  apiRecords.find(record=>record.type==='A').data.address='192.0.2.11';
  await api('/commands/update_zone',{id:zone.id,expected_revision:current.revision,name,records:apiRecords});
  const addressField=await evaluate(`document.querySelector('#zone-form [name$="[address]"]').name`);
  await change('#zone-form',{[addressField]:'192.0.2.12'});
  await save('#zone-form','#zone-save');
  await until(()=>evaluate(`document.body.textContent.includes('Expected revision does not match current revision')`),'Stale draft did not report conflict');
  assert.equal(await evaluate(`document.querySelector('#zone-form [name$="[address]"]').value`),'192.0.2.12');
  assert.deepEqual((await api(`/zones/${zone.id}`)).records,apiRecords);
  confirmNext(true);
  await click('[phx-click="discard_content"]');
  await until(()=>evaluate(`document.querySelector('#zone-form [name$="[address]"]').value === '192.0.2.11'`),'Explicit canonical reread missing');
  await change('#zone-form',{[addressField]:'192.0.2.20'});
  await save('#zone-form','#zone-save');
  await clean('#zone-form');
  await tab(zone.id,'versions');
  await click('#zone-confirm-version');
  await until(async()=>(await api(`/zones/${zone.id}/versions`)).length===2,'Second immutable version missing');
  const versions=await api(`/zones/${zone.id}/versions`);
  const v2=versions.find(version=>version.version===2);
  assert.ok(v2,'Confirmed version 2 identity missing');
  assert.deepEqual(versions.find(version=>version.id===v1.id),v1,'Draft edits mutated v1');
  assert.ok((await api(assignmentPath(zone.id))).assignments.every(row=>row.resource_version_id===v1.id),'Assignments advanced automatically');

  // Both editors remain mounted: save one while retaining the other's proposal.
  await tab(zone.id,'application');
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[2]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 3`),'Third Worker proposal missing');
  const proposed = await evaluate(`document.querySelector('#zone-assignments-form fieldset[data-worker-id="${workers[2]}"] select[name$="[resource_version_id]"]').name`);
  await change('#zone-assignments-form',{[proposed]:v1.id});
  await tab(zone.id,'edit');
  await change('#zone-form',{[addressField]:'192.0.2.21'});
  await save('#zone-form','#zone-save');
  await clean('#zone-form');
  await tab(zone.id,'application');
  assert.equal(await evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length`),3,'Content save discarded assignment proposal');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form').dataset.editorDirty`),'true');
  await tab(zone.id,'edit');
  await change('#zone-form',{[addressField]:'192.0.2.22'});
  await tab(zone.id,'application');
  confirmNext(false);
  await toolbar(-1);
  await until(dialogHandled,'Dirty Back did not request confirmation');
  await until(()=>evaluate(`location.pathname === ${JSON.stringify(detail(zone.id,'application'))}`),'Cancelled Back left the dirty editor');
  assert.equal(await evaluate(`document.querySelector('#zone-form [name$="[address]"]').value`),'192.0.2.22');
  await save('#zone-assignments-form','#zone-save-assignments');
  await until(async()=>(await api(assignmentPath(zone.id))).assignments.length===3,'Additional service assignment missing');
  await clean('#zone-assignments-form');
  await tab(zone.id,'edit');
  assert.equal(await evaluate(`document.querySelector('#zone-form [name$="[address]"]').value`),'192.0.2.22','Assignment save discarded content proposal');
  confirmNext(false);
  await click('a[href="/management/dns/views"]');
  assert.equal(await evaluate('location.pathname'),detail(zone.id),'Dirty external navigation was accepted');
  confirmNext(true);
  await click('[phx-click="discard_content"]');
  await clean('#zone-form');
  await tab(zone.id,'application');
  const advanceFields=await evaluate(`Object.fromEntries(Array.from(document.querySelectorAll('#zone-assignments-form fieldset[data-worker-id="${workers[0]}"] select[name$="[resource_version_id]"]')).map(field=>[field.name,${JSON.stringify(v2.id)}]))`);
  await change('#zone-assignments-form',advanceFields);
  await save('#zone-assignments-form','#zone-save-assignments');
  await until(async()=>(await api(assignmentPath(zone.id))).assignments.filter(row=>row.worker_id===workers[0]).every(row=>row.resource_version_id===v2.id),'Explicit pinned-version advance missing');
  await clean('#zone-assignments-form');

  // Toolbar traversals are noncancelable in Chromium. Protect even input whose
  // change has not reached LiveView, and restore the exact history entry.
  await tab(zone.id,'versions');
  await toolbar(-1);
  await until(()=>evaluate(`location.pathname === ${JSON.stringify(detail(zone.id,'application'))}`),'Clean toolbar Back failed');
  await evaluate(`(() => {
    const form = document.querySelector('#zone-form');
    const input = form.elements.namedItem(${JSON.stringify(addressField)});
    form.closest('[phx-hook="EditorGuard"]').addEventListener('input',event=>event.stopPropagation(),{once:true});
    input.value = '192.0.2.24';
    input.dispatchEvent(new Event('input',{bubbles:true}));
  })()`);
  assert.equal(await evaluate(`document.querySelector('#zone-form').dataset.editorDirty`),'false','Rapid-input regression must precede server acknowledgement');
  for (const direction of [-1,-1,1]) {
    confirmNext(false);
    await toolbar(direction);
    await until(dialogHandled,'Unacknowledged toolbar traversal did not request confirmation');
    await until(()=>evaluate(`location.pathname === ${JSON.stringify(detail(zone.id,'application'))}`),'Cancelled toolbar traversal changed the address');
    assert.equal(await evaluate(`document.querySelector('#zone-form [name$="[address]"]').value`),'192.0.2.24','Cancelled toolbar traversal lost immediate input');
  }
  confirmNext(true);
  await click('[phx-click="discard_content"]');
  await until(()=>evaluate(`document.querySelector('#zone-form [name$="[address]"]').value === '192.0.2.21'`),'Explicit immediate-input discard failed');
  await toolbar(1);
  await until(()=>evaluate(`location.pathname === ${JSON.stringify(detail(zone.id,'versions'))}`),'Clean toolbar Forward failed');
  await toolbar(-1);
  await until(()=>evaluate(`location.pathname === ${JSON.stringify(detail(zone.id,'application'))}`),'Clean toolbar return failed');

  const beforeConflict=await api(assignmentPath(zone.id));
  const bVersion=await evaluate(`document.querySelector('#zone-assignments-form fieldset[data-worker-id="${workers[1]}"] select[name$="[resource_version_id]"]').name`);
  await change('#zone-assignments-form',{[bVersion]:v2.id});
  const outside=await api('/commands/set_zone_assignments',{zone_id:zone.id,expected_assignment_token:beforeConflict.assignment_token,expected_worker_revisions:beforeConflict.worker_revisions,assignments:beforeConflict.assignments.filter(row=>row.worker_id!==workers[1]).map(({worker_id,service_id,resource_version_id})=>({worker_id,service_id,resource_version_id}))});
  await save('#zone-assignments-form','#zone-save-assignments');
  await until(()=>evaluate(`!!document.querySelector('#zone-assignment-error')`),'Real assignment conflict missing');
  assert.deepEqual(await api(assignmentPath(zone.id)),outside,'Stale full-set replacement partially mutated data');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form fieldset[data-worker-id="${workers[1]}"] select[name$="[resource_version_id]"]').value`),v2.id,'Conflict discarded proposed selection');
  confirmNext(true);
  await click('[phx-click="refresh_assignments"]');
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 2`),'Explicit assignment-set reload missing');
  const invalid=await api(assignmentPath(zone.id));
  await rejectCommand('set_zone_assignments',{zone_id:zone.id,expected_assignment_token:invalid.assignment_token,expected_worker_revisions:invalid.worker_revisions,assignments:[{worker_id:workers[1],service_id:services[0].id,resource_version_id:v2.id}]},404);
  assert.deepEqual(await api(assignmentPath(zone.id)),invalid,'Wrong-scope rejection mutated assignments');
  exports.push(await publish(workers[0]));
  assert.equal(exports[1].revision,2);

  // Rename the mutable draft; reference payloads and older export bytes stay pinned.
  zone=await api(`/zones/${zone.id}`);
  const renamed='renamed-data-workflow.test.';
  const renamedRecords=zone.records.map(record=>({...record,name:record.name.replace(name,renamed),data:Object.fromEntries(Object.entries(record.data).map(([key,value])=>[key,typeof value==='string'?value.replace(name,renamed):value]))}));
  zone=await api('/commands/update_zone',{id:zone.id,expected_revision:zone.revision,name:renamed,records:renamedRecords});
  const extraName='catalog-extra.test.';
  const extraRecords=records.map(record=>({...record,name:record.name.replace(name,extraName),data:Object.fromEntries(Object.entries(record.data).map(([key,value])=>[key,typeof value==='string'?value.replace(name,extraName):value]))}));
  await api('/commands/create_zone',{name:extraName,records:extraRecords});
  const catalog=await api('/zone-catalog?page_size=1');
  assert.equal(catalog.zones.length,1);
  assert.equal(catalog.total,2);
  assert.equal(catalog.has_next,true);
  assert.equal(Object.hasOwn(catalog.zones[0],'records'),false,'Catalog should return summaries');
  await navigate('/management/zones?page_size=1');
  assert.equal(await evaluate(`document.querySelector('#zone-count').dataset.displayed`),'1');
  await click('nav[aria-label="Zone catalog pages"] a[href*="page=2"]');
  await until(()=>evaluate(`location.search.includes('page=2')`),'Catalog next page failed');
  await navigate('/management/zones?search=renamed-data-workflow');
  assert.equal(await evaluate(`document.querySelector('#zone-count').dataset.displayed`),'1');
  for(const item of exports) assert.equal(await(await fetch(`${base}/api/workers/${workers[0]}/targets/${item.revision}/export`)).text(),item.toml);
  await navigate(`/server/${workers[0]}/dns/policy`);
  assert.match(await evaluate(`document.querySelector('#service-references').innerText`),/data-workflow\.test\./);
  assert.equal(await evaluate(`!!document.querySelector('#assignment-form')`),false);

  const otherViews=await api(viewPath(workers[2],services[2].id));
  const otherAcls=await api(aclPath(workers[2],services[2].id));
  await navigate(`/server/${workers[0]}/dns/views/${services[0].id}`);
  await change('#dns-view-form',{'view[name]':'data-view','view[priority]':'7','view[client_rules]':'allow networks 192.0.2.0/24'});
  await save('#dns-view-form','#dns-view-save');
  await until(async()=>(await api(viewPath(workers[0],services[0].id))).some(view=>view.name==='data-view'),'Scoped View save missing');
  await clean('#dns-view-form');
  assert.deepEqual(await api(viewPath(workers[2],services[2].id)),otherViews);
  assert.match(await evaluate(`document.querySelector('#dns-views-workflow').textContent`),/included in Worker targets/);
  await navigate('/management/dns/acl');
  assert.equal(await evaluate(`!!document.querySelector('#dns-acl-form')`),false,'Global ACL selector must not infer ownership');
  await navigate(`/server/${workers[0]}/dns/acl/${services[0].id}`);
  await change('#dns-acl-form',{'acl[name]':'data-acl','acl[description]':'Data workflow fixture','acl[rules]':'allow networks 192.0.2.0/24\ndeny any'});
  await save('#dns-acl-form','#dns-acl-form button[type="submit"]');
  await until(async()=>(await api(aclPath(workers[0],services[0].id))).some(acl=>acl.name==='data-acl'),'Scoped ACL save missing');
  await clean('#dns-acl-form');
  assert.deepEqual(await api(aclPath(workers[2],services[2].id)),otherAcls);

  await navigate('/system/ip-database');
  const digest=createHash('sha256').update(await readFile(process.env.MANAGEMENT_DATA_CITY_FILE)).digest('hex');
  await click('#ip-database-download-city');
  let successJob;
  await until(()=>evaluate(`!!document.querySelector('#ip-database-download-result')?.dataset.jobId`),'Persistent IP job identity missing');
  successJob=Number(await evaluate(`document.querySelector('#ip-database-download-result').dataset.jobId`));
  await until(async()=>(await api('/tasks/ip_city/jobs')).find(job=>job.id===successJob)?.state==='completed','Fixture-backed synchronization did not succeed');
  await verifyArtifact(digest);
  await writeFile(process.env.MANAGEMENT_DATA_SOURCE_FILE,'invalid compressed fixture');
  await click('#ip-database-download-city');
  let failedJob;
  await until(async()=>{failedJob=Number(await evaluate(`document.querySelector('#ip-database-download-result')?.dataset.jobId`));return failedJob>successJob;},'New synchronization intent reused old job');
  await until(async()=>['retryable','discarded'].includes((await api('/tasks/ip_city/jobs')).find(job=>job.id===failedJob)?.state),'Failed fixture synchronization did not report failure');
  await verifyArtifact(digest);
  await navigate(`/system/tasks/ip_city#task-job-${failedJob}`);
  assert.equal(await evaluate(`document.body.textContent.includes(${JSON.stringify(String(failedJob))})`),true);
  await navigate(detail(zone.id,'application'));
  if(process.env.MANAGEMENT_SCREENSHOT_PREFIX){
    const screenshot=await cdp('Page.captureScreenshot',{format:'png'});
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-data-desktop.png`,Buffer.from(screenshot.data,'base64'));
    await cdp('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'),true,'Data mobile overflow');
    const mobile=await cdp('Page.captureScreenshot',{format:'png'});
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-data-mobile.png`,Buffer.from(mobile.data,'base64'));
  }
  await dnsPolicyResourceSmoke({navigate, evaluate, until, click, workers});
  await cloudProviderModalSmoke({navigate, evaluate, until, click});
  const state={zone:await api(`/zones/${zone.id}`),versions:await api(`/zones/${zone.id}/versions`),assignments:await api(assignmentPath(zone.id)),workers,services,exports,digest,successJob,failedJob,views:await api(viewPath(workers[0],services[0].id)),acls:await api(aclPath(workers[0],services[0].id))};
  await writeFile(stateFile,JSON.stringify(state,null,2));
  console.log('PASS Data browser: zero-Worker draft/confirmation, one DNS service per Worker, independent editors, immutable v1/v2 and exports, real draft/assignment conflicts, UI/API parity, scoped View/ACL, fixture success/failure and durable artifact selection');
}


async function cloudProviderModalSmoke({navigate, evaluate, until, click}) {
  const waitForModal = () => until(() => evaluate(`!!document.querySelector('.schema-form')`), 'React schema form mounted');
  const field = (path, value) => evaluate(`(() => {
    const control = document.querySelector('[data-field-path="/' + ${JSON.stringify(path)} + '"]');
    const input = control?.matches('input') ? control : control?.querySelector('input');
    if (!input) throw new Error(document.querySelector('.schema-form').outerHTML.slice(0, 4000));
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(value)});
    input.dispatchEvent(new Event('input', {bubbles: true}));
  })()`);
  const pick = async (path, text) => {
    await evaluate(`(() => {
      const field = document.querySelector('[data-field-path="/' + ${JSON.stringify(path)} + '"]');
      (field.matches('[role=combobox],button,input') ? field : field.querySelector('[role=combobox],button,input')).click();
    })()`);
    const match = `Array.from(document.querySelectorAll('[role=option]')).find(el => el.textContent.includes(${JSON.stringify(text)}))`;
    await until(() => evaluate(`!!(${match})`), `Select option ${text}`);
    await evaluate(`(${match}).click()`);
  };
  const submit = () => click('.schema-form button[type=submit]');
  await navigate('/system/cloud-providers');
  await click('#cloud-provider-new');
  await waitForModal();
  await submit();
  await until(() => evaluate(`!!document.querySelector('.schema-form [aria-invalid=true]')`), 'Schema validation requires provider fields');
  await pick('kind', 'Cloudflare DNS');
  await submit();
  await until(() => evaluate(`!!document.querySelector('input[type=password][data-field-path="/api_token"]')`), 'Cloudflare credentials form');
  assert.equal(await evaluate(`document.querySelector('dialog [data-field-path]').dataset.fieldPath`), '/name');
  await field('name', 'Data Workflow Cloud');
  await submit();
  await until(() => evaluate(`document.querySelector('[data-field-path="/api_token"]').getAttribute('aria-invalid') === 'true'`), 'Cloudflare requires an API token');
  await field('api_token', 'browser-test-token');
  await field('account_id', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  await submit();
  await until(() => evaluate(`document.body.innerText.includes('Data Workflow Cloud') && !document.querySelector('.schema-form')`), 'Create provider from React modal');

  await evaluate(`Array.from(document.querySelectorAll('tr')).find(row => row.textContent.includes('Data Workflow Cloud')).querySelector('[phx-click="edit"]').click()`);
  await waitForModal();
  assert.equal(await evaluate(`document.querySelector('dialog [data-field-path]').dataset.fieldPath`), '/name');
  assert.equal(await evaluate(`document.querySelector('[data-field-path="/name"]').value`), 'Data Workflow Cloud');
  assert.equal(await evaluate(`document.querySelector('[data-field-path="/api_token"]').value`), '');
  await field('name', 'Data Workflow Cloud edited');
  await submit();
  await until(() => evaluate(`document.body.innerText.includes('Data Workflow Cloud edited') && !document.querySelector('.schema-form')`), 'Edit provider from React modal');

  await navigate('/management/zones');
  assert.equal(await evaluate(`!!document.querySelector('a[href="/management/zones/cloud"]')`), false);
  await click('a[href="/management/zones/new"]');
  await until(() => evaluate(`!!document.querySelector('a[href="/management/zones/new/cloud"]')`), 'New Zone type choices');
  await click('a[href="/management/zones/new/cloud"]');
  await until(() => evaluate(`!!document.querySelector('#cloud-dns-import-binding')`), 'Cloud-synced authoritative zone setup');
  await click('#cloud-dns-import-binding');
  const remoteZone = 'cccccccccccccccccccccccccccccccc';
  const cloudZoneSelect = '#cloud-dns-import-zone';
  await until(() => evaluate(`!!document.querySelector('${cloudZoneSelect} option[value="${remoteZone}"]')`), 'Cloud zones loaded');
  assert.equal(await evaluate(`document.querySelector('#cloud-dns-import-provider').selectedOptions[0].textContent.includes('Data Workflow Cloud edited')`), true);
  assert.equal(await evaluate(`document.querySelector('${cloudZoneSelect} option[value="${remoteZone}"]').textContent`), 'renamed-data-workflow.test.');
  assert.equal(await evaluate(`document.querySelector('${cloudZoneSelect}').options.length`), 3);
  await evaluate(`document.querySelector('${cloudZoneSelect}').value = '${remoteZone}'`);
  await click('#cloud-dns-import-form button[type=submit]');
  await until(() => evaluate(`!!document.querySelector('#cloud-dns-preview-pull') && !document.querySelector('#cloud-dns-import-modal')`), 'Provider binding accepted');
  assert.equal(await evaluate(`document.body.innerText.includes('Data Workflow Cloud edited')`), true);
  assert.equal(await evaluate(`document.querySelector('#cloud-dns-zone-name').textContent.trim()`), 'renamed-data-workflow.test.');
  await navigate('/management/zones/new/cloud');
  await until(() => evaluate(`document.querySelector('[phx-click="select"]')?.textContent.includes('renamed-data-workflow.test.')`), 'Pending import shows the zone name after reopening');
  assert.equal(await evaluate(`document.body.innerText.includes('${remoteZone}')`), false);
  console.log('PASS Cloud DNS: add and edit a provider, then import a listed zone by name');
}


async function dnsPolicyResourceSmoke({navigate, evaluate, until, click, workers}) {
  const modalReady = () => until(() => evaluate(`!!document.querySelector('.schema-form')`), 'DNS resource modal mounted');
  const setField = (path, value) => evaluate(`(() => {
    const control = document.querySelector('[data-field-path=' + JSON.stringify(${JSON.stringify(path)}) + ']');
    const input = control.matches('input') ? control : control.querySelector('input');
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, ${JSON.stringify(value)});
    input.dispatchEvent(new Event('input', {bubbles: true}));
  })()`);
  const selectWorkers = () => evaluate(`(() => {
    const controls = Array.from(document.querySelectorAll('.schema-form input[type=checkbox]'));
    for (const id of ${JSON.stringify(workers.slice(0, 2))}) {
      const checkbox = controls.find((input) => input.closest('label')?.textContent.includes(id));
      checkbox.click();
    }
  })()`);
  const submitModal = () => click('.schema-form button[type=submit]');

  await navigate('/management/dns/views');
  assert.equal(await evaluate(`!!document.querySelector('#dns-view-worker-selector')`), false);
  await click('#dns-view-new');
  await modalReady();
  await setField('/name', 'browser-recursion');
  await selectWorkers();
  await evaluate(`(() => {
    const field = document.querySelector('[data-field-path="/recursion_enabled"]');
    (field.matches('[role=switch]') ? field : field.querySelector('[role=switch]')).click();
  })()`);
  await submitModal();
  await until(() => evaluate(`document.querySelector('#dns-view-resources')?.textContent.includes('browser-recursion')`), 'View saved with multiple assigned Workers');

  await navigate('/management/dns/forward-zones');
  await click('#add-forward-zone');
  await modalReady();
  await setField('/name', 'forward-browser.test.');
  await setField('/forwarders/0/address', '127.0.0.1');
  await selectWorkers();
  await submitModal();
  await until(() => evaluate(`document.querySelector('#forward-zones')?.textContent.includes('forward-browser.test.')`), 'Forward zone saved with multiple assigned Workers');
  console.log('PASS DNS resource modals: forward zone and recursive View assigned to multiple Workers');
}
