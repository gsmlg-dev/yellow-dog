import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';

const sections = [
  ['nodes', 'Node Management', '/management/servers'],
  ['data', 'Data Configuration', '/management/zones'],
  ['monitoring', 'Monitoring', '/management'],
  ['system', 'System Configuration', '/system/process-map'],
];

export function navigationSmoke({ cdp, evaluate, navigate, until }) {
  async function click(selector) {
    const point = await evaluate(`(() => {
      const element = document.querySelector(${JSON.stringify(selector)});
      if (!element) throw new Error('Missing click target: ' + ${JSON.stringify(selector)});
      element.scrollIntoView({ block: 'center', inline: 'nearest' });
      const box = element.getBoundingClientRect();
      return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
    })()`);
    await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', clickCount: 1, ...point });
    await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', clickCount: 1, ...point });
  }

  async function key(key, selector) {
    if (selector) await evaluate(`document.querySelector(${JSON.stringify(selector)}).focus()`);
    const code = key === ' ' ? 'Space' : key;
    const windowsVirtualKeyCode = { Enter: 13, Escape: 27, ' ': 32 }[key];
    await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode });
    await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode });
  }

  async function reload() {
    const beforeReload = (await cdp('Page.getFrameTree')).frameTree.frame.loaderId;
    await cdp('Page.reload', { ignoreCache: true });
    await until(async () => (await cdp('Page.getFrameTree')).frameTree.frame.loaderId !== beforeReload, 'Browser did not perform a real refresh');
    await until(() => evaluate(`!!document.querySelector('.phx-connected')`), 'LiveView did not reconnect after refresh');
  }

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

  async function collapsible() {
    await navigate('/management/netman');
    await selected('nodes', 'netmans');
    await screenshot('desktop-netman');
    const toggle = '#app-sidebar-navigation [data-left-menu-toggle]';
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-controls')`), 'app-sidebar-navigation-scroll');
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded')`), 'true');
    assert.equal(await evaluate(`!!document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-label')`), true, 'Desktop toggle must have an accessible name');

    const groupId = await evaluate(`document.querySelector('details[data-nav-group]').id`);
    assert.ok(groupId, 'Collapsible groups need stable IDs');
    const summary = `#${groupId} > summary`;
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), true);
    await click(summary);
    await until(() => evaluate(`!document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), 'Pointer did not collapse the menu group');
    await key('Enter', summary);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), 'Enter did not expand the menu group');
    await key(' ', summary);
    await until(() => evaluate(`!document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), 'Space did not collapse the menu group');
    const expanded = await evaluate(`({ sidebar: document.querySelector('#app-sidebar').getBoundingClientRect().width, main: document.querySelector('main').getBoundingClientRect().width })`);
    await key('Enter', toggle);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded') === 'false' && document.querySelector('#app-sidebar').getBoundingClientRect().width < ${expanded.sidebar - 80} && document.querySelector('main').getBoundingClientRect().width > ${expanded.main + 80}`), 'Desktop sidebar did not collapse and reclaim content space');
    await screenshot('desktop-compact');
    await key(' ', toggle);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded') === 'true' && document.querySelector('#app-sidebar').getBoundingClientRect().width > ${expanded.sidebar - 5}`), 'Space did not expand the desktop sidebar');
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), false, 'Expanding the rail lost the closed group state');
    await key('Enter', summary);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(`#${groupId}`)}).open`), 'Menu group did not reopen after expanding the rail');
    await click(toggle);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded') === 'false'`), 'Pointer did not collapse the sidebar');
    await click('nav[aria-label="Main navigation"] a[data-section="data"]');
    await until(() => evaluate(`location.pathname === '/management/zones' && !!document.querySelector('.phx-connected')`), 'Live navigation failed with the sidebar collapsed');
    await selected('data', 'dns_zones');
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded')`), 'false', 'Live navigation lost the compact sidebar preference');
    await reload();
    await selected('data', 'dns_zones');
    await until(() => evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded') === 'false' && document.querySelector('#app-sidebar').getBoundingClientRect().width < ${expanded.sidebar - 80}`), 'Refresh lost the compact sidebar preference');
    await key(' ', toggle);
    await until(() => evaluate(`document.querySelector(${JSON.stringify(toggle)}).getAttribute('aria-expanded') === 'true' && document.querySelector('#app-sidebar').getBoundingClientRect().width > ${expanded.sidebar - 5}`), 'Space did not expand the desktop sidebar');
    assert.equal(await evaluate(`document.documentElement.scrollWidth <= innerWidth`), true, 'Expanded desktop navigation overflows');

    for (const theme of ['sunshine', 'moonlight']) {
      await click('#theme-toggle > summary');
      await click(`#theme-toggle label[for="theme-toggle-${theme}"]`);
      await until(() => evaluate(`document.documentElement.dataset.theme === ${JSON.stringify(theme)}`), `${theme} theme did not activate`);
      if (await evaluate(`document.querySelector('#theme-toggle').open`)) await click('#theme-toggle > summary');
      await selected('data', 'dns_zones');
      assert.equal(await evaluate(`getComputedStyle(document.querySelector('nav[aria-label="Main navigation"] a')).color !== getComputedStyle(document.querySelector('.navbar')).backgroundColor`), true, `Primary navigation is invisible in ${theme}`);
      assert.equal(await evaluate(`document.querySelector('#app-sidebar').scrollWidth <= document.querySelector('#app-sidebar').clientWidth`), true, `Sidebar overflows in ${theme}`);
      await screenshot(`desktop-${theme}`);
    }
  }

  async function scrollPreserved() {
    await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 420, deviceScaleFactor: 1, mobile: false });
    await navigate('/management/zones');
    const scrollTarget = '#app-sidebar-navigation [data-left-menu-scroll]';
    const point = await evaluate(`(() => {
      const box = document.querySelector(${JSON.stringify(scrollTarget)}).getBoundingClientRect();
      return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
    })()`);
    await cdp('Input.dispatchMouseEvent', { type: 'mouseWheel', deltaX: 0, deltaY: 160, ...point });
    await until(() => evaluate(`document.querySelector(${JSON.stringify(scrollTarget)}).scrollTop > 0`), 'The native menu scroll viewport did not scroll');
    const saved = await evaluate(`document.querySelector(${JSON.stringify(scrollTarget)}).scrollTop`);
    await click('nav[aria-label="Main navigation"] a[data-section="nodes"]');
    await until(() => evaluate(`location.pathname === '/management/servers' && !!document.querySelector('.phx-connected')`), 'Switching away from a scrolled section failed');
    await selected('nodes', 'workers');
    await click('nav[aria-label="Main navigation"] a[data-section="data"]');
    await until(() => evaluate(`location.pathname === '/management/zones' && !!document.querySelector('.phx-connected')`), 'Returning to a scrolled section failed');
    await selected('data', 'dns_zones');
    await until(() => evaluate(`Math.abs(document.querySelector(${JSON.stringify(scrollTarget)}).scrollTop - ${saved}) <= 1`), 'Returning to Data lost its menu scroll position');
    await cdp('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
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
    await collapsible();
    await scrollPreserved();
    await cdp('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
    assert.equal(await evaluate(`document.querySelector('#mobile-navigation-toggle').getAttribute('aria-expanded')`), 'false');
    await click('#mobile-navigation-toggle');
    await until(() => evaluate(`document.querySelector('#mobile-navigation-toggle').getAttribute('aria-expanded') === 'true'`), 'Mobile toggle did not announce the expanded state');
    await key('Escape');
    await until(() => evaluate(`!document.querySelector('#yd-layout').classList.contains('yd-sidebar-open') && document.querySelector('#mobile-navigation-toggle').getAttribute('aria-expanded') === 'false'`), 'Escape did not close the mobile drawer');
    await click('#mobile-navigation-toggle');
    await until(() => evaluate(`document.querySelector('#yd-layout').classList.contains('yd-sidebar-open')`), 'Mobile drawer did not reopen');
    await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', clickCount: 1, x: 385, y: 400 });
    await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', clickCount: 1, x: 385, y: 400 });
    await until(() => evaluate(`!document.querySelector('#yd-layout').classList.contains('yd-sidebar-open') && document.querySelector('#mobile-navigation-toggle').getAttribute('aria-expanded') === 'false'`), 'Overlay did not close the mobile drawer');
    for (const [section, , path] of sections) {
      await click('#mobile-navigation-toggle');
      await until(() => evaluate(`document.querySelector('#yd-layout').classList.contains('yd-sidebar-open')`), 'Mobile drawer did not open');
      assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Mobile navigation"] a[data-section]')).map(link => link.dataset.section)`), sections.map(([id]) => id));
      assert.equal(await evaluate(`Array.from(document.querySelectorAll('nav[aria-label="Mobile navigation"] a[data-section]')).every(link => { const box = link.getBoundingClientRect(); return box.width > 0 && box.height > 0 && box.left >= 0 && box.right <= innerWidth; })`), true, 'All mobile sections must be visible and reachable');
      if (section === 'nodes') await screenshot('mobile-navigation');
      await click(`nav[aria-label="Mobile navigation"] a[data-section="${section}"]`);
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
