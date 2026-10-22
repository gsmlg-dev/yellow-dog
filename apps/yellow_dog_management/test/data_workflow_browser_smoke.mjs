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
  await navigate('/management/zones/new');
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
  const ordered = values => [...values].sort((left,right)=>`${left.name}:${left.type}`.localeCompare(`${right.name}:${right.type}`));
  assert.deepEqual(ordered(zone.records), ordered(records));
  assert.deepEqual(await api('/workers'), []);
  await tab(zone.id,'versions');
  await click('#zone-confirm-version');
  await until(async () => (await api(`/zones/${zone.id}/versions`)).length === 1, 'Zero-Worker confirmation failed');
  const v1 = (await api(`/zones/${zone.id}/versions`))[0];
  await click('#zone-confirm-version');
  assert.equal((await api(`/zones/${zone.id}/versions`)).length, 1, 'Same saved draft should reuse its version');
  assert.deepEqual(await api('/workers'), []);

  const workers = [];
  for (const workerName of ['Data Worker A','Data Worker B']) {
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
  for (const [worker,label,port] of [[workers[0],'dns',18553],[workers[0],'dns-secondary',18554],[workers[1],'dns',18555]]) {
    await navigate(`/server/${worker}/services/new`);
    await submit('#service-form',{'service[id]':label,'service[listen_address]':'127.0.0.1','service[port]':String(port),'service[desired_state]':'stopped'});
    let service;
    await until(async()=>{service=(await api(`/workers/${worker}`)).services.find(item=>item.instance_id===label);return !!service;},'Node DNS instance missing');
    services.push(service);
    await until(()=>evaluate(`document.querySelector('#node-workflow').dataset.dirty === 'false'`),'Service save not acknowledged');
  }
  await navigate(detail(zone.id,'application'));
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[0]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 1`),'First proposal missing');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form select[name$="[service_id]"]').value`),'','Multiple services must require explicit choice');
  const serviceSelect = await evaluate(`document.querySelector('#zone-assignments-form select[name$="[service_id]"]').name`);
  await change('#zone-assignments-form',{[serviceSelect]:services[0].id});
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[1]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 2`),'Second Worker proposal missing');
  assert.equal(await evaluate(`document.querySelector('#zone-assignments-form fieldset[data-worker-id="${workers[1]}"] select[name$="[service_id]"]').value`),services[2].id);
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
  await click(`[phx-click="add_assignment_worker"][phx-value-id="${workers[0]}"]`);
  await until(()=>evaluate(`document.querySelectorAll('#zone-assignments-form fieldset').length === 3`),'Additional service proposal missing');
  const proposed = await evaluate(`Array.from(document.querySelectorAll('#zone-assignments-form fieldset')).find(row=>row.dataset.workerId===${JSON.stringify(workers[0])} && row.querySelector('select[name$="[service_id]"]').value==='').id`);
  const proposedFields=await evaluate(`Object.fromEntries(Array.from(document.querySelectorAll('#${proposed} select')).map(field=>[field.name,field.name.endsWith('[service_id]')?${JSON.stringify(services[1].id)}:${JSON.stringify(v1.id)}]))`);
  await change('#zone-assignments-form',proposedFields);
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
  await navigate(`/server/${workers[0]}/services/${services[0].id}/edit`);
  assert.match(await evaluate(`document.querySelector('#service-references').innerText`),/data-workflow\.test\./);
  assert.equal(await evaluate(`!!document.querySelector('#assignment-form')`),false);

  const otherViews=await api(viewPath(workers[0],services[1].id));
  const otherAcls=await api(aclPath(workers[0],services[1].id));
  await navigate(`/server/${workers[0]}/dns/views/${services[0].id}`);
  await change('#dns-view-form',{'view[name]':'data-view','view[priority]':'7','view[client_rules]':'allow networks 192.0.2.0/24'});
  await save('#dns-view-form','#dns-view-save');
  await until(async()=>(await api(viewPath(workers[0],services[0].id))).some(view=>view.name==='data-view'),'Scoped View save missing');
  await clean('#dns-view-form');
  assert.deepEqual(await api(viewPath(workers[0],services[1].id)),otherViews);
  assert.match(await evaluate(`document.querySelector('#dns-views-workflow').textContent`),/not included in the current Worker target\/export/);
  await navigate('/management/dns/acl');
  assert.equal(await evaluate(`!!document.querySelector('#dns-acl-form')`),false,'Global ACL selector must not infer ownership');
  await navigate(`/server/${workers[0]}/dns/acl/${services[0].id}`);
  await change('#dns-acl-form',{'acl[name]':'data-acl','acl[description]':'Data workflow fixture','acl[rules]':'allow networks 192.0.2.0/24\ndeny any'});
  await save('#dns-acl-form','#dns-acl-form button[type="submit"]');
  await until(async()=>(await api(aclPath(workers[0],services[0].id))).some(acl=>acl.name==='data-acl'),'Scoped ACL save missing');
  await clean('#dns-acl-form');
  assert.deepEqual(await api(aclPath(workers[0],services[1].id)),otherAcls);

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
  const state={zone:await api(`/zones/${zone.id}`),versions:await api(`/zones/${zone.id}/versions`),assignments:await api(assignmentPath(zone.id)),workers,services,exports,digest,successJob,failedJob,views:await api(viewPath(workers[0],services[0].id)),acls:await api(aclPath(workers[0],services[0].id))};
  await writeFile(stateFile,JSON.stringify(state,null,2));
  console.log('PASS Data browser: zero-Worker draft/confirmation, explicit multiple services, independent editors, immutable v1/v2 and exports, real draft/assignment conflicts, UI/API parity, scoped View/ACL, fixture success/failure and durable artifact selection');
}
