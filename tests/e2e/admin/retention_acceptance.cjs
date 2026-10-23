'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '../../..');
const index = process.argv.indexOf('--fixture');
if (index < 0 || !process.argv[index + 1]) throw new Error('Pass --fixture');
const fixturePath = path.resolve(process.argv[index + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) {
  throw new Error('Unexpected synthetic fixture');
}
const run = randomUUID(), output = path.join(path.dirname(fixturePath), 'browser-' + run);
const profile = path.join('C:/ft-chrome', 'rt-' + run.slice(0, 8));
const read = async file => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
let fixture, credentials, context, page, secrets = [];
const receipt = {run_id: run, purpose: 'retention-browser-acceptance', phase: 'starting',
  headed: true, personal_profile: false, checks: [], page_errors: [], console_issues: []};
const safe = value => secrets.reduce((text, item) => text.split(item).join('[redacted]'), String(value));
const save = () => fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
async function check(name, callback) {
  receipt.phase = name; await save(); await callback();
  receipt.checks.push({name, result: 'passed'}); await save(); console.log('PASS ' + name);
}
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'), mask: [page.locator('input[type=password]')]});
  await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
}
const origin = () => fixture.api_origin;
const route = pathname => origin() + pathname;
const packageId = name => fixture.packages[name].id;
async function login(name) {
  await page.goto(route('/admin/login'));
  await page.getByLabel('管理员账号', {exact: true}).fill(credentials[name].username);
  await page.getByLabel('密码', {exact: true}).fill(credentials[name].password);
  await page.getByRole('button', {name: '登录后台', exact: true}).click();
  await page.getByRole('heading', {name: '服务概况', exact: true}).waitFor();
}
async function logout() {
  await page.goto(route('/admin/overview'));
  await page.getByRole('button', {name: '退出登录', exact: true}).click();
  await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
}
async function catalog() {
  await page.goto(route('/admin/backups/retention'));
  await page.getByRole('heading', {name: '备份保留与保护', exact: true}).waitFor();
}
async function selectPreview(password) {
  for (const key of ['old_eligible', 'old_unregistered']) {
    await page.getByRole('checkbox', {name: '选择备份 ' + packageId(key), exact: true}).check();
  }
  await page.getByLabel('当前管理密码', {exact: true}).fill(password);
  await page.locator('[name=confirm_target]').check();
  await page.getByRole('button', {name: '验证所选备份并预览', exact: true}).click();
}
async function main() {
  fixture = await read(fixturePath);
  assert.equal(fixture.purpose, 'flowtrace-retention-browser-synthetic');
  assert.equal(fixture.api_origin, 'http://127.0.0.1:18092');
  const privateFile = path.resolve(fixture.credential_file);
  assert.ok(privateFile.startsWith(path.join(root, 'work/flowtrace-dev') + path.sep));
  credentials = await read(privateFile);
  secrets = [...Object.values(credentials).filter(value => typeof value === 'string'),
    ...Object.values(credentials).filter(value => value && typeof value === 'object').map(value => value.password)]
    .filter(value => typeof value === 'string' && value.length >= 8).sort((a, b) => b.length - a.length);
  await fs.mkdir(output); await fs.mkdir(profile, {recursive: true});
  receipt.fixture = fixturePath; receipt.origin = fixture.api_origin; receipt.profile = profile;
  context = await chromium.launchPersistentContext(profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: {width: 1280, height: 900},
  });
  receipt.browser = context.browser().version();
  page = context.pages()[0]; page.setDefaultTimeout(20000);
  page.on('pageerror', error => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', message => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409|422|503)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase,
      ...(category === 'other' ? {message: safe(message.text())} : {})});
  });
  await login('owner');
  await check('ordinary-backup-entry-and-protected-candidate-reasons', async () => {
    await page.goto(route('/admin/backups'));
    await page.getByRole('link', {name: '查看保留候选', exact: true}).click();
    await page.getByRole('heading', {name: '备份保留与保护', exact: true}).waitFor();
    for (const key of ['old_unregistered', 'newest_witness', 'pinned']) {
      assert.equal(await page.getByRole('checkbox', {name: '选择备份 ' + packageId(key), exact: true}).isDisabled(), true);
    }
    assert.equal(await page.getByRole('checkbox', {name: '选择备份 ' + packageId('old_eligible'), exact: true}).isEnabled(), true);
    assert.equal(await page.getByRole('button', {name: /隔离|销毁|删除备份/}).count(), 0);
    await screen('candidate-desktop');
  });
  await check('explicit-registration-rechecks-password-and-fresh-fixed-target', async () => {
    const id = packageId('old_unregistered');
    await page.goto(route('/admin/backups/' + id + '/register'));
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.wrong_password);
    await page.locator('[name=confirm_target]').check();
    await page.getByRole('button', {name: '完整验证并登记', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.getByLabel('当前管理密码', {exact: true}).inputValue(), '');
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('[name=confirm_target]').check();
    await page.getByRole('button', {name: '完整验证并登记', exact: true}).click();
    await page.getByRole('heading', {name: '备份保留标记', exact: true}).waitFor();
    assert.equal(new URL(page.url()).pathname, '/admin/backups/' + id + '/protection');
    await screen('registered-fixed-target');
  });
  await check('create-and-release-exact-pin-with-current-password-and-cas', async () => {
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('[name=confirm_target]').check();
    await page.getByRole('button', {name: '保留此备份', exact: true}).click();
    const release = page.locator('form[action$="/release"]');
    await release.waitFor(); assert.equal(await release.count(), 1);
    await release.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await release.locator('[name=confirm_target]').check();
    await release.getByRole('button', {name: '解除这个标记', exact: true}).click();
    await page.getByText('此页没有尚未解除的保留标记，其他保护仍可能存在。', {exact: true}).waitFor();
    assert.equal(await page.locator('form[action$="/release"]').count(), 0);
  });
  await check('preview-rechecks-password-and-displays-only-explicitly-selected-uuids', async () => {
    await catalog(); await selectPreview(credentials.wrong_password);
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.getByLabel('当前管理密码', {exact: true}).inputValue(), '');
    await selectPreview(credentials.owner.password);
    await page.getByRole('heading', {name: '零删除预览报告', exact: true}).waitFor();
    for (const key of ['old_eligible', 'old_unregistered']) {
      assert.equal(await page.getByRole('heading', {name: packageId(key), exact: true}).count(), 1);
    }
    const text = await page.locator('main').innerText();
    for (const key of ['newest_witness', 'pinned']) assert.ok(!text.includes(packageId(key)));
    assert.match(text, /2 个备份/);
    assert.equal(await page.locator('main form').count(), 0);
    await screen('explicit-zero-delete-report');
  });
  await check('twenty-pin-page-and-one-pin-continuation-stay-bounded', async () => {
    await page.goto(route('/admin/backups/' + packageId('pinned') + '/protection'));
    assert.equal(await page.locator('form[action$="/release"]').count(), 20);
    await page.getByRole('link', {name: '下一页标记', exact: true}).click();
    assert.equal(await page.locator('form[action$="/release"]').count(), 1);
    await screen('pin-continuation');
  });
  await check('narrow-layout-keyboard-confirmation-and-reduced-motion', async () => {
    await page.setViewportSize({width: 390, height: 844});
    await page.emulateMedia({reducedMotion: 'reduce'}); await catalog();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.getByLabel('当前管理密码', {exact: true}).focus(); await page.keyboard.press('Tab');
    assert.equal(await page.locator('[name=confirm_target]').evaluate(element => element === document.activeElement), true);
    await screen('candidate-narrow');
    await page.goto(route('/admin/backups/' + packageId('old_unregistered') + '/protection'));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await screen('protection-narrow'); await page.setViewportSize({width: 1280, height: 900});
  });
  await check('recovery-only-authorized-and-service-only-denied', async () => {
    await logout(); await login('recovery_only'); await catalog();
    const config = await page.goto(route('/admin/configuration')); assert.equal(config.status(), 403);
    await logout(); await login('service_only');
    await page.goto(route('/admin/backups'));
    assert.equal(await page.getByRole('link', {name: '查看保留候选', exact: true}).count(), 0);
    for (const target of ['/admin/backups/retention', '/admin/backups/' + packageId('pinned') + '/protection']) {
      const response = await page.goto(route(target)); assert.equal(response.status(), 403);
      assert.ok(!(await page.locator('body').innerText()).includes(packageId('pinned')));
    }
    await logout();
  });
  assert.deepEqual(receipt.page_errors, []);
  assert.deepEqual(receipt.console_issues.filter(item => item.category === 'other'), []);
  receipt.phase = 'passed'; receipt.summary = {passed: receipt.checks.length}; await save();
}
main().catch(async error => {
  receipt.phase = 'failed'; receipt.failure = {name: error.name, message: safe(error.message)};
  await save(); console.error('FAILED ' + safe(error.message)); process.exitCode = 1;
}).finally(async () => { if (context) await context.close(); });
