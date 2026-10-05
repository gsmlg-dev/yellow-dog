"""Run against a freshly migrated, disposable database and a built release.

YELLOW_DOG_MANAGEMENT_DATABASE_URL must be set. No Worker is launched.
Requests are unauthenticated; the disposable smoke port defaults to 14280.
python3 test/release_smoke.py /absolute/release/bin/yellow_dog_management
"""
import json
from concurrent.futures import ThreadPoolExecutor
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

binary = pathlib.Path(sys.argv[1]).resolve()
port = int(os.environ.get('YELLOW_DOG_MANAGEMENT_PORT', '14280'))
base = f'http://127.0.0.1:{port}/api'
env = dict(os.environ, YELLOW_DOG_MANAGEMENT_PORT=str(port), RELEASE_DISTRIBUTION='none')
env.pop('YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN', None)
log = open('/tmp/yellow-dog-management-release-smoke.log', 'w')
process = None


def request(path, body=None, key=None, raw=False, expected=200):
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers.update({'Content-Type': 'application/json', 'Idempotency-Key': key or str(uuid.uuid4())})
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    result = response.read()
    assert response.status == expected, (path, response.status, result)
    if raw:
        return result
    result = json.loads(result)
    return result.get('data', result)


def mutate(operation, body, key=None, expected=200):
    return request('/commands/' + operation, body, key, expected=expected)


def start():
    global process
    process = subprocess.Popen([str(binary), 'start'], env=env, cwd=binary.parent.parent, stdout=log, stderr=log)
    for _ in range(100):
        if process.poll() is not None:
            raise AssertionError('Release exited; inspect /tmp/yellow-dog-management-release-smoke.log')
        try:
            request('/workers')
            listeners = subprocess.check_output(['ss', '-lntup'], text=True)
            own = [line for line in listeners.splitlines() if f'pid={process.pid},' in line]
            assert len(own) == 1 and own[0].startswith('tcp ') and f'127.0.0.1:{port} ' in own[0], own
            print('Management listeners:', own[0], flush=True)
            return
        except (OSError, AssertionError):
            time.sleep(.1)
    raise AssertionError('Release never exposed unauthenticated API')


def stop():
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=15)


def zone(name, address='192.0.2.1'):
    return {'name': name, 'records': [
        {'name': name, 'type': 'SOA', 'ttl': 300, 'data': {'mname': 'ns.' + name, 'rname': 'hostmaster.' + name, 'serial': 1, 'refresh': 3600, 'retry': 600, 'expire': 86400, 'minimum': 300}},
        {'name': name, 'type': 'NS', 'ttl': 300, 'data': {'host': 'ns.' + name}},
        {'name': 'ns.' + name, 'type': 'A', 'ttl': 300, 'data': {'address': address}}]}


try:
    names = [path.name for path in (binary.parent.parent / 'lib').iterdir()]
    forbidden = ('yellow_dog_worker-', 'yellow_dog_dns-', 'yellow_dog_dhcp', 'yellow_dog_console-', 'yellow_dog_management_core-', 'yellow_dog_server_agent-', 'yellow_dog_netman_agent-', 'abyss-', 'ex_dns-', 'concord-')
    assert not any(name.startswith(forbidden) for name in names), names
    print('Release dependency boundary:', ', '.join(sorted(names)), flush=True)
    start()
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/management.css', timeout=10) as stylesheet:
        assert stylesheet.headers.get_content_type() == 'text/css'
        css = stylesheet.read().decode()
        assert '--color-primary' in css and '.btn' in css
    print('Packaged local DuskMoon stylesheet passed', flush=True)
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/management', timeout=10) as page:
        html = page.read().decode()
        assert 'yd-layout' in html and 'management-live.js' in html
        assert 'Operator token' not in html
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/management-live.js', timeout=10) as script:
        assert script.headers.get_content_type() in ('text/javascript', 'application/javascript')
        assert script.read()
    print('Packaged Console layout and LiveView client passed', flush=True)
    assert request('/workers') == []
    assert request('/zones') == []
    a = mutate('create_zone', zone('example.test.'))
    edited = dict(zone('example.test.', '192.0.2.2'), id=a['id'], expected_revision=a['revision'])
    a = mutate('update_zone', edited)
    assert request('/workers') == []
    confirm_body = {'id': a['id'], 'expected_revision': a['revision']}
    v = mutate('confirm_zone', confirm_body, 'durable-confirm')
    b = mutate('create_zone', zone('second.test.'))
    vb = mutate('confirm_zone', {'id': b['id'], 'expected_revision': b['revision']})
    unused = mutate('create_zone', zone('unassigned.test.'))
    exports, targets = {}, {}
    for i in range(4):
        worker_id = f'logical-{i}'
        w = mutate('create_worker', {'id': worker_id, 'name': f'Logical Worker {i}', 'expected_capabilities': ['dns']})
        assert w['status'] == 'not_yet_connected' and w['actual_state'] == 'unknown'
        mutate('put_service', {'worker_id': worker_id, 'id': 'dns', 'type': 'dns', 'desired_state': 'stopped', 'config': {'listen_address': '127.0.0.1', 'port': 15353}, 'expected_revision': w['revision']})
        w = request('/workers/' + worker_id)
        mutate('assign', {'worker_id': worker_id, 'service_id': 'dns', 'resource_version_id': v['id'], 'expected_revision': w['revision']})
        w = request('/workers/' + worker_id)
        target = mutate('confirm_target', {'worker_id': worker_id, 'expected_revision': w['revision']})
        assert target['status'] == 'prepared' and target['actual_state'] == 'unknown'
        assert [r['id'] for r in target['plan']['resources']] == [a['id']]
        assert target['plan']['services'][0]['desired_state'] == 'stopped'
        targets[worker_id] = target
        exports[worker_id] = request(f'/workers/{worker_id}/targets/{target["revision"]}/export', raw=True)
    worker_id = 'logical-0'
    w = request('/workers/' + worker_id)
    mutate('assign', {'worker_id': worker_id, 'service_id': 'dns', 'resource_version_id': vb['id'], 'expected_revision': w['revision']})
    w = request('/workers/' + worker_id)
    mutate('unassign', {'worker_id': worker_id, 'service_id': 'dns', 'resource_id': a['id'], 'expected_revision': w['revision']})
    preview = request('/workers/' + worker_id + '/preview')
    assert [r['id'] for r in preview['plan']['resources']] == [b['id']]
    assert preview['plan']['services'][0]['desired_state'] == 'stopped'
    assert preview['diff']['resources']['removed'] == [a['id']]
    print('A1-A5/A11: fresh startup, zero-Worker DNS edits, four logical targets, exact assignments, stopped-state removal passed', flush=True)
    # HTTP requests acquire independent database pool connections (not one shared sandbox connection).
    vc = mutate('confirm_zone', {'id': unused['id'], 'expected_revision': unused['revision']})
    concurrent_worker = request('/workers/logical-1')
    requests = [{'worker_id': 'logical-1', 'service_id': 'dns', 'resource_version_id': version['id'], 'expected_revision': concurrent_worker['revision']} for version in [vb, vc]]
    def attempt(body, operation='assign'):
        data = json.dumps(body).encode()
        headers = {'Content-Type': 'application/json', 'Idempotency-Key': str(uuid.uuid4())}
        try:
            response = urllib.request.urlopen(urllib.request.Request(base + '/commands/' + operation, data=data, headers=headers), timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        return body, response.status, json.loads(response.read())
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(attempt, requests))
    assert sorted(status for _, status, _ in outcomes) == [200, 409], outcomes
    for body, status, result in outcomes:
        if status == 409:
            assert result['error']['code'] == 'revision_conflict'
            body['expected_revision'] = request('/workers/logical-1')['revision']
            mutate('assign', body)
    aggregate = request('/workers/logical-1/preview')['plan']
    assert {r['id'] for r in aggregate['resources']} == {a['id'], b['id'], unused['id']}
    assert aggregate['services'][0]['desired_state'] == 'stopped'
    print('A6: concurrent HTTP assignments on independent DB connections produced one conflict; retry preserved all three zones', flush=True)
    assert request('/netmans') == []
    netman = mutate('create_netman', {'id': 'release-netman', 'name': 'Release Netman', 'profile_name': 'vm'})
    assert netman['status'] == 'not_yet_connected' and netman['actual_state'] == 'unknown'
    assert netman['last_seen_at'] is None
    netman_config = {'profiles': [{
        'profile_id': 'wired', 'interface': 'eth0', 'zone': 'lan',
        'ipv4': {'method': 'manual', 'address': '192.0.2.10/24', 'gateway': '192.0.2.1', 'dns': ['192.0.2.53'], 'dns_search': ['example.test']},
        'ipv6': {'method': 'disabled'}
    }], 'resolved': {'upstreams': ['192.0.2.53'], 'search_domains': ['example.test']}}
    draft = mutate('update_netman_config', {'id': netman['id'], 'expected_revision': 1, 'document': netman_config})
    first_netman_version = mutate('confirm_netman_config', {'id': netman['id'], 'expected_revision': draft['revision']}, 'durable-netman-confirm')
    netman_requests = []
    for address in ['192.0.2.11/24', '192.0.2.12/24']:
        candidate = json.loads(json.dumps(draft['document']))
        candidate['profiles'][0]['ipv4']['address'] = address
        netman_requests.append({'id': netman['id'], 'expected_revision': draft['revision'], 'document': candidate})
    with ThreadPoolExecutor(max_workers=2) as pool:
        netman_outcomes = list(pool.map(lambda body: attempt(body, 'update_netman_config'), netman_requests))
    assert sorted(status for _, status, _ in netman_outcomes) == [200, 409], netman_outcomes
    for body, status, result in netman_outcomes:
        if status == 409:
            assert result['error']['code'] == 'revision_conflict'
            body['expected_revision'] = request('/netmans/release-netman/config')['revision']
            mutate('update_netman_config', body)
    current_draft = request('/netmans/release-netman/config')
    second_netman_version = mutate('confirm_netman_config', {'id': netman['id'], 'expected_revision': current_draft['revision']})
    rollback = mutate('rollback_netman_config', {'id': netman['id'], 'expected_revision': current_draft['revision'], 'target_version': first_netman_version['version']})
    assert rollback['document'] == first_netman_version['document']
    assert rollback['digest'] == first_netman_version['digest']
    assert rollback['rollback_source_id'] == first_netman_version['id']
    assert rollback['actual_state'] == 'unknown' and rollback['status'] == 'prepared'
    assert request('/netmans/release-netman/versions') == [rollback, second_netman_version, first_netman_version]
    mutate('create_netman', {'id': 'observer', 'profile_name': 'observe_only'})
    rejected = mutate('confirm_netman_config', {'id': 'observer', 'expected_revision': 1}, expected=422)
    assert rejected['error']['code'] == 'read_only'
    netmans_before = request('/netmans')
    netman_draft_before = request('/netmans/release-netman/config')
    netman_versions_before = request('/netmans/release-netman/versions')
    print('Netman: real concurrent PG requests, prepared immutable history, desired rollback and observe-only rejection passed; no host-network operations', flush=True)
    before = request('/workers/' + worker_id)
    stop()
    start()
    assert request('/workers/' + worker_id) == before
    assert request('/netmans') == netmans_before
    assert request('/netmans/release-netman/config') == netman_draft_before
    assert request('/netmans/release-netman/versions') == netman_versions_before
    assert mutate('confirm_netman_config', {'id': netman['id'], 'expected_revision': draft['revision']}, 'durable-netman-confirm') == first_netman_version
    assert mutate('confirm_zone', confirm_body, 'durable-confirm') == v
    assert len(request('/zones/' + a['id'] + '/versions')) == 1
    for wid, target in targets.items():
        assert request(f'/workers/{wid}/targets/{target["revision"]}') == {k: value for k, value in target.items() if k != 'worker_revision'}
        assert request(f'/workers/{wid}/targets/{target["revision"]}/export', raw=True) == exports[wid]
    assert len(request('/zones')) == 3
    print('A7-A8: real release process restart preserved drafts, assignments, versions, targets and durable idempotency; historical exports byte-identical', flush=True)
    print('Netman: independent process restart preserved node metadata, desired draft, all versions and exact idempotent result', flush=True)
    print('RELEASE SMOKE PASSED', flush=True)
finally:
    stop()
    log.close()
