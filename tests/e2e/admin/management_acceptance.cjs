// Real Jinja admin UI, synthetic identities and an owned Chrome UUID profile.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID, createHash} = require('node:crypto');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '../../..');
const arg = process.argv.indexOf('--fixture');
if (arg < 0 || !process.argv[arg + 1]) throw new Error('Pass the prepared isolated admin --fixture');
const fixturePath = path.resolve(process.argv[arg + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture location');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), `browser-${runId}`);
const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-p5-admin-${runId}`);
let context;
let page;
let secrets = [];
let priorChecks = new Set();
const receipt = {run_id: runId, kind: 'normal-admin-management-browser', phase: 'starting', headed: true,
  personal_profile: false, checks: [], page_errors: [], console_issues: []};
const safe = (text) => secrets.reduce((value, secret) => value.split(secret).join('[redacted]'), String(text));
const json = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
async function check(name, action) {
  if (priorChecks.has(name)) return;
  receipt.phase = name;
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  await action(); receipt.checks.push({name, result: 'passed'});
  await fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(receipt, null, 2));
  console.log(`PASS ${name}`);
}
async function screen(name) {
  await page.screenshot({path: path.join(output, name + '.png'),
    mask: [page.locator('input'), page.locator('header p'), page.locator('tbody td:first-child')]});
  await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
}
async function main() {
  const fixture = await json(fixturePath);
  if (fixture.purpose !== 'flowtrace-p5-admin-synthetic' || fixture.state !== 'seeded'
      || fixture.origin !== 'http://127.0.0.1:18087') throw new Error('Unexpected synthetic server');
  const privatePath = path.resolve(fixture.credentials_path);
  if (!privatePath.startsWith(path.join(root, 'work/flowtrace-dev') + path.sep)
      || !/^admin-qa-[0-9a-f-]{36}\.json$/.test(path.basename(privatePath))) throw new Error('Unexpected credentials location');
  const credentials = await json(privatePath);
  secrets = Object.values(credentials).flatMap((value) => typeof value === 'string' ? [value] : Object.values(value))
    .filter((value) => typeof value === 'string' && value.length >= 8).sort((a, b) => b.length - a.length);
  await fs.mkdir(output, {recursive: true}); await fs.mkdir(path.dirname(profile), {recursive: true}); await fs.mkdir(profile);
  receipt.fixture_run_id = fixture.run_id; receipt.profile = profile; receipt.origin = fixture.origin;
  const resumeArg = process.argv.indexOf('--resume-receipt');
  if (resumeArg >= 0) {
    const previousPath = path.resolve(process.argv[resumeArg + 1]);
    if (!previousPath.startsWith(path.dirname(fixturePath) + path.sep)) throw new Error('Unrelated prior receipt');
    const previous = await json(previousPath);
    const prefix = ['owner-keyboard-login-operational-metadata-and-user-search',
      'reauthenticated-password-reset-revokes-original-api-session',
      'owner-role-change-and-last-enabled-owner-protection'];
    assert.equal(previous.fixture_run_id, fixture.run_id); assert.equal(previous.phase, 'failed');
    assert.deepEqual(previous.checks, prefix.map((name) => ({name, result: 'passed'})));
    priorChecks = new Set(prefix);
    receipt.prior_checks = previous.checks; receipt.prior_receipt = path.relative(root, previousPath);
  }
  context = await chromium.launchPersistentContext(profile, {executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: {width: 1280, height: 900}, acceptDownloads: true});
  receipt.browser = context.browser().version(); page = context.pages()[0]; page.setDefaultTimeout(15000);
  page.on('pageerror', (error) => receipt.page_errors.push({name: error.name, phase: receipt.phase}));
  page.on('console', (message) => {
    if (!['error', 'warning'].includes(message.type())) return;
    const category = /Failed to load resource:.*(?:401|403|409)/.test(message.text()) ? 'expected_rejected_http'
      : message.location().url.endsWith('/favicon.ico') && /404/.test(message.text()) ? 'missing_favicon' : 'other';
    receipt.console_issues.push({type: message.type(), category, phase: receipt.phase});
  });
  const login = async (label) => {
    await page.goto(fixture.origin + '/admin/login');
    await page.getByLabel('管理员账号', {exact: true}).fill(credentials[label].username);
    // Exercise the ordinary keyboard path from username into its password.
    await page.keyboard.press('Tab');
    assert.equal(await page.locator('input[name=password]').evaluate((input) => input === document.activeElement), true);
    await page.keyboard.type(credentials[label].password);
    await page.getByRole('button', {name: '登录后台', exact: true}).click();
    await page.getByRole('heading', {name: '服务概况', exact: true}).waitFor();
  };
  const logout = async () => { await page.getByRole('button', {name: '退出登录', exact: true}).click(); await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor(); };
  const search = async (label) => {
    await page.goto(fixture.origin + '/admin/users');
    await page.getByLabel('账号名称或编号', {exact: true}).fill(credentials[label].username);
    await page.getByRole('button', {name: '搜索用户', exact: true}).click();
    assert.equal(await page.locator('tbody tr').count(), 1);
    assert.match(await page.locator('tbody').innerText(), /有效会话|无摘要/);
  };
  if (priorChecks.size) await login('owner');
  await check('owner-keyboard-login-operational-metadata-and-user-search', async () => {
    await login('owner');
    await page.getByText('最近成功校验', {exact: true}).waitFor();
    await page.getByText('执行器心跳', {exact: true}).waitFor();
    await search('reset_target');
    assert.match(await page.locator('tbody').innerText(), /就绪 0 个 · 0 字节/);
    await screen('user-search');
  });
  await check('reauthenticated-password-reset-revokes-original-api-session', async () => {
    await page.getByRole('link', {name: '重置密码', exact: true}).click();
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.wrong_password);
    await page.getByLabel('用户新密码', {exact: true}).fill(credentials.reset_target.new_password);
    await page.getByLabel('再次输入用户新密码', {exact: true}).fill(credentials.reset_target.new_password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认重置密码', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '当前管理密码验证失败'}).waitFor();
    assert.equal(await page.locator('input[name=new_password]').inputValue(), '');
    const original = await context.request.get(fixture.origin + '/api/v1/users/me',
      {headers: {authorization: 'Bearer ' + credentials.reset_target.original_access_token}});
    assert.equal(original.status(), 200);
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.getByLabel('用户新密码', {exact: true}).fill(credentials.reset_target.new_password);
    await page.getByLabel('再次输入用户新密码', {exact: true}).fill(credentials.reset_target.new_password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认重置密码', exact: true}).click();
    await page.getByRole('heading', {name: /的会话$/}).waitFor();
    assert.match(await page.locator('tbody').innerText(), /已撤销/);
    const revoked = await context.request.get(fixture.origin + '/api/v1/users/me',
      {headers: {authorization: 'Bearer ' + credentials.reset_target.original_access_token}});
    assert.equal(revoked.status(), 401);
    const authenticated = await context.request.post(fixture.origin + '/api/v1/auth/login', {data: {
      username: credentials.reset_target.username, password: credentials.reset_target.new_password,
      client_id: randomUUID(), device_name: 'Synthetic reset verification', client_kind: 'native'}});
    assert.equal(authenticated.status(), 200);
    assert.equal((await authenticated.json()).user_id, fixture.identities.reset_target.user_id);
    receipt.reset_http_statuses = {before_failed_reset: original.status(), after_reset: revoked.status(), new_login: authenticated.status()};
    await screen('password-reset');
  });
  await check('owner-role-change-and-last-enabled-owner-protection', async () => {
    await search('role_target'); await page.getByRole('link', {name: '管理角色', exact: true}).click();
    for (const role of ['server_owner', 'service_admin', 'recovery_admin']) await page.locator(`input[name=roles][value=${role}]`).setChecked(role === 'recovery_admin');
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认保存角色', exact: true}).click();
    await search('role_target'); assert.match(await page.locator('tbody').innerText(), /恢复管理员/);
    await search('owner'); await page.getByRole('link', {name: '管理角色', exact: true}).click();
    await page.locator('input[name=roles][value=server_owner]').uncheck();
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    await page.locator('input[name=confirm_target]').check();
    await page.getByRole('button', {name: '确认保存角色', exact: true}).click();
    await page.getByRole('alert').filter({hasText: '服务器所有者'}).waitFor();
    assert.equal(await page.locator('input[name=roles][value=server_owner]').isChecked(), true);
    await screen('last-owner-protected');
  });
  await check('audit-filters-stable-pagination-and-reauthenticated-jsonl-download', async () => {
    await page.goto(fixture.origin + '/admin/audit');
    await page.getByLabel('动作', {exact: true}).fill('fixture.browser_page');
    await page.getByLabel('操作者编号', {exact: true}).fill(fixture.identities.owner.user_id);
    const date = new Date(); const yesterday = new Date(date.valueOf() - 86400000).toISOString().slice(0, 10);
    const tomorrow = new Date(date.valueOf() + 86400000).toISOString().slice(0, 10);
    await page.getByLabel('起始时间（UTC）', {exact: true}).fill(yesterday + 'T00:00');
    await page.getByLabel('结束时间（UTC，不含）', {exact: true}).fill(tomorrow + 'T00:00');
    await page.getByRole('button', {name: '查询审计', exact: true}).click();
    assert.match(await page.locator('.pagination').innerText(), /共 56 条/);
    assert.equal(await page.locator('tbody tr').count(), 50);
    const first = await page.locator('tbody tr td:last-child').allTextContents();
    await page.getByRole('link', {name: '下一页', exact: true}).click();
    assert.equal(await page.locator('tbody tr').count(), 6);
    const second = await page.locator('tbody tr td:last-child').allTextContents();
    assert(!second.some((id) => first.includes(id)));
    await page.getByLabel('当前管理密码', {exact: true}).fill(credentials.owner.password);
    const downloaded = page.waitForEvent('download');
    await page.getByRole('button', {name: '导出审计JSONL', exact: true}).click();
    const download = await downloaded; const file = path.join(output, 'admin-audit.jsonl'); await download.saveAs(file);
    const bytes = await fs.readFile(file); const text = bytes.toString('utf8');
    const rows = text.trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows[0].count, 56); assert.equal(rows.length, 57);
    assert(!secrets.some((value) => text.includes(value)));
    receipt.audit_export = {rows: 56, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex')};
    await page.getByRole('combobox', {name: '结果', exact: true}).selectOption('failed');
    await page.getByRole('button', {name: '查询审计', exact: true}).click();
    assert.match(await page.locator('.pagination').innerText(), /共 28 条/);
    await screen('audit-filtered-export');
  });
  await check('recovery-service-boundaries-and-private-book-denial', async () => {
    await logout(); await login('recovery');
    assert.equal(await page.getByRole('link', {name: '用户与会话', exact: true}).count(), 0);
    const denied = await page.goto(fixture.origin + '/admin/users'); assert.equal(denied.status(), 403);
    await page.goto(fixture.origin + '/admin/overview'); await logout(); await login('service');
    await search('reset_target'); assert.equal(await page.getByRole('link', {name: '管理角色', exact: true}).count(), 0);
    const forbidden = await page.goto(fixture.origin + `/admin/users/${fixture.identities.owner.user_id}/roles`); assert.equal(forbidden.status(), 403);
    const loginResponse = await context.request.post(fixture.origin + '/api/v1/auth/login', {data: {
      username: credentials.service.username, password: credentials.service.password,
      client_id: randomUUID(), device_name: 'Synthetic role boundary', client_kind: 'native'}});
    assert.equal(loginResponse.status(), 200); const tokens = await loginResponse.json();
    const privateBook = await context.request.get(fixture.origin + `/api/v1/books/${fixture.identities.reset_target.book_id}/members`,
      {headers: {authorization: 'Bearer ' + tokens.access_token}});
    assert([403, 404].includes(privateBook.status()));
    receipt.role_http_statuses = {recovery_users: denied.status(), service_roles: forbidden.status(), private_book: privateBook.status()};
    await page.goto(fixture.origin + '/admin/overview');
  });
  await check('narrow-layout-local-recovery-instructions-and-logout', async () => {
    await page.setViewportSize({width: 390, height: 844});
    await page.getByRole('link', {name: '用户与会话', exact: true}).click();
    await page.getByRole('button', {name: '搜索用户', exact: true}).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await screen('admin-narrow');
    await page.getByRole('link', {name: '本机恢复说明', exact: true}).click();
    await page.getByRole('heading', {name: '本机受控恢复', exact: true}).waitFor();
    assert.equal(await page.locator('code.command').count(), 1);
    assert.equal(await page.locator('form[action*=recovery]').count(), 0);
    await logout();
    await page.goto(fixture.origin + '/admin/overview'); await page.getByRole('heading', {name: '流迹管理', exact: true}).waitFor();
  });
  assert.deepEqual(receipt.page_errors, []);
  assert(!receipt.console_issues.some((issue) => issue.category === 'other'));
  // Expected 403/401 network statuses can produce browser console errors;
  // captured categories contain no response body, URL, form or credentials.
  receipt.phase = 'passed';
}
main().catch(async (error) => {
  receipt.phase = 'failed'; receipt.error = safe(error.stack || error); process.exitCode = 1;
  console.error(receipt.error);
  if (page) { try { await screen('failure'); } catch (_) { /* preserve primary failure */ } }
}).finally(async () => {
  if (context) await context.close(); receipt.finished_at = new Date().toISOString();
  await fs.mkdir(output, {recursive: true}); await fs.writeFile(path.join(output, 'receipt.json'), safe(JSON.stringify(receipt, null, 2)));
  console.log(`RECEIPT ${path.relative(root, path.join(output, 'receipt.json'))}`);
});
