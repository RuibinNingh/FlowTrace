// Actual Jinja forms, production Worker and real backup files on isolated QA data.
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
if (index < 0) throw new Error('Pass isolated operations --fixture');
const fixturePath = path.resolve(process.argv[index + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), `operations-browser-${runId}`);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p5-operations-${runId}`);
const receipt = {run_id: runId, kind: 'real-admin-jobs-worker-backup-verification', phase: 'starting',
  personal_profile: false, headed: true, checks: [], page_errors: [], console_issues: []};
let context, page, secrets = [], fixture, credentials, origin;
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const safe = (value) => secrets.reduce((text, secret) => text.split(secret).join('[redacted]'), String(value));
async function save() { await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2)); }
async function check(name, action) {
  receipt.phase = name; await save(); await action(); receipt.checks.push({name, result: 'passed'}); await save();
  console.log('PASS ' + name);
}
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'), mask: [page.locator('input'), page.locator('header p')]});
  await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
}
async function login(label) {
  await page.goto(origin + '/admin/login');
  await page.getByLabel('管理员账号', {exact: true}).fill(credentials[label].username);
  await page.keyboard.press('Tab'); await page.keyboard.type(credentials[label].password);
  await page.getByRole('button', {name: '登录后台', exact: true}).click();
  await page.getByRole('heading', {name: '服务概况', exact: true}).waitFor();
}
async function logout() {
  await page.getByRole('button', {name: '退出登录', exact: true}).click();
  await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
}
async function workerOnce(expected) {
  const result = await execute(path.join(root, 'server/.venv/Scripts/python.exe'),
    [path.join(root, 'tests/e2e/admin/worker_once.py'), '--env-file', fixture.env_file],
    {cwd: root, timeout: 30000, windowsHide: true, maxBuffer: 65536});
  assert.deepEqual(JSON.parse(result.stdout.trim()), {worked: expected});
  assert.equal(result.stderr.trim(), '');
}
const row = (jobId) => page.locator('tbody tr').filter({hasText: jobId});
async function enqueue(backupId, testWrongPassword = false) {
  await page.goto(origin + '/admin/jobs/backup-verify');
  await page.getByLabel('备份UUID', {exact: true}).fill(backupId);
  await page.getByRole('button', {name: '核对目标', exact: true}).click();
  await page.getByRole('heading', {name: '确认校验备份', exact: true}).waitFor();
  assert.match(await page.locator('dl').innerText(), new RegExp(backupId));
  if (testWrongPassword) {
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.wrong_password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '排队校验', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.getByLabel('当前管理密码', {exact: true}).inputValue(), '');
  }
  await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
  await page.locator('input[name=confirm_target]').check();
  await page.getByRole('button', {name: '排队校验', exact: true}).click();
  await page.getByRole('heading', {name: '任务队列', exact: true}).waitFor();
  const id = (await page.locator('tbody tr').first().locator('td').first().innerText()).match(/[0-9a-f-]{36}/)[0];
  await row(id).getByText('待执行', {exact: true}).waitFor();
  return id;
}
async function main() {
  fixture = await read(fixturePath);
  assert.equal(fixture.purpose, 'flowtrace-p5-admin-operations-synthetic');
  const admin = await read(fixture.admin_fixture); origin = admin.origin;
  assert.equal(origin, 'http://127.0.0.1:18087');
  const privatePath = path.resolve(admin.credentials_path);
  if (!privatePath.startsWith(path.join(root, 'work/flowtrace-dev') + path.sep)) throw new Error('Unexpected private fixture');
  credentials = await read(privatePath);
  secrets = Object.values(credentials).flatMap((value) => typeof value === 'string' ? [value] : Object.values(value))
    .filter((value) => typeof value === 'string' && value.length >= 8).sort((a, b) => b.length - a.length);
  await fs.mkdir(output); await fs.mkdir(profile, {recursive: true});
  receipt.operations_fixture = fixture.run_id; receipt.origin = origin; receipt.profile = profile;
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: {width: 1280, height: 900}});
  receipt.browser = context.browser().version(); page = context.pages()[0]; page.setDefaultTimeout(15000);
  page.on('pageerror', (error) => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', (message) => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase,
      ...(category === 'other' ? {message: safe(message.text())} : {})});
  });
  await login('owner');
  await check('real-verified-backup-enqueued-reauthenticated-and-completed-by-worker', async () => {
    receipt.good_job_id = await enqueue(fixture.good_backup_id, true);
    await workerOnce(true); await page.reload();
    await row(receipt.good_job_id).getByText('已完成', {exact: true}).waitFor();
    assert.match(await row(receipt.good_job_id).innerText(), /backup_verified/);
    assert.match(await row(receipt.good_job_id).innerText(), new RegExp(fixture.good_backup_id));
    await screen('verified-backup');
  });
  await check('actual-corrupt-backup-fails-and-manual-retry-keeps-original-job', async () => {
    receipt.damaged_job_id = await enqueue(fixture.damaged_backup_id);
    await workerOnce(true); await page.reload();
    await row(receipt.damaged_job_id).getByText('失败', {exact: true}).waitFor();
    assert.match(await row(receipt.damaged_job_id).innerText(), /backup_file_hash_mismatch/);
    await row(receipt.damaged_job_id).getByRole('link', {name: '重试', exact: true}).click();
    await page.getByRole('heading', {name: '确认重试任务', exact: true}).waitFor();
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认重试', exact: true}).click();
    await row(receipt.damaged_job_id).getByText('待执行', {exact: true}).waitFor();
    await workerOnce(true); await page.reload();
    await row(receipt.damaged_job_id).getByText('失败', {exact: true}).waitFor();
    assert.match(await row(receipt.damaged_job_id).innerText(), /手工重试 1 · generation 2/);
    assert.equal(await row(receipt.damaged_job_id).count(), 1);
    await screen('corrupt-retry-same-job');
  });
  await check('cancelled-job-is-not-claimed-and-unimplemented-kind-remains-pending', async () => {
    receipt.cancelled_job_id = await enqueue(fixture.good_backup_id);
    await row(receipt.cancelled_job_id).getByRole('link', {name: '取消', exact: true}).click();
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认取消', exact: true}).click();
    await row(receipt.cancelled_job_id).getByText('已取消', {exact: true}).waitFor();
    await workerOnce(false);
    await page.goto(origin + '/admin/jobs?kind=export');
    assert.equal(await page.getByRole('link', {name: '重试', exact: true}).count(), 0);
    assert.match(await page.locator('tbody').innerText(), /处理器未接入/);
    assert.equal((await page.locator('tbody').innerText()).includes(fixture.private_body_sentinel), false);
  });
  await check('real-cursor-pagination-and-actual-fresh-stale-worker-records', async () => {
    await page.goto(origin + '/admin/jobs');
    const ids = new Set(); let pages = 0;
    for (;;) {
      const count = await page.locator('tbody tr').count(); assert.ok(count <= 50);
      for (const text of await page.locator('tbody tr td:first-child').allInnerTexts()) {
        const id = text.match(/[0-9a-f-]{36}/)[0]; assert.equal(ids.has(id), false); ids.add(id);
      }
      pages += 1; assert.ok(pages < 20);
      if (!await page.getByRole('link', {name: '更早任务', exact: true}).count()) break;
      await page.getByRole('link', {name: '更早任务', exact: true}).click();
    }
    for (const id of fixture.unsupported_job_ids) assert.equal(ids.has(id), true);
    assert.ok(pages >= 2); receipt.pagination = {pages, unique_jobs: ids.size};
    await page.goto(origin + '/admin/workers');
    await row(fixture.stale_worker_id).getByText('心跳已过期', {exact: true}).waitFor();
    assert.ok(await page.getByText('60秒内联系', {exact: true}).count() >= 1);
    await screen('worker-heartbeats');
  });
  await check('service-and-recovery-capabilities-mobile-keyboard-and-logout', async () => {
    await logout(); await login('service');
    await page.goto(origin + '/admin/jobs?kind=backup_verify');
    assert.equal(await page.getByRole('link', {name: '校验指定备份', exact: true}).count(), 0);
    assert.equal(await page.getByRole('link', {name: '重试', exact: true}).count(), 0);
    assert.equal((await context.request.get(origin + '/admin/jobs/backup-verify')).status(), 403);
    await logout(); await login('recovery'); await page.goto(origin + '/admin/jobs');
    assert.equal(await page.locator('tbody').getByText('数据导出', {exact: true}).count(), 0);
    assert.equal((await context.request.get(origin + '/admin/jobs/' + fixture.unsupported_job_ids[0] + '/cancel')).status(), 404);
    await page.setViewportSize({width: 390, height: 844});
    await page.emulateMedia({reducedMotion: 'reduce'});
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await screen('mobile-jobs');
    await page.getByRole('link', {name: '执行器状态', exact: true}).focus();
    await page.keyboard.press('Enter'); await page.getByRole('heading', {name: '执行器状态', exact: true}).waitFor();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await logout(); await page.goto(origin + '/admin/jobs');
    await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
    assert.deepEqual(receipt.page_errors, []);
    assert.equal(receipt.console_issues.some((item) => item.category === 'other'), false);
  });
  receipt.phase = 'completed'; await save();
}
main().catch(async (error) => {
  receipt.phase = 'failed'; receipt.error = safe(error.stack || error);
  if (page) { try { await screen('failure'); } catch {} }
  console.error(safe(error.stack || error)); process.exitCode = 1;
}).finally(async () => {
  if (context) await context.close();
  await fs.mkdir(output, {recursive: true}); await save(); console.log('RECEIPT ' + path.relative(root, path.join(output, 'receipt.json')));
});
