// Actual authenticated raw ZIP downloads; no token injection or browser internals.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {chromium} = require('playwright');
const execute = promisify(execFile);
const root = path.resolve(__dirname, '../../..');
const index = process.argv.indexOf('--fixture');
if (index < 0) throw new Error('Pass isolated backup --fixture');
const fixturePath = path.resolve(process.argv[index + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), `backup-browser-${runId}`);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p5-backup-${runId}`);
const receipt = {run_id: runId, kind: 'real-admin-private-backup-download', phase: 'starting',
  personal_profile: false, headed: true, checks: [], page_errors: [], console_issues: []};
let context, page, fixture, credentials, origin, secrets = [];
const diagnosticNonce = process.argv.includes('--diagnostic-url-nonce');
receipt.diagnostic_url_nonce = diagnosticNonce;
const diagnosticDirect = process.argv.includes('--diagnostic-direct-loopback');
receipt.diagnostic_direct_loopback = diagnosticDirect;
const diagnosticAlt = process.argv.includes('--diagnostic-browser-alt');
receipt.diagnostic_browser_alt = diagnosticAlt;
const headless = process.argv.includes('--headless');
receipt.headed = !headless;
const accessOnly = process.argv.includes('--access-ui-only');
receipt.acceptance_scope = accessOnly ? 'headed-access-layout-and-separate-http-zip-validation; native-zip-download-blocked' : 'full-browser-zip-download';
if (accessOnly) receipt.kind = 'real-admin-backup-access-ui-and-separated-http-download';
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const safe = (value) => secrets.reduce((text, secret) => text.split(secret).join('[redacted]'), String(value));
async function save() { await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2)); }
async function check(name, action) {
  receipt.phase = name; await save(); await action(); receipt.checks.push({name, result: 'passed'}); await save(); console.log('PASS ' + name);
}
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'), mask: [page.locator('input')]});
  await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
}
async function login(label) {
  await page.goto(origin + '/admin/login');
  await page.getByLabel('管理员账号', {exact: true}).fill(credentials[label].username);
  await page.keyboard.press('Tab'); await page.keyboard.type(credentials[label].password);
  await page.getByRole('button', {name: '登录后台', exact: true}).click();
  await page.getByRole('heading', {name: '服务概况', exact: true}).waitFor();
}
async function logout() { await page.getByRole('button', {name: '退出登录', exact: true}).click(); await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor(); }
async function validate(archive) {
  const result = await execute(path.join(root, 'server/.venv/Scripts/python.exe'),
    [path.join(root, 'tests/e2e/admin/validate_backup_download.py'), '--fixture', fixturePath, '--archive', archive],
    {cwd: root, timeout: 30000, windowsHide: true, maxBuffer: 65536});
  assert.equal(result.stderr.trim(), '');
  const verified = JSON.parse(result.stdout.trim());
  assert.equal(verified.verified_members, 5); assert.equal(verified.objects, 2); assert.equal(verified.pg_restore_toc_verified, true);
  return verified;
}
async function download(label) {
  const url = origin + '/admin/backups/' + fixture.good_backup_id + '/download';
  await page.goto(url);
  await page.getByLabel('当前管理密码', {exact: true}).fill(credentials[label].password);
  await page.locator('input[name=confirm_target]').check();
  receipt.last_form_state = await page.locator('form.credential-form').evaluate((form) => ({valid: form.checkValidity(),
    checked: form.querySelector('input[name=confirm_target]').checked, method: form.method,
    invalid: Array.from(form.elements).filter((field) => field.willValidate && !field.checkValidity()).map((field) => field.name)}));
  if (diagnosticNonce) await page.locator('form.credential-form').evaluate((form, nonce) => { const url = new URL(form.action); url.searchParams.set('download_request', nonce); form.action = url.href; }, randomUUID());
  await save();
  let artifact;
  if (diagnosticAlt) await page.keyboard.down('Alt');
  try { [artifact] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', {name: '验证并下载', exact: true}).click()]); }
  finally { if (diagnosticAlt) await page.keyboard.up('Alt'); }
  assert.equal(artifact.suggestedFilename(), 'flowtrace-backup-' + fixture.good_backup_id + '.zip');
  const file = path.join(output, label + '-backup.zip'); await artifact.saveAs(file);
  const verified = await validate(file);
  const transport = receipt.zip_network.filter((item) => item.event === 'headers' && item.status === 200 && item.fields['content-type'] === 'application/zip').at(-1);
  assert.ok(transport); assert.equal(transport.fields['x-flowtrace-archive-sha256'], verified.sha256);
  assert.equal(Number(transport.fields['content-length']), verified.size_bytes);
  return verified;
}
async function main() {
  fixture = await read(fixturePath); assert.equal(fixture.purpose, 'flowtrace-p5-admin-backup-download-synthetic');
  const admin = await read(fixture.admin_fixture); origin = admin.origin; assert.equal(origin, 'http://127.0.0.1:18087');
  for (const privatePath of [admin.credentials_path, fixture.credentials_path]) {
    if (!path.resolve(privatePath).startsWith(path.join(root, 'work/flowtrace-dev') + path.sep)) throw new Error('Unexpected private fixture');
  }
  credentials = {...await read(admin.credentials_path), ...await read(fixture.credentials_path)};
  secrets = Object.values(credentials).flatMap((value) => typeof value === 'string' ? [value] : Object.values(value))
    .filter((value) => typeof value === 'string' && value.length >= 8).sort((a, b) => b.length - a.length);
  await fs.mkdir(output); await fs.mkdir(profile, {recursive: true});
  receipt.backup_fixture = fixture.run_id; receipt.origin = origin; receipt.profile = profile;
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless, locale: 'zh-CN', viewport: {width: 1280, height: 900}, acceptDownloads: true,
    args: diagnosticDirect ? ['--no-proxy-server'] : []});
  receipt.browser = context.browser().version(); page = context.pages()[0]; page.setDefaultTimeout(15000);
  const protocol = await context.newCDPSession(page); const requests = new Set();
  await protocol.send('Network.enable'); receipt.zip_network = [];
  protocol.on('Network.requestWillBeSent', (event) => { if (event.request.method === 'POST' && new URL(event.request.url).pathname.endsWith('/download')) requests.add(event.requestId); });
  protocol.on('Network.responseReceived', (event) => { if (requests.has(event.requestId)) receipt.zip_network.push({event: 'response', status: event.response.status, mime_type: event.response.mimeType,
    disk_cache: event.response.fromDiskCache, service_worker: event.response.fromServiceWorker, remote_ip: event.response.remoteIPAddress, remote_port: event.response.remotePort, protocol: event.response.protocol}); });
  protocol.on('Network.responseReceivedExtraInfo', (event) => { if (requests.has(event.requestId)) {
    const fields = {}; for (const [key, value] of Object.entries(event.headers)) if (['content-type','content-disposition','content-length','x-flowtrace-archive-sha256'].includes(key.toLowerCase())) fields[key.toLowerCase()] = value;
    receipt.zip_network.push({event: 'headers', status: event.statusCode, fields}); } });
  protocol.on('Network.loadingFailed', (event) => { if (requests.has(event.requestId)) receipt.zip_network.push({event: 'failed', code: event.errorText, cancelled: event.canceled}); });
  protocol.on('Network.loadingFinished', (event) => { if (requests.has(event.requestId)) receipt.zip_network.push({event: 'finished', encoded_bytes: event.encodedDataLength}); });
  const browserProtocol = await context.browser().newBrowserCDPSession(); receipt.native_downloads = [];
  browserProtocol.on('Browser.downloadWillBegin', (event) => receipt.native_downloads.push({event: 'begin', filename: event.suggestedFilename}));
  browserProtocol.on('Browser.downloadProgress', (event) => receipt.native_downloads.push({event: 'progress', state: event.state, bytes: event.receivedBytes}));
  page.on('pageerror', (error) => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', (message) => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase,
      ...(category === 'other' ? {message: safe(message.text())} : {})});
  });
  await login('owner');
  await check('metadata-partial-backup-and-history-are-truthful', async () => {
    await page.getByText('最近成功校验', {exact: true}).waitFor();
    await page.getByRole('link', {name: '备份管理', exact: true}).first().click();
    await page.getByRole('heading', {name: '备份管理', exact: true}).waitFor();
    await page.locator('tbody tr').filter({hasText: fixture.partial_backup_id}).getByText('不可用', {exact: true}).waitFor();
    const row = page.locator('tbody tr').filter({hasText: fixture.good_backup_id});
    assert.match(await row.innerText(), /5 个文件（含清单）/);
    assert.equal(await row.getByRole('link', {name: '下载原始包', exact: true}).count(), 1);
    await page.getByText('网页备份创建和隔离恢复服务尚未接入。', {exact: false}).waitFor();
    await screen('backup-catalog');
  });
  await check(accessOnly ? 'owner-wrong-password-rejected-with-empty-password-field' : 'owner-wrong-password-rejected-then-real-five-member-download', async () => {
    await page.goto(origin + '/admin/backups/' + fixture.good_backup_id + '/download');
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.wrong_password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '验证并下载', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.getByLabel('当前管理密码', {exact: true}).inputValue(), '');
    if (!accessOnly) receipt.owner_archive = await download('owner');
    await screen('download-confirmation');
  });
  await check('damaged-backup-refuses-download-with-fixed-failure', async () => {
    const url = origin + '/admin/backups/' + fixture.damaged_backup_id + '/download';
    await page.goto(url); await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('input[name=confirm_target]').check();
    const [response] = await Promise.all([page.waitForResponse((item) => item.url() === url && item.request().method() === 'POST'), page.getByRole('button', {name: '验证并下载', exact: true}).click()]);
    assert.equal(response.status(), 409); assert.equal((await response.allHeaders())['content-disposition'], undefined);
    await page.getByRole('alert').filter({hasText: '备份文件校验失败'}).waitFor(); await screen('damaged-rejection');
  });
  await check(accessOnly ? 'service-and-owner-without-recovery-denied-recovery-only-confirmation' : 'service-and-owner-without-recovery-denied-recovery-only-downloads', async () => {
    await logout();
    for (const label of ['service', 'owner_without_recovery']) {
      await login(label); await page.goto(origin + '/admin/backups');
      assert.equal(await page.getByRole('link', {name: '下载原始包', exact: true}).count(), 0);
      const url = origin + '/admin/backups/' + fixture.good_backup_id + '/download';
      assert.equal((await context.request.get(url)).status(), 403);
      const csrf = await page.locator('input[name=csrf_token]').first().inputValue();
      assert.equal((await context.request.post(url, {form: {csrf_token: csrf, confirm_target: fixture.good_backup_id, current_password: credentials[label].password}, headers: {origin}})).status(), 403);
      await logout();
    }
    await login('recovery'); assert.equal((await context.request.get(origin + '/admin/users')).status(), 403);
    if (accessOnly) {
      const url = origin + '/admin/backups/' + fixture.good_backup_id + '/download'; await page.goto(url);
      await page.getByRole('heading', {name: '确认下载原始备份', exact: true}).waitFor();
      const csrf = await page.locator('input[name=csrf_token]').first().inputValue();
      const response = await context.request.post(url, {form: {csrf_token: csrf, confirm_target: fixture.good_backup_id, current_password: credentials.recovery.password}, headers: {origin}});
      assert.equal(response.status(), 200); const file = path.join(output, 'separate-recovery-http.zip'); await fs.writeFile(file, await response.body());
      receipt.separate_recovery_http_archive = await validate(file);
    } else { receipt.recovery_archive = await download('recovery'); assert.equal(receipt.recovery_archive.sha256, receipt.owner_archive.sha256); }
  });
  await check('mobile-keyboard-logout-and-private-artifact-cleanup', async () => {
    await page.setViewportSize({width: 390, height: 844}); await page.emulateMedia({reducedMotion: 'reduce'});
    await page.goto(origin + '/admin/backups/' + fixture.good_backup_id + '/download');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.getByLabel('当前管理密码', {exact: true}).focus(); await page.keyboard.press('Tab');
    assert.equal(await page.locator('input[name=confirm_target]').evaluate((input) => input === document.activeElement), true);
    await screen('mobile-download'); await logout(); await page.goto(origin + '/admin/backups');
    await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
    const result = await execute(path.join(root, 'server/.venv/Scripts/python.exe'), [path.join(root, 'tests/e2e/admin/validate_backup_download.py'), '--fixture', fixturePath, '--postconditions'], {cwd: root, timeout: 15000, windowsHide: true, maxBuffer: 65536});
    assert.equal(result.stderr.trim(), ''); receipt.postconditions = JSON.parse(result.stdout.trim());
    assert.deepEqual(receipt.page_errors, []); assert.equal(receipt.console_issues.some((item) => item.category === 'other'), false);
  });
  receipt.phase = 'completed'; await save();
}
main().catch(async (error) => {
  receipt.phase = 'failed'; receipt.error = safe(error.stack || error);
  if (page) { try { await screen('failure'); } catch {} }
  if (context && page) { try {
    const csrf = await page.locator('input[name=csrf_token]').first().inputValue();
    const response = await context.request.post(origin + '/admin/backups/' + fixture.good_backup_id + '/download',
      {form: {csrf_token: csrf, confirm_target: fixture.good_backup_id, current_password: credentials.owner.password}, headers: {origin}});
    const headers = response.headers(); const body = await response.body();
    receipt.diagnostic_direct_http = {status: response.status(), content_type: headers['content-type'],
      content_disposition: headers['content-disposition'], content_length: headers['content-length'],
      archive_sha256: headers['x-flowtrace-archive-sha256'], received_bytes: body.length};
    await fs.writeFile(path.join(output, 'diagnostic-http.zip'), body);
  } catch (diagnosticError) { receipt.diagnostic_http_error = safe(diagnosticError.message); } }
  if (page) { try { await page.goto(origin + '/admin/audit');
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    const [control] = await Promise.all([page.waitForEvent('download', {timeout: 8000}), page.getByRole('button', {name: '导出审计JSONL', exact: true}).click()]);
    await control.saveAs(path.join(output, 'diagnostic-control.jsonl')); receipt.ndjson_control_download = true;
  } catch (diagnosticError) { receipt.ndjson_control_download = false; receipt.ndjson_control_error = safe(diagnosticError.message); } }
  if (context) { try { const ui = await context.newPage(); await ui.goto('chrome://downloads/');
    await fs.writeFile(path.join(output, 'owned-downloads-ui.txt'), safe(await ui.locator('body').ariaSnapshot())); } catch {} }
  console.error(safe(error.stack || error)); process.exitCode = 1;
}).finally(async () => {
  if (context) await context.close(); await fs.mkdir(output, {recursive: true}); await save();
  console.log('RECEIPT ' + path.relative(root, path.join(output, 'receipt.json')));
});
