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
const argument = process.argv.indexOf('--fixture');
if (argument < 0) throw new Error('Pass creation --fixture');
const fixturePath = path.resolve(process.argv[argument + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture');
const capabilityOnly = process.argv.includes('--capability-only');
const postconditionsArgument = process.argv.indexOf('--postconditions');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), `creation-browser-${runId}`);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p5-creation-${runId}`);
const receipt = {run_id: runId, kind: capabilityOnly ? 'real-backup-create-unconfigured-boundary' : 'real-backup-create-worker-and-verification-forms',
  headed: true, personal_profile: false, phase: 'starting', checks: [], creations: [], page_errors: [], console_issues: []};
let fixture, credentials, origin, context, page, secrets = [];
const read = async file => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const safe = value => secrets.reduce((text, item) => text.split(item).join('[redacted]'), String(value));
async function save() { await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2)); }
async function check(name, action) {
  receipt.phase = name; await save(); await action(); receipt.checks.push({name, result: 'passed'}); await save();
  console.log('PASS ' + name);
}
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'), mask: [page.locator('input[type="password"]')]});
  await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
}
async function login(label) {
  await page.goto(origin + '/admin/login');
  await page.getByLabel('管理员账号', {exact: true}).fill(credentials[label].username);
  await page.getByLabel('密码', {exact: true}).fill(credentials[label].password);
  await page.getByRole('button', {name: '登录后台', exact: true}).click();
  await page.getByRole('heading', {name: '服务概况', exact: true}).waitFor();
}
async function logout() {
  await page.getByRole('button', {name: '退出登录', exact: true}).click();
  await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
}
async function worker() {
  const result = await execute(path.join(root, 'server/.venv/Scripts/python.exe'),
    [path.join(root, 'tests/e2e/admin/worker_once.py'), '--env-file', fixture.env_file, '--backup-create'],
    {cwd: root, timeout: 90000, windowsHide: true, maxBuffer: 65536});
  assert.deepEqual(JSON.parse(result.stdout.trim()), {worked: true}); assert.equal(result.stderr.trim(), '');
}
const row = id => page.locator('tbody tr').filter({hasText: id});
async function create(label, wrongPassword = false) {
  await page.goto(origin + '/admin/backups');
  await page.getByRole('link', {name: '创建新备份', exact: true}).click();
  await page.getByRole('heading', {name: '确认创建备份', exact: true}).waitFor();
  assert.match(await page.locator('main').innerText(), /当前服务恢复点/);
  assert.match(await page.locator('main').innerText(), /短暂进入维护窗口/);
  assert.match(await page.locator('main').innerText(), /OS私有密钥资料不随/);
  if (wrongPassword) {
    await page.locator('[name=current_password]').fill(credentials.wrong_password);
    await page.locator('[name=confirm_target]').check();
    await page.getByRole('button', {name: '排队创建备份', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.locator('[name=current_password]').inputValue(), '');
  }
  await page.locator('[name=current_password]').fill(credentials[label].password);
  await page.locator('[name=confirm_target]').check();
  await page.getByRole('button', {name: '排队创建备份', exact: true}).click();
  await page.getByRole('heading', {name: '任务队列', exact: true}).waitFor();
  const jobId = new URL(page.url()).searchParams.get('created');
  assert.match(jobId, /^[0-9a-f-]{36}$/);
  await row(jobId).getByText('待执行', {exact: true}).waitFor();
  await worker(); await page.reload();
  await row(jobId).getByText('已完成', {exact: true}).waitFor();
  const text = await row(jobId).innerText(); assert.match(text, /backup_created/);
  const backupId = text.match(/产物 ([0-9a-f-]{36})/)[1];
  assert.match(text, /5 文件/);
  receipt.creations.push({role: label, job_id: jobId, backup_id: backupId}); await save();
  await screen('created-' + label);
  return backupId;
}
async function verify(backupId) {
  await page.goto(origin + '/admin/jobs/backup-verify');
  await page.getByLabel('备份UUID', {exact: true}).fill(backupId);
  await page.getByRole('button', {name: '核对目标', exact: true}).click();
  await page.locator('[name=current_password]').fill(credentials.owner.password);
  await page.locator('[name=confirm_target]').check();
  await page.getByRole('button', {name: '排队校验', exact: true}).click();
  await page.getByRole('heading', {name: '任务队列', exact: true}).waitFor();
  const jobId = (await page.locator('tbody tr').first().innerText()).match(/[0-9a-f-]{36}/)[0];
  await worker(); await page.reload();
  await row(jobId).getByText('已完成', {exact: true}).waitFor();
  assert.match(await row(jobId).innerText(), /backup_verified/);
  receipt.verification_job_id = jobId;
  await page.goto(origin + '/admin/backups');
  await page.locator('section').filter({has: page.getByRole('heading', {name: '最近成功校验', exact: true})})
    .getByText(backupId, {exact: true}).waitFor();
}
async function main() {
  fixture = await read(fixturePath); assert.equal(fixture.purpose, 'flowtrace-p5-backup-creation-synthetic');
  origin = fixture.origin; assert.equal(origin, 'http://127.0.0.1:18087');
  const privatePath = path.resolve(fixture.credentials_path);
  if (!privatePath.startsWith(path.join(root, 'work/flowtrace-dev') + path.sep)) throw new Error('Unexpected private fixture');
  credentials = await read(privatePath);
  secrets = Object.values(credentials).flatMap(item => typeof item === 'string' ? [item] : Object.values(item))
    .filter(item => typeof item === 'string' && item.length >= 8).sort((a,b) => b.length - a.length);
  await fs.mkdir(output); await fs.mkdir(profile, {recursive: true});
  receipt.fixture = fixture.run_id; receipt.origin = origin; receipt.profile = profile;
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: {width: 1280, height: 900}});
  receipt.browser = context.browser().version(); page = context.pages()[0]; page.setDefaultTimeout(20000);
  page.on('pageerror', error => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', message => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409|503)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase,
      ...(category === 'other' ? {message: safe(message.text())} : {})});
  });
  await login('owner');
  if (capabilityOnly) {
    await check('missing-trusted-tool-hides-create-and-direct-entry-has-no-execution-form', async () => {
      await page.goto(origin + '/admin/backups');
      assert.equal(await page.getByRole('link', {name: '创建新备份', exact: true}).count(), 0);
      if (postconditionsArgument >= 0) {
        const reportPath = path.resolve(process.argv[postconditionsArgument + 1]);
        if (!reportPath.startsWith(path.dirname(fixturePath) + path.sep)) throw new Error('Unexpected report');
        const report = await read(reportPath);
        assert.equal(report.kind, 'real-browser-creation-package-postconditions');
        for (const artifact of report.artifacts) {
          const item = page.locator('tbody tr').filter({hasText: artifact.backup_id});
          assert.match(await item.innerText(), new RegExp(artifact.package_bytes_including_manifest + ' 字节'));
          assert.match(await item.innerText(), /5 个文件（含清单）/);
        }
        receipt.complete_package_metadata_verified = true;
        receipt.postconditions = reportPath;
        await screen('complete-package-metadata-after-restart');
      }
      const response = await page.goto(origin + '/admin/backups/create'); assert.equal(response.status(), 503);
      assert.equal(await page.getByRole('button', {name: '排队创建备份', exact: true}).count(), 0);
      await page.goto(origin + '/admin/jobs');
      assert.doesNotMatch(await page.locator('header p').innerText(), /备份创建/);
      await screen('unconfigured-tool');
    });
  } else {
    let backupId;
    await check('owner-confirms-reauthenticates-and-production-cli-worker-creates-real-five-file-backup', async () => {
      backupId = await create('owner', true);
    });
    await check('independent-production-verification-job-publishes-current-backup-history', async () => {
      await verify(backupId); await screen('created-and-independently-verified');
    });
    await check('recovery-only-can-create-real-package-without-service-configuration-access', async () => {
      await logout(); await login('recovery'); await create('recovery');
      const denied = await page.goto(origin + '/admin/configuration'); assert.equal(denied.status(), 403);
      await page.goto(origin + '/admin/overview'); await logout();
    });
    await check('service-and-owner-without-recovery-denied-and-narrow-confirmation-is-keyboard-usable', async () => {
      for (const role of ['service', 'owner_without_recovery']) {
        await login(role); await page.goto(origin + '/admin/backups');
        assert.equal(await page.getByRole('link', {name: '创建新备份', exact: true}).count(), 0);
        const denied = await page.goto(origin + '/admin/backups/create'); assert.equal(denied.status(), 403);
        await page.goto(origin + '/admin/overview'); await logout();
      }
      await login('owner'); await page.goto(origin + '/admin/backups/create');
      await page.setViewportSize({width: 390, height: 844}); await page.emulateMedia({reducedMotion: 'reduce'});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.locator('[name=current_password]').focus(); await page.keyboard.press('Tab');
      assert.equal(await page.locator('[name=confirm_target]').evaluate(element => element === document.activeElement), true);
      await screen('creation-confirm-narrow');
    });
  }
  await logout();
  assert.deepEqual(receipt.page_errors, []);
  assert.deepEqual(receipt.console_issues.filter(item => item.category === 'other'), []);
  receipt.phase = 'passed'; receipt.summary = {passed: receipt.checks.length, real_creations: receipt.creations.length}; await save();
}
main().catch(async error => {
  receipt.phase = 'failed'; receipt.failure = {name: error.name, message: safe(error.message)};
  await save(); console.error('FAILED ' + safe(error.message)); process.exitCode = 1;
}).finally(async () => { if (context) await context.close(); });
