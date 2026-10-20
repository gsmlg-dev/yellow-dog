import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';

const sections = [
  ['nodes', 'Node Management', '/management/servers'],
  ['data', 'Data Configuration', '/management/zones'],
  ['monitoring', 'Monitoring', '/management'],
  ['system', 'System Configuration', '/system/process-map'],
];

export function navigationSmoke({ cdp, evaluate, navigate, until }) {
  async function selected(section, item) {
    await until(() => evaluate(`document.querySelector('nav[aria-label="Main navigation"] a[aria-current="page"]')?.dataset.section === ${JSON.stringify(section)} && document.querySelector('#app-sidebar-navigation')?.dataset.section === ${JSON.stringify(section)}`), `Wrong primary navigation for ${section}`);
    if (item) {
      assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('#app-sidebar-navigation [data-nav-item][aria-current="page"]')).map(item => item.dataset.navItem)`), [item], 'Exactly the owning secondary item must be active');
    }
  }

  async function disabledEntries() {
    const entries = await evaluate(`Array.from(document.querySelectorAll('#app-sidebar-navigation [data-nav-item][aria-disabled="true"]')).map(item => ({
      text: item.textContent, href: item.getAttribute('href'),
      handlers: Array.from(item.attributes).filter(attribute => /^(phx-|data-phx-|on)/.test(attribute.name)).map(attribute => attribute.name),
      actionableChildren: item.querySelectorAll('a, button, input, [phx-click], [phx-submit]').length,
      explanation: item.getAttribute('title') || item.getAttribute('aria-describedby') || item.getAttribute('aria-label')
    }))`);
    for (const entry of entries) {
      assert.equal(entry.href, null, entry.text);
      assert.deepEqual(entry.handlers, [], entry.text);
      assert.equal(entry.actionableChildren, 0, entry.text);
      assert.ok(entry.explanation, `Disabled item needs an accessible explanation: ${entry.text}`);
    }
    assert.equal(await evaluate(`!!document.querySelector('#app-sidebar-navigation a[href="#"]')`), false);
  }

  async function screenshot(name) {
    if (!process.env.MANAGEMENT_SCREENSHOT_PREFIX) return;
    const result = await cdp('Page.captureScreenshot', { format: 'png' });
    await writeFile(`${process.env.MANAGEMENT_SCREENSHOT_PREFIX}-${name}.png`, Buffer.from(result.data, 'base64'));
  }

  async function global() {
    assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Main navigation"] a[data-section]')).map(link => [link.dataset.section, link.textContent.trim(), link.getAttribute('href')])`), sections, 'Desktop primary navigation must contain exactly four ordered sections');
    for (const [section, , path] of sections) {
      await evaluate(`document.querySelector('nav[aria-label="Main navigation"] a[data-section="${section}"]').click()`);
      await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected')`), `Section switch failed: ${section}`);
      await selected(section);
      await disabledEntries();
      if (section !== 'nodes') {
        assert.equal(await evaluate(`Array.from(document.querySelectorAll('#app-sidebar-navigation [data-nav-item][aria-disabled="true"]')).some(item => item.textContent.includes('Planned'))`), true, `${section} must expose its planned outline`);
      }
      await screenshot(`desktop-${section}`);
    }
    for (const [path, section, item] of [
      ['/system/ip-database', 'data', 'ip_database'],
      ['/system/mac-database', 'data', 'mac_database'],
      ['/management/dns/views', 'data', 'dns_views'],
      ['/management/config', 'nodes', 'config_targets'],
      ['/management/netman', 'nodes', 'netmans'],
      ['/management/events', 'monitoring', 'events'],
      ['/system/tasks', 'monitoring', 'tasks'],
      ['/system/logs/tasks', 'monitoring', 'logs'],
      ['/system/backups/restore', 'system', 'backups'],
    ]) {
      await navigate(path);
      await selected(section, item);
    }
    await cdp('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
    for (const [section, , path] of sections) {
      await evaluate(`document.querySelector('#mobile-navigation-toggle').click()`);
      await until(() => evaluate(`document.querySelector('#yd-layout').classList.contains('yd-sidebar-open')`), 'Mobile drawer did not open');
      assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Mobile navigation"] a[data-section]')).map(link => link.dataset.section)`), sections.map(([id]) => id));
      assert.equal(await evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Mobile navigation"] a[data-section]')).every(link => { const box = link.getBoundingClientRect(); return box.width > 0 && box.height > 0 && box.left >= 0 && box.right <= innerWidth; })`), true, 'All mobile sections must be visible and reachable');
      if (section === 'nodes') await screenshot('mobile-navigation');
      await evaluate(`document.querySelector('nav[aria-label="Mobile navigation"] a[data-section="${section}"]').click()`);
      await until(() => evaluate(`location.pathname === ${JSON.stringify(path)} && !!document.querySelector('.phx-connected')`), `Mobile section switch failed: ${section}`);
      await selected(section);
      await until(() => evaluate(`!document.querySelector('#yd-layout').classList.contains('yd-sidebar-open')`), 'Mobile drawer did not close after navigation');
      assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Mobile viewport overflows');
    }
    await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
    await navigate('/management');
  }

  async function scoped(workerId, serviceId, zoneId) {
    const prefix = `/server/${encodeURIComponent(workerId)}/dns`;
    const routes = [
      [`${prefix}/zones`, 'dns_zones'],
      [`${prefix}/zones/import`, 'dns_zones'],
      [`${prefix}/zones/${zoneId}/records/0/edit`, 'dns_zones'],
      [`${prefix}/zones/${zoneId}/records/bulk`, 'dns_zones'],
      [`${prefix}/views/${encodeURIComponent(serviceId)}`, 'dns_views'],
      [`${prefix}/acl/${encodeURIComponent(serviceId)}`, 'dns_acls'],
    ];
    for (const [path, item] of routes) {
      await navigate(`${path}?server_id[]=other&service_id=other#navigation`);
      await selected('data', item);
      assert.equal(await evaluate(`document.querySelector('#server-selection-form-select').value`), workerId, 'Scoped Data navigation lost the selected Worker');
      if (item === 'dns_views' || item === 'dns_acls') {
        const destination = item === 'dns_views' ? 'acl' : 'views';
        const otherItem = item === 'dns_views' ? 'dns_acls' : 'dns_views';
        assert.equal(await evaluate(`document.querySelector('#app-sidebar-navigation a[data-nav-item="${otherItem}"]').getAttribute('href')`), `${prefix}/${destination}/${encodeURIComponent(serviceId)}`, 'Switching scoped DNS data must preserve the service');
      }
    }
    const [aclPath] = routes.at(-1);
    const beforeReload = (await cdp('Page.getFrameTree')).frameTree.frame.loaderId;
    await cdp('Page.reload', { ignoreCache: true });
    await until(async () => (await cdp('Page.getFrameTree')).frameTree.frame.loaderId !== beforeReload, 'Browser did not perform a real refresh');
    await until(() => evaluate(`location.pathname === ${JSON.stringify(aclPath)} && !!document.querySelector('.phx-connected') && document.querySelector('#server-selection-form-select')?.value === ${JSON.stringify(workerId)}`), 'Refresh lost scoped Data selection');
    await selected('data', 'dns_acls');
    await evaluate(`document.querySelector('nav[aria-label="Main navigation"] a[data-section="monitoring"]').click()`);
    await until(() => evaluate(`location.pathname === '/management' && !!document.querySelector('.phx-connected')`), 'Live section navigation failed');
    await selected('monitoring');
    await evaluate('history.back()');
    await until(() => evaluate(`location.pathname === ${JSON.stringify(aclPath)} && !!document.querySelector('.phx-connected') && document.querySelector('#server-selection-form-select')?.value === ${JSON.stringify(workerId)}`), 'Browser back lost scoped Data selection');
    await selected('data', 'dns_acls');
    await evaluate('history.forward()');
    await until(() => evaluate(`location.pathname === '/management' && !!document.querySelector('.phx-connected')`), 'Browser forward failed');
    await selected('monitoring');
    await navigate(`/server/${encodeURIComponent(workerId)}/dashboard`);
  }

  return { global, scoped };
}
