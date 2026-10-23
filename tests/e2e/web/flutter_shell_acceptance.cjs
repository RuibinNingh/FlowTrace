// Normal Flutter main, real visible UI and real browser storage. This group
// covers provisional drafts and the production upgrade bridge, not sync/account
// correctness or a complete business journey. No application hooks/DB edits.
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
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p6-flutter-${runId}`);
const buildArgument = process.argv.indexOf('--build');
if (buildArgument < 0 || !process.argv[buildArgument + 1]) throw new Error('Pass --build with a new sealed normal-main build directory');
const build = path.resolve(process.argv[buildArgument + 1]);
if (!build.startsWith(path.join(root, 'apps/flowtrace/build') + path.sep)) throw new Error('Build must be inside this workspace Flutter build directory');
const candidate = path.join(output, 'release-B');
const receipt = {run_id: runId, kind: 'normal-flutter-provisional-drafts-and-upgrade', phase: 'starting',
  headed: true, personal_profile: false, checks: [], blocked_origins: [], page_errors: []};
let context;
let server;
let origin;
let current = build;
const notes = ['并发草稿一', '并发草稿二', '升级前输入一', '升级前输入二'].map((label) => `${label}-${runId.slice(0, 8)}`);
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

async function readJson(file) { return JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, '')); }
async function verifyRelease(folder) {
  const manifest = await readJson(path.join(folder, 'flowtrace-release.json'));
  assert.match(manifest.release_id, /^[0-9a-f]{64}$/);
  for (const required of ['index.html', 'main.dart.js', 'flutter_bootstrap.js', 'flowtrace_shell.js', 'sqlite3.wasm', 'drift_worker.js']) {
    assert(manifest.resources[required], `Missing runtime resource ${required}`);
  }
  for (const [name, metadata] of Object.entries(manifest.resources)) {
    const resolved = path.resolve(folder, name);
    assert(resolved.startsWith(folder + path.sep));
    const bytes = await fs.readFile(resolved);
    assert.equal(bytes.length, metadata.bytes);
    assert.equal(hash(bytes), metadata.sha256);
  }
  return manifest;
}
async function makeCandidate() {
  await fs.cp(build, candidate, {recursive: true, errorOnExist: true, force: false,
    filter: (source) => !['flowtrace-release.json', 'flutter_service_worker.js'].includes(path.basename(source))});
  const manifestPath = path.join(candidate, 'manifest.json');
  const publicManifest = await readJson(manifestPath);
  publicManifest.description = `流迹 P6 资源更新验证 ${runId}`;
  await fs.writeFile(manifestPath, JSON.stringify(publicManifest, null, 2));
  const result = spawnSync(path.join(root, 'server/.venv/Scripts/python.exe'),
    [path.join(root, 'apps/flowtrace/tool/web_release/seal_release.py'), candidate], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  return verifyRelease(candidate);
}
async function startServer() {
  const types = {'.js': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html; charset=utf-8',
    '.json': 'application/json', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf'};
  server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://localhost');
      const key = decodeURIComponent(url.pathname).slice(1) || 'index.html';
      if (/^(api|admin|auth)(\/|$)/.test(key) || key.includes('..') || key.includes('\\')) {
        response.writeHead(404, {'Cache-Control': 'no-store'}); response.end(); return;
      }
      const folder = current;
      const bytes = await fs.readFile(path.join(folder, key));
      response.writeHead(200, {'Content-Type': types[path.extname(key)] || 'application/octet-stream',
        'Cache-Control': 'no-store', 'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp', 'X-Content-Type-Options': 'nosniff'});
      response.end(bytes);
    } catch (_) { response.writeHead(404, {'Cache-Control': 'no-store'}); response.end(); }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}/`;
  receipt.origin = origin;
}
async function launch(offline = false) {
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, viewport: {width: 1280, height: 900}, locale: 'zh-CN', acceptDownloads: true});
  context.setDefaultTimeout(20000);
  receipt.browser = context.browser().version();
  await context.route((url) => ['http:', 'https:'].includes(url.protocol) && url.origin !== new URL(origin).origin, async (route) => {
    const value = new URL(route.request().url()).origin;
    if (!receipt.blocked_origins.includes(value)) receipt.blocked_origins.push(value);
    await route.abort('blockedbyclient');
  });
  context.on('page', observe);
  context.pages().forEach(observe);
  await context.setOffline(offline);
}
function observe(page) { page.on('pageerror', (error) => receipt.page_errors.push({name: error.name, phase: receipt.phase})); }
async function check(name, action) {
  receipt.phase = name;
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  await action();
  receipt.checks.push({name, result: 'passed'});
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(`PASS ${name}`);
}
async function loaded(page, release) {
  await page.waitForFunction(async (expected) => window.FlowTraceShell && (await FlowTraceShell.status()).complete
    && (await FlowTraceShell.status()).releaseId === expected, release, {timeout: 120000});
  await page.getByRole('button', {name: '新建草稿', exact: true}).waitFor({state: 'visible', timeout: 60000});
  assert.equal((await page.evaluate(() => FlowTraceShell.ready)).offlineReady, true);
}
async function edit(page, note) {
  await page.getByRole('button', {name: '新建草稿', exact: true}).click();
  const field = page.getByRole('textbox', {name: /^备注(?:\s|$)/, disabled: false});
  await field.waitFor({state: 'visible'});
  await field.fill(note);
}
async function save(page) {
  await page.getByRole('button', {name: '保存到本机', exact: true}).click();
  await page.getByRole('textbox', {name: /^备注(?:\s|$)/}).waitFor({state: 'detached'});
}
async function containsDrafts(page, expected) {
  for (const note of expected) {
    await page.getByRole('button', {name: new RegExp('^' + escape(note) + '(?:\\s|$)')}).waitFor({state: 'visible'});
    assert.equal(await page.getByRole('button', {name: new RegExp('^' + escape(note) + '(?:\\s|$)')}).count(), 1);
  }
}
async function waitingRelease(page, expected) {
  await page.evaluate(async () => { await FlowTraceShell.checkForUpdate(); });
  await page.waitForFunction(async (release) => {
    const registration = await navigator.serviceWorker.getRegistration();
    const worker = registration?.waiting;
    if (!worker) return false;
    return new Promise((resolve) => {
      const channel = new MessageChannel();
      const timer = setTimeout(() => { channel.port1.close(); resolve(false); }, 5000);
      channel.port1.onmessage = (event) => { clearTimeout(timer); channel.port1.close(); resolve(event.data.complete && event.data.releaseId === release); };
      worker.postMessage({type: 'FLOWTRACE_STATUS'}, [channel.port2]);
    });
  }, expected, {timeout: 120000});
}
async function main() {
  await fs.mkdir(output, {recursive: true});
  await fs.mkdir(path.dirname(profile), {recursive: true});
  await fs.mkdir(profile); // fresh run directory; no pre-existing profile
  receipt.profile = profile;
  const releaseA = await verifyRelease(build);
  const releaseB = await makeCandidate();
  assert.notEqual(releaseA.release_id, releaseB.release_id);
  assert.equal(releaseA.resources['main.dart.js'].sha256, releaseB.resources['main.dart.js'].sha256);
  receipt.releases = {A: releaseA.release_id, B: releaseB.release_id};
  receipt.main_js_sha256 = releaseA.resources['main.dart.js'].sha256;
  receipt.candidate_difference = 'public manifest.description only; identical Flutter main.dart.js';
  receipt.resource_count = Object.keys(releaseA.resources).length;
  await startServer(); await launch();
  let page = context.pages()[0];
  let peer;
  await check('normal-main-complete-first-install-and-concurrent-two-tab-drafts', async () => {
    await page.goto(origin, {waitUntil: 'domcontentloaded'}); await loaded(page, releaseA.release_id);
    peer = await context.newPage(); await peer.goto(origin); await loaded(peer, releaseA.release_id);
    await Promise.all([edit(page, notes[0]), edit(peer, notes[1])]);
    await Promise.all([save(page), save(peer)]);
    // Provisional drafts use a controller snapshot, so reopen both normal UI
    // views before checking the two independently committed records.
    await Promise.all([page.reload(), peer.reload()]);
    await loaded(page, releaseA.release_id); await loaded(peer, releaseA.release_id);
    await containsDrafts(page, notes.slice(0, 2)); await containsDrafts(peer, notes.slice(0, 2));
    const keys = await page.evaluate(async () => (await Promise.all((await caches.keys()).map(async (name) =>
      (await (await caches.open(name)).keys()).map((request) => request.url)))).flat());
    assert(!keys.some((key) => /\/(api|admin|auth)\//.test(key)));
  });
  await check('normal-main-offline-reload-keeps-concurrent-drafts', async () => {
    await context.setOffline(true);
    await Promise.all([page.reload(), peer.reload()]);
    await loaded(page, releaseA.release_id); await loaded(peer, releaseA.release_id);
    await containsDrafts(page, notes.slice(0, 2)); await containsDrafts(peer, notes.slice(0, 2));
    await context.setOffline(false);
  });
  await check('two-normal-flutter-editors-flush-before-resource-upgrade', async () => {
    current = candidate;
    await waitingRelease(page, releaseB.release_id);
    await Promise.all([edit(page, notes[2]), edit(peer, notes[3])]);
    // Both inputs are still in real editor widgets when the public shell's
    // update control requests persistence; no manual save precedes this click.
    await page.getByRole('button', {name: '更新', exact: true}).click();
    await loaded(page, releaseB.release_id); await loaded(peer, releaseB.release_id);
    await containsDrafts(page, notes); await containsDrafts(peer, notes);
  });
  await check('normal-main-browser-process-offline-cold-start-keeps-all-drafts', async () => {
    await peer.close(); await context.close(); context = null;
    await launch(true);
    page = context.pages()[0]; await page.goto(origin);
    await loaded(page, releaseB.release_id); await containsDrafts(page, notes);
    await page.screenshot({path: path.join(output, 'flutter-offline-drafts.png')});
    await fs.writeFile(path.join(output, 'flutter-offline-drafts-aria.txt'), await page.locator('body').ariaSnapshot());
  });
  assert.deepEqual(receipt.page_errors, []);
  receipt.phase = 'passed';
}
main().catch(async (error) => {
  receipt.phase = 'failed'; receipt.error = String(error.stack || error); process.exitCode = 1;
  console.error(receipt.error);
  for (const [index, page] of (context?.pages() || []).entries()) {
    try {
      await fs.writeFile(path.join(output, `failure-${index}-aria.txt`), await page.locator('body').ariaSnapshot());
      await page.screenshot({path: path.join(output, `failure-${index}.png`)});
    } catch (_) { /* preserve primary failure */ }
  }
}).finally(async () => {
  if (context) await context.close();
  if (server) await new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); });
  receipt.finished_at = new Date().toISOString();
  await fs.mkdir(output, {recursive: true});
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(`RECEIPT outputs/validation/P6/${runId}/receipt.json`);
});
