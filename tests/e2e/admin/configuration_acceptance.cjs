// Real forms and a UUID-owned Chrome profile; never uses a personal browser.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '../../..');
const argument = process.argv.indexOf('--fixture');
if (argument < 0) throw new Error('Pass isolated --fixture');
const fixturePath = path.resolve(process.argv[argument + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), `configuration-browser-${runId}`);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p5-configuration-${runId}`);
const receipt = {run_id: runId, kind: 'real-configuration-cas-secret-rollback-and-role-forms', headed: true,
  personal_profile: false, phase: 'starting', checks: [], page_errors: [], console_issues: []};
let context, page, credentials, origin, secrets = [];
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const safe = (value) => secrets.reduce((text, item) => text.split(item).join('[redacted]'), String(value));
async function save() { await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2)); }
async function check(name, action) {
  receipt.phase = name; await save(); await action(); receipt.checks.push({name, result: 'passed'}); await save();
  console.log('PASS ' + name);
}
const input = (key, target = page) => target.locator(`[name="${key}"]`);
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'), mask: [page.locator('input')]});
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
async function configuration(target = page) {
  await target.goto(origin + '/admin/configuration');
  await target.getByRole('heading', {name: '服务配置', exact: true}).waitFor();
  return Number(await input('base_version', target).inputValue());
}
async function submit(target = page, label = 'owner', password = credentials[label].password) {
  await input('current_password', target).fill(password);
  await input('confirm_version', target).check();
  await target.getByRole('button', {name: '保存为新版本', exact: true}).click();
}
async function main() {
  const fixture = await read(fixturePath);
  assert.equal(fixture.purpose, 'flowtrace-p5-admin-synthetic');
  origin = fixture.origin; assert.equal(origin, 'http://127.0.0.1:18087');
  const privatePath = path.resolve(fixture.credentials_path);
  if (!privatePath.startsWith(path.join(root, 'work/flowtrace-dev') + path.sep)) throw new Error('Unexpected credentials');
  credentials = await read(privatePath);
  assert.equal(typeof credentials.configuration_ai_secret, 'string');
  secrets = Object.values(credentials).flatMap(item => typeof item === 'string' ? [item] : Object.values(item))
    .filter(item => typeof item === 'string' && item.length >= 8).sort((a, b) => b.length - a.length);
  await fs.mkdir(output); await fs.mkdir(profile, {recursive: true});
  receipt.origin = origin; receipt.fixture = fixture.run_id; receipt.profile = profile;
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: {width: 1280, height: 900}});
  receipt.browser = context.browser().version(); page = context.pages()[0]; page.setDefaultTimeout(15000);
  context.on('page', item => item.on('pageerror', error => receipt.page_errors.push({name: error.name, phase: receipt.phase})));
  page.on('pageerror', error => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', message => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409|422)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase,
      ...(category === 'other' ? {message: safe(message.text())} : {})});
  });
  await login('owner');
  await check('public-preview-does-not-publish-and-needs-no-current-password', async () => {
    assert.equal(await configuration(), 0);
    await input('invitation_default_days').fill('9');
    await page.getByRole('button', {name: '预览公开设置', exact: true}).click();
    await page.getByRole('heading', {name: '公开设置预览', exact: true}).waitFor();
    assert.equal(await input('invitation_default_days').inputValue(), '9');
    assert.equal(await configuration(), 0);
    assert.equal(await input('invitation_default_days').inputValue(), '7');
    await screen('configuration-initial');
  });
  await check('wrong-password-rejected-then-real-secret-and-runtime-policy-published', async () => {
    await submit(page, 'owner', credentials.wrong_password);
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await input('current_password').inputValue(), '');
    assert.equal(Number(await input('base_version').inputValue()), 0);
    await input('registration_enabled').selectOption('false');
    await input('invitation_default_days').fill('9');
    await input('attachment_max_bytes').fill('1024');
    await input('per_user_attachment_quota_bytes').fill('2048');
    await input('worker_poll_seconds').fill('0.5');
    await input('ai_api_key_action').selectOption('replace');
    await input('ai_api_key_value').fill(credentials.configuration_ai_secret);
    await submit();
    assert.equal(Number(await input('base_version').inputValue()), 1);
    assert.equal(await input('registration_enabled').inputValue(), 'false');
    assert.equal(await input('ai_api_key_value').inputValue(), '');
    assert.equal(await page.content().then(content => content.includes(credentials.configuration_ai_secret)), false);
    await page.getByText('AI API 密钥 · 已配置', {exact: true}).waitFor();
    await page.getByRole('link', {name: '检查服务连接', exact: true}).click();
    const providerForm = page.locator('form[action="/admin/configuration/providers/ai_primary/check"]');
    await providerForm.locator('[name="current_password"]').fill(credentials.owner.password);
    await providerForm.locator('[name="confirm_provider"]').check();
    await providerForm.getByRole('button', {name: '检查 ai_primary', exact: true}).click();
    await page.getByRole('status').filter({hasText: 'provider_reachable'}).waitFor();
    await screen('configuration-real-provider-check');
    assert.equal(await configuration(), 1);
    await screen('configuration-secret-published');
  });
  await check('ordinary-two-tab-stale-form-refuses-overwrite-and-delete-keeps-history', async () => {
    const stale = await context.newPage();
    assert.equal(await configuration(stale), 1);
    await input('ai_api_key_action').selectOption('delete');
    await input('invitation_default_days').fill('10');
    await submit(); assert.equal(Number(await input('base_version').inputValue()), 2);
    await submit(stale);
    await stale.getByRole('alert').filter({hasText: '版本'}).waitFor();
    await stale.close();
    assert.equal(await configuration(), 2);
    assert.equal(await input('invitation_default_days').inputValue(), '10');
    await page.getByText('AI API 密钥 · 未配置', {exact: true}).waitFor();
  });
  await check('explicit-history-rollback-revalidates-retained-secret-and-default-version', async () => {
    await page.getByRole('link', {name: '查看版本历史', exact: true}).click();
    // Version-specific fixed path is still the ordinary generated history link.
    await page.locator('a[href="/admin/configuration/rollback/1"]').click();
    await page.getByRole('heading', {name: '预览回滚', exact: true}).waitFor();
    await input('current_password').fill(credentials.owner.password); await input('confirm_target').check();
    await page.getByRole('button', {name: '确认并生成新版本', exact: true}).click();
    assert.equal(Number(await input('base_version').inputValue()), 3);
    await page.getByText('AI API 密钥 · 已配置', {exact: true}).waitFor();
    await page.getByRole('link', {name: '查看版本历史', exact: true}).click();
    await page.getByRole('link', {name: '回到初始设置', exact: true}).click();
    await input('current_password').fill(credentials.owner.password); await input('confirm_target').check();
    await page.getByRole('button', {name: '确认并生成新版本', exact: true}).click();
    assert.equal(Number(await input('base_version').inputValue()), 4);
    assert.equal(await input('registration_enabled').inputValue(), 'true');
    assert.equal(await input('attachment_max_bytes').inputValue(), '10485760');
    await page.getByText('AI API 密钥 · 未配置', {exact: true}).waitFor();
    await screen('configuration-default-rollback');
  });
  await check('service-role-can-configure-and-recovery-only-role-has-no-config-authority', async () => {
    await logout(); await login('service'); assert.equal(await configuration(), 4);
    await input('invitation_default_days').fill('8'); await submit(page, 'service');
    assert.equal(Number(await input('base_version').inputValue()), 5);
    await logout(); await login('recovery');
    assert.equal(await page.getByRole('link', {name: '服务配置', exact: true}).count(), 0);
    const response = await page.goto(origin + '/admin/configuration'); assert.equal(response.status(), 403);
    await page.goto(origin + '/admin/overview'); await logout(); await login('owner');
  });
  await check('narrow-layout-keyboard-and-unregistered-provider-remain-explicit', async () => {
    assert.equal(await configuration(), 5);
    await page.setViewportSize({width: 390, height: 844}); await page.emulateMedia({reducedMotion: 'reduce'});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await input('current_password').focus(); await page.keyboard.press('Tab');
    assert.equal(await input('confirm_version').evaluate(element => element === document.activeElement), true);
    await screen('configuration-narrow');
    await page.setViewportSize({width: 1280, height: 900});
    await page.getByRole('link', {name: '检查服务连接', exact: true}).click();
    await page.getByRole('heading', {name: '服务连接检查', exact: true}).waitFor();
    assert.match(await page.locator('main').innerText(), /部署尚未登记/);
    await screen('configuration-providers');
    await logout();
  });
  assert.deepEqual(receipt.page_errors, []);
  assert.deepEqual(receipt.console_issues.filter(item => item.category === 'other'), []);
  receipt.phase = 'passed'; receipt.summary = {passed: receipt.checks.length, final_version: 5}; await save();
}
main().catch(async error => {
  receipt.phase = 'failed'; receipt.failure = {name: error.name, message: safe(error.message)};
  await save(); console.error('FAILED ' + safe(error.message)); process.exitCode = 1;
}).finally(async () => { if (context) await context.close(); });
