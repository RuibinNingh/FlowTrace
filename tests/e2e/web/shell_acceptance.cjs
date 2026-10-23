// Real Chromium service-worker acceptance. Fixtures are synthetic JavaScript
// applications, so these checks prove the shell protocol, not Flutter business UI.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
const {randomUUID, createHash} = require('node:crypto');
const {spawnSync} = require('node:child_process');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '../../..');
const runId = randomUUID();
const output = path.join(root, 'outputs/validation/P6', runId);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p6-shell-${runId}`);
const receipt = {run_id: runId, kind: 'synthetic-shell-real-chromium', headed: true, personal_profile: false, checks: []};
let context;
let server;
let timeoutServer;
let migrationServer;
let current = 'A';
let fault = null;
const requests = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function makeRelease(version) {
  const directory = path.join(output, 'releases', version);
  await fs.mkdir(directory, {recursive: true});
  const web = path.join(root, 'apps/flowtrace/web');
  let index = await fs.readFile(path.join(web, 'index.html'), 'utf8');
  index = index.replace('$FLUTTER_BASE_HREF', '/');
  await fs.writeFile(path.join(directory, 'index.html'), index);
  await fs.copyFile(path.join(web, 'flowtrace_shell.js'), path.join(directory, 'flowtrace_shell.js'));
  await fs.writeFile(path.join(directory, 'flutter_bootstrap.js'), `const s=document.createElement('script');s.src='main.dart.js';document.body.append(s);`);
  await fs.writeFile(path.join(directory, 'main.dart.js'), `document.body.dataset.appVersion=${JSON.stringify(version)};document.body.append(Object.assign(document.createElement('main'),{textContent:'Synthetic shell fixture ${version}'}));const nav=document.createElement('button');nav.textContent='合成导航';Object.assign(nav.style,{position:'fixed',top:'16px',right:'16px'});nav.onclick=()=>{document.body.dataset.navigation='opened';};document.body.append(nav);`);
  await fs.writeFile(path.join(directory, 'sqlite3.wasm'), 'synthetic-shell-only-no-real-sqlite');
  await fs.writeFile(path.join(directory, 'drift_worker.js'), '// synthetic shell test only');
  await fs.writeFile(path.join(directory, 'late-resource.bin'), `${version}:${'complete-package-resource'.repeat(500)}`);
  const result = spawnSync(path.join(root, 'server/.venv/Scripts/python.exe'), [path.join(root, 'apps/flowtrace/tool/web_release/seal_release.py'), directory], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(await fs.readFile(path.join(directory, 'flowtrace-release.json'), 'utf8'));
}
async function startServer() {
  server = http.createServer(async (request, response) => {
    const requestUrl = new URL(request.url, 'http://localhost');
    const key = decodeURIComponent(requestUrl.pathname).slice(1) || 'index.html';
    const record = {release: current, key, fault, method: request.method, release_query: requestUrl.searchParams.get('flowtrace_release')};
    requests.push(record);
    response.on('finish', () => { record.response_status = response.statusCode; });
    if (/^(api|admin|auth)(\/|$)/.test(key)) {
      response.writeHead(200, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'}); response.end('{"synthetic":true}'); return;
    }
    if (key.includes('..') || key.includes('\\')) { response.writeHead(403); response.end(); return; }
    if (fault === 'missing' && key === 'late-resource.bin') { response.writeHead(404); response.end(); return; }
    if (fault === 'corrupt' && key === 'main.dart.js') { response.writeHead(200); response.end('wrong-hash'); return; }
    if (fault === 'interrupted' && key === 'late-resource.bin') {
      // Send a real partial body before disconnecting. Destroying a socket
      // before headers lets Chromium retry the GET invisibly across the next
      // deployed fixture, which can conflate two deliberate failure rounds.
      response.writeHead(200, {'Content-Type': 'application/octet-stream', 'Content-Length': '12502', 'Cache-Control': 'no-store'});
      response.write('truncated-release-body');
      setTimeout(() => response.destroy(), 20);
      return;
    }
    if (fault === 'slow' && key === 'late-resource.bin') await sleep(750);
    try {
      const bytes = await fs.readFile(path.join(output, 'releases', current, key));
      record.served_sha256 = createHash('sha256').update(bytes).digest('hex');
      const type = key.endsWith('.js') ? 'text/javascript' : key.endsWith('.html') ? 'text/html' : key.endsWith('.json') ? 'application/json' : 'application/octet-stream';
      response.writeHead(200, {'Content-Type': type, 'Cache-Control': 'no-store', 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp'});
      response.end(bytes);
    } catch (_) { response.writeHead(404); response.end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}/`;
}
async function launch() {
  context = await chromium.launchPersistentContext(profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
    viewport: {width: 1200, height: 800}, locale: 'zh-CN',
  });
  context.setDefaultTimeout(15000);
  receipt.browser = context.browser().version();
  receipt.resource_responses ||= [];
  context.on('response', async (response) => {
    const url = new URL(response.url());
    if (url.pathname !== '/late-resource.bin' || url.origin !== new URL(receipt.origin).origin) return;
    const headers = await response.allHeaders();
    receipt.resource_responses.push({status: response.status(), worker: response.request().serviceWorker()?.url() || null,
      from_service_worker: response.fromServiceWorker(), content_type: headers['content-type'] || null,
      server: headers.server || null, via: headers.via || null});
  });
}
async function loaded(page, version) {
  await page.waitForFunction((expected) => document.body.dataset.appVersion === expected, version, {timeout: 60000});
  const status = await page.evaluate(() => FlowTraceShell.status());
  assert.equal(status.complete, true);
  return status;
}
async function check(name, task) {
  receipt.phase = name;
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  await task();
  receipt.checks.push({name, result: 'passed'});
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(`PASS ${name}`);
}
async function updateAttempt(page, expectedRelease) {
  return page.evaluate(async (expected) => {
    const registration = await navigator.serviceWorker.getRegistration();
    const failures = new Set();
    const onMessage = (event) => { if (event.data?.type === 'FLOWTRACE_PREPARATION_FAILED') { failures.add(event.data.releaseId); (window.syntheticWorkerFailures ||= []).push(event.data); } };
    navigator.serviceWorker.addEventListener('message', onMessage);
    let lastUpdate = 0;
    try {
      const deadline = Date.now() + 15000;
      while (Date.now() < deadline) {
        // A failure message is sent before the install event rejects. Keep the
        // fault deployed until that actual installer has become terminal.
        if (failures.has(expected) && !registration.installing) return 'redundant';
        if (registration.waiting) {
          const status = await new Promise((resolve) => {
            const channel = new MessageChannel();
            const timer = setTimeout(() => { channel.port1.close(); resolve(null); }, 1000);
            channel.port1.onmessage = (event) => { clearTimeout(timer); channel.port1.close(); resolve(event.data); };
            registration.waiting.postMessage({type: 'FLOWTRACE_STATUS'}, [channel.port2]);
          });
          if (status?.releaseId === expected && status.complete) return 'installed';
        }
        // A page reload can launch an automatic check for the preceding faulty
        // version. Let that specific install settle before asking for the next
        // candidate; observe identity rather than any worker's redundant state.
        if (!registration.installing && Date.now() - lastUpdate >= 500) {
          lastUpdate = Date.now(); await registration.update();
        }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      return 'timeout';
    } finally { navigator.serviceWorker.removeEventListener('message', onMessage); }
  }, expectedRelease);
}
async function barrier(page, name) {
  await page.evaluate((label) => {
    window.prepared = 0; window.resumed = 0;
    FlowTraceShell.registerUpdateBarrier({prepare: async () => {
      window.prepared += 1;
      if (window.prepareDelay) await new Promise((resolve) => setTimeout(resolve, window.prepareDelay));
      window.paused = true;
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open('synthetic-shell-barrier', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('outbox');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      await new Promise((resolve, reject) => {
        const transaction = db.transaction('outbox', 'readwrite');
        transaction.objectStore('outbox').put({stableOperationId: label, persisted: true}, label);
        transaction.oncomplete = resolve; transaction.onerror = () => reject(transaction.error);
      });
      db.close(); return true;
    }, resume: () => { window.resumed += 1; window.paused = false; }});
  }, name);
}
async function stopActiveWorker(page, expectedScript) {
  const cdp = await context.newCDPSession(page);
  const versions = new Map();
  cdp.on('ServiceWorker.workerVersionUpdated', ({versions: updates}) => {
    for (const version of updates) versions.set(version.versionId, version);
  });
  await cdp.send('ServiceWorker.enable');
  let active;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && !active) {
    active = [...versions.values()].find((version) => version.status === 'activated' && version.scriptURL === expectedScript);
    if (!active) await sleep(20);
  }
  assert(active, 'Expected this fixture origin active worker');
  await cdp.send('ServiceWorker.stopWorker', {versionId: active.versionId});
  while (Date.now() < deadline && versions.get(active.versionId)?.runningStatus !== 'stopped') await sleep(20);
  assert.equal(versions.get(active.versionId)?.runningStatus, 'stopped');
  receipt.stopped_active_worker = {version_id: active.versionId, observed_running_status: 'stopped'};
  await cdp.detach();
}
async function main() {
  await fs.mkdir(output, {recursive: true});
  await fs.mkdir(profile); // existing profiles are never reused by a new run
  const releases = {};
  for (const name of ['A', 'B', 'C', 'D', 'E']) releases[name] = await makeRelease(name);
  const origin = await startServer();
  receipt.origin = origin; receipt.profile = profile; receipt.releases = Object.fromEntries(Object.entries(releases).map(([key, value]) => [key, value.release_id]));
  await launch();
  let page = context.pages()[0];
  await check('complete-first-install-and-api-exclusion', async () => {
    await page.goto(origin); const status = await loaded(page, 'A'); assert.equal(status.releaseId, releases.A.release_id);
    const installedNames = new Set(requests.filter((request) => request.release_query === releases.A.release_id).map((request) => request.key));
    assert.deepEqual([...installedNames].sort(), Object.keys(releases.A.resources).sort());
    await page.evaluate(async () => { await fetch('/api/private'); await fetch('/admin/private'); await fetch('/auth/private'); });
    const keys = await page.evaluate(async () => (await Promise.all((await caches.keys()).map(async (name) => (await (await caches.open(name)).keys()).map((r) => r.url)))).flat());
    assert(!keys.some((key) => /\/(api|admin|auth)\//.test(key)));
  });
  await check('offline-reload-and-new-tab', async () => {
    await context.setOffline(true); await page.reload(); await loaded(page, 'A');
    const cold = await context.newPage(); await cold.goto(origin); await loaded(cold, 'A'); await cold.close();
    await context.setOffline(false);
  });
  await check('offline-browser-process-cold-start', async () => {
    await context.close(); await launch(); await context.setOffline(true);
    page = context.pages()[0]; await page.goto(origin); await loaded(page, 'A');
    await context.setOffline(false);
  });
  await check('bad-hash-retains-complete-old-package', async () => {
    current = 'B'; fault = 'corrupt'; assert.equal(await updateAttempt(page, releases.B.release_id), 'redundant');
    await page.reload(); await loaded(page, 'A');
    assert.equal(await page.evaluate(async () => (await fetch('late-resource.bin')).text()), `A:${'complete-package-resource'.repeat(500)}`);
  });
  await check('missing-resource-retains-complete-old-package', async () => {
    current = 'C'; fault = 'missing'; assert.equal(await updateAttempt(page, releases.C.release_id), 'redundant');
    await context.setOffline(true); await page.reload(); await loaded(page, 'A'); await context.setOffline(false);
  });
  await check('interrupted-download-retains-old-package', async () => {
    current = 'D'; fault = 'interrupted'; assert.equal(await updateAttempt(page, releases.D.release_id), 'redundant');
    await page.reload(); await loaded(page, 'A');
  });
  let peer;
  await check('unprepared-tab-refuses-hot-upgrade', async () => {
    current = 'E'; fault = null;
    receipt.valid_candidate_attempts = [];
    let outcome;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      outcome = await updateAttempt(page, releases.E.release_id);
      receipt.valid_candidate_attempts.push({attempt, outcome, failures: await page.evaluate(() => window.syntheticWorkerFailures || [])});
      if (outcome === 'installed') break;
      // Deliberately destroyed preceding downloads can finish after deployment
      // changes. Any failed attempt must leave the verified old app usable;
      // retry only the same immutable valid candidate, never bypass integrity.
      assert.equal(outcome, 'redundant'); await loaded(page, 'A'); await sleep(200);
    }
    assert.equal(outcome, 'installed');
    peer = await context.newPage(); await peer.goto(origin); await loaded(peer, 'A');
    await barrier(page, 'tab-one');
    await page.evaluate(() => { window.prepareDelay = 200; });
    const result = await page.evaluate(() => FlowTraceShell.activateUpdate()); assert.equal(result.ok, false);
    await page.waitForFunction(() => window.resumed >= 1);
    await sleep(250);
    assert.equal(await page.evaluate(() => window.paused), false);
    await page.evaluate(() => { window.prepareDelay = 0; });
    await loaded(page, 'A'); await loaded(peer, 'A');
  });
  await check('active-worker-restart-keeps-late-tab-blocked-and-aborts-upgrade', async () => {
    await barrier(peer, 'tab-two');
    await page.evaluate(() => { window.prepareDelay = 5000; window.lastActivation = null; void FlowTraceShell.activateUpdate().then((result) => { window.lastActivation = result; }); });
    await page.waitForFunction(() => window.prepared === 2);
    await stopActiveWorker(page, new URL('flutter_service_worker.js', origin).href);
    const late = await context.newPage(); await late.goto(origin);
    await late.waitForFunction(() => document.querySelector('aside')?.textContent.includes('另一个窗口正在更新'));
    assert.equal(await late.evaluate(() => document.body.dataset.appVersion), undefined);
    await page.waitForFunction(() => window.lastActivation !== null);
    const result = await page.evaluate(() => window.lastActivation);
    assert.equal(result.ok, false); assert.equal(result.reason, 'new_tab');
    await late.close();
    assert.equal(await page.evaluate(() => window.paused), false);
    assert.equal(await peer.evaluate(() => window.paused), false);
    await page.evaluate(() => { window.prepareDelay = 0; });
  });
  await check('all-tabs-persist-before-atomic-upgrade', async () => {
    await page.evaluate(async () => { await (await caches.open('flutter-app-cache')).put('/legacy-marker', new Response('synthetic')); });
    await page.evaluate(() => { void FlowTraceShell.activateUpdate(); });
    await loaded(page, 'E'); await loaded(peer, 'E');
    const stored = await page.evaluate(async () => {
      const db = await new Promise((resolve) => { const request = indexedDB.open('synthetic-shell-barrier', 1); request.onsuccess = () => resolve(request.result); });
      const rows = await new Promise((resolve) => { const request = db.transaction('outbox').objectStore('outbox').getAll(); request.onsuccess = () => resolve(request.result); }); db.close(); return rows;
    });
    assert.deepEqual(stored.map((row) => row.stableOperationId).sort(), ['tab-one', 'tab-two']);
    const cachesKept = await page.evaluate(() => caches.keys());
    assert(cachesKept.includes(`flowtrace-shell-v1:/:${releases.A.release_id}`));
    assert(cachesKept.includes(`flowtrace-shell-v1:/:${releases.E.release_id}`));
    assert(!cachesKept.includes('flutter-app-cache'));
  });
  await check('corrupted-active-cache-fails-closed-without-new-network-bytes', async () => {
    await page.evaluate(async () => { const status = await FlowTraceShell.status(); const cache = await caches.open(`flowtrace-shell-v1:/:${status.releaseId}`); await cache.put(new URL('late-resource.bin', location.href), new Response('corrupt')); });
    const before = requests.length;
    const response = await page.evaluate(async () => { const result = await fetch('late-resource.bin'); return {status: result.status, text: await result.text()}; });
    assert.equal(response.status, 503); assert(!response.text.includes('complete-package-resource'));
    assert(!requests.slice(before).some((request) => request.key === 'late-resource.bin'));
  });
  await peer.close();
  await check('query-versioned-worker-migration-negotiates-the-same-startup-fence', async () => {
    migrationServer = http.createServer(server.listeners('request')[0]);
    await new Promise((resolve) => migrationServer.listen(0, '127.0.0.1', resolve));
    const migrationOrigin = `http://127.0.0.1:${migrationServer.address().port}/`;
    const previous = await context.newPage();
    await previous.addInitScript(() => {
      const register = navigator.serviceWorker.register.bind(navigator.serviceWorker);
      navigator.serviceWorker.register = (script, options) => {
        const url = new URL(script, document.baseURI);
        if (!sessionStorage.getItem('synthetic-query-registration-used')) {
          url.searchParams.set('v', 'previous-flutter');
          sessionStorage.setItem('synthetic-query-registration-used', 'true');
        }
        return register(url.href, options);
      };
    });
    await previous.goto(migrationOrigin); await loaded(previous, 'E');
    const next = await context.newPage(); await next.goto(migrationOrigin); await loaded(next, 'E');
    assert.equal(await updateAttempt(next, releases.E.release_id), 'installed');
    const scripts = await next.evaluate(async () => {
      const registration = await navigator.serviceWorker.getRegistration();
      return {active: registration.active.scriptURL, waiting: registration.waiting.scriptURL};
    });
    assert.match(scripts.active, /\?v=previous-flutter$/);
    assert(!new URL(scripts.waiting).search);
    receipt.query_migration = {active_had_version_query: true, candidate_has_version_query: false};
    await barrier(previous, 'migration-one'); await barrier(next, 'migration-two');
    await previous.evaluate(() => { window.prepareDelay = 1000; });
    await next.evaluate(() => { window.lastActivation = null; void FlowTraceShell.activateUpdate().then((result) => { window.lastActivation = result; }); });
    await previous.waitForFunction(() => window.prepared === 1);
    const late = await context.newPage(); await late.goto(migrationOrigin);
    await late.waitForFunction(() => document.querySelector('aside')?.textContent.includes('另一个窗口正在更新'));
    assert.equal(await late.evaluate(() => document.body.dataset.appVersion), undefined);
    await next.waitForFunction(() => window.lastActivation !== null);
    assert.equal((await next.evaluate(() => window.lastActivation)).reason, 'new_tab');
    await late.close();
    await previous.evaluate(() => { window.prepareDelay = 0; window.oldRegistrationPage = true; });
    await next.evaluate(() => { window.oldRegistrationPage = true; void FlowTraceShell.activateUpdate(); });
    for (const target of [previous, next]) {
      await target.waitForFunction(() => !window.oldRegistrationPage && document.body.dataset.appVersion === 'E');
      assert.equal(await target.evaluate(async () => new URL((await navigator.serviceWorker.getRegistration()).active.scriptURL).search), '');
      await target.close();
    }
    await new Promise((resolve) => { migrationServer.close(resolve); migrationServer.closeAllConnections(); }); migrationServer = null;
  });
  await check('quota-failure-is-explicit-and-keeps-online-ui', async () => {
    const quotaOrigin = origin.replace('127.0.0.1', 'localhost');
    const quotaPage = await context.newPage();
    const cdp = await context.newCDPSession(quotaPage);
    await cdp.send('Storage.overrideQuotaForOrigin', {origin: quotaOrigin, quotaSize: 1});
    await quotaPage.goto(quotaOrigin);
    await quotaPage.waitForFunction(() => document.body.dataset.appVersion === 'E', null, {timeout: 60000});
    const preparation = await quotaPage.evaluate(() => FlowTraceShell.ready);
    assert.equal(preparation.offlineReady, false);
    await quotaPage.waitForFunction(async () => (await FlowTraceShell.status()).failureReason === 'storage_quota');
    assert.match(await quotaPage.locator('aside').innerText(), /离线准备未完成/);
    await quotaPage.setViewportSize({width: 390, height: 844});
    const bounds = await quotaPage.locator('aside').boundingBox();
    assert(bounds.x >= 0 && bounds.x + bounds.width <= 390);
    await quotaPage.screenshot({path: path.join(output, 'online-only-narrow.png')});
    await quotaPage.getByRole('button', {name: '收起提示', exact: true}).press('Enter');
    assert.equal(await quotaPage.locator('aside').isVisible(), false);
    await quotaPage.getByRole('button', {name: '合成导航', exact: true}).click();
    assert.equal(await quotaPage.locator('body').getAttribute('data-navigation'), 'opened');
    assert.equal((await quotaPage.evaluate(() => FlowTraceShell.ready)).offlineReady, false);
    assert.equal((await quotaPage.evaluate(() => FlowTraceShell.status())).failureReason, 'storage_quota');
    receipt.dismissible_online_feedback = {viewport: 390, keyboard_dismissal: true,
      normal_mouse_navigation: true, offline_status_unchanged: true};
    const estimate = await quotaPage.evaluate(() => navigator.storage.estimate());
    receipt.quota_test = {requested_bytes: 1, reported_quota: estimate.quota, usage: estimate.usage, failure_reason: (await quotaPage.evaluate(() => FlowTraceShell.status())).failureReason};
    await cdp.send('Storage.overrideQuotaForOrigin', {origin: quotaOrigin});
    await quotaPage.close();
  });
  await check('late-first-install-claim-keeps-unflushed-online-editor', async () => {
    // A separate origin has no prior registration. Accelerate only the shell's
    // bounded 45s networking deadline, while the real worker keeps downloading.
    // Neither CacheStorage nor worker activation is mocked.
    timeoutServer = http.createServer(server.listeners('request')[0]);
    await new Promise((resolve) => timeoutServer.listen(0, '127.0.0.1', resolve));
    const slowOrigin = `http://127.0.0.1:${timeoutServer.address().port}/`;
    const slowPage = await context.newPage();
    await slowPage.addInitScript(() => {
      const actual = window.setTimeout;
      window.setTimeout = function(callback, milliseconds, ...args) { return actual.call(window, callback, milliseconds === 45000 ? 50 : milliseconds, ...args); };
    });
    fault = 'slow'; await slowPage.goto(slowOrigin);
    await slowPage.waitForFunction(() => document.body.dataset.appVersion === 'E');
    assert.equal((await slowPage.evaluate(() => FlowTraceShell.ready)).offlineReady, false);
    await slowPage.evaluate(() => { window.unflushedSyntheticEditor = '12+ synthetic in-memory'; });
    await slowPage.waitForFunction(async () => (await FlowTraceShell.status()).complete === true);
    await sleep(200);
    assert.equal(await slowPage.evaluate(() => window.unflushedSyntheticEditor), '12+ synthetic in-memory');
    fault = null; await slowPage.close();
    await new Promise((resolve) => { timeoutServer.close(resolve); timeoutServer.closeAllConnections(); }); timeoutServer = null;
  });
  await check('cleared-site-data-does-not-pretend-to-recover-unsynced-outbox', async () => {
    const cdp = await context.newCDPSession(page);
    await cdp.send('Storage.clearDataForOrigin', {origin, storageTypes: 'all'});
    await page.goto('about:blank'); await context.setOffline(true);
    let failedOffline = false;
    try { await page.goto(origin, {timeout: 10000}); } catch (_) { failedOffline = true; }
    assert.equal(failedOffline, true);
    await context.setOffline(false); await page.goto(origin); await loaded(page, 'E');
    const names = await page.evaluate(async () => (await indexedDB.databases()).map((db) => db.name));
    assert(!names.includes('synthetic-shell-barrier'));
  });
  await page.screenshot({path: path.join(output, 'shell-final.png')});
  receipt.phase = 'passed';
}
main().catch(async (error) => {
  receipt.phase = 'failed'; receipt.error = String(error.stack || error); console.error(receipt.error); process.exitCode = 1;
  receipt.pages = [];
  for (const [index, page] of (context?.pages() || []).entries()) {
    try {
      const information = await page.evaluate(async () => ({url: location.href, failures: window.syntheticWorkerFailures, panel: document.querySelector('aside')?.textContent, app: document.body.dataset.appVersion, shell: window.FlowTraceShell ? await FlowTraceShell.status() : null, workers: (await navigator.serviceWorker.getRegistrations()).map((r) => ({scope: r.scope, installing: r.installing?.state, active: r.active?.state, waiting: r.waiting?.state}))}));
      receipt.pages.push(information);
      await page.screenshot({path: path.join(output, `failure-${index}.png`)});
    } catch (_) { /* preserve primary test failure */ }
  }
}).finally(async () => {
  if (context) await context.close();
  if (server) await new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); });
  if (timeoutServer) await new Promise((resolve) => { timeoutServer.close(resolve); timeoutServer.closeAllConnections(); });
  if (migrationServer) await new Promise((resolve) => { migrationServer.close(resolve); migrationServer.closeAllConnections(); });
  receipt.finished_at = new Date().toISOString();
  receipt.requests = requests;
  await fs.mkdir(output, {recursive: true});
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(`RECEIPT outputs/validation/P6/${runId}/receipt.json`);
});
