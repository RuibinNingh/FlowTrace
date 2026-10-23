'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../..');
const [phase, input, jobArgument] = process.argv.slice(2);
const read = async file => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const uuid = value => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);

async function main() {
  assert.ok(['enqueue', 'completed', 'failed'].includes(phase));
  const fixturePath = path.resolve(input || '');
  const fixture = await read(fixturePath), run = fixture.run_id;
  assert.match(run, /^[0-9a-f]{32}$/);
  assert.equal(fixturePath, path.join(root, 'outputs/validation/P5/admin', 'quarantine-' + run, 'fixture.json'));
  assert.equal(fixture.purpose, 'flowtrace-quarantine-browser-synthetic-v1');
  assert.equal(fixture.expected_head, '0016_backup_quarantine');
  assert.equal(fixture.api_origin, 'http://127.0.0.1:18096');
  assert.equal(fixture.restorable_dump, false);
  const privateFile = path.join(root, 'work/flowtrace-dev', 'quarantine-' + run + '.json');
  assert.equal(fixture.credential_file, privateFile);
  const credentials = await read(privateFile);
  const secrets = [credentials.wrong_password, ...['owner', 'recovery_only', 'service_only']
    .flatMap(key => [credentials[key].username, credentials[key].password])];
  const safe = value => secrets.reduce((text, value) => text.split(value).join('[redacted]'), String(value));
  const profile = path.resolve('C:/ft-chrome', 'q-' + run.slice(0, 12));
  const bindingFile = path.join(path.dirname(fixturePath), 'owned-browser-profile.json');
  const binding = { purpose: 'flowtrace-quarantine-owned-chrome-v1', run_id: run, profile };
  try {
    assert.deepEqual(await read(bindingFile), binding);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    try {
      await fs.access(profile);
      throw new Error('Unbound existing profile refused');
    } catch (profileError) {
      if (profileError.code !== 'ENOENT') throw profileError;
    }
    await fs.writeFile(bindingFile, JSON.stringify(binding, null, 2), { flag: 'wx' });
  }
  const stamp = new Date().toISOString().replace(/[^0-9TZ]/g, '');
  const output = path.join(path.dirname(fixturePath), 'browser-' + phase + '-' + stamp);
  await fs.mkdir(output);
  const result = { purpose: 'quarantine-ordinary-browser-v1', phase, run_id: run, profile,
    node_pid: process.pid,
    origin: fixture.api_origin, headed: true, restorable_dump: false, started_at: new Date().toISOString(),
    result: 'running', checks: [], http: [], errors: [] };
  let context, page, sensitive = false, step = 'launch';
  const save = () => fs.writeFile(path.join(output, 'receipt.json'), JSON.stringify(result, null, 2));
  const selected = ['selected_a', 'selected_b'].map(key => fixture.packages[key].id);
  try {
    context = await chromium.launchPersistentContext(profile, {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
      locale: 'zh-CN', viewport: { width: 1280, height: 900 },
    });
    result.browser_version = context.browser().version();
    page = context.pages()[0]; page.setDefaultTimeout(20000);
    page.on('pageerror', error => result.errors.push({ type: 'pageerror', name: error.name }));
    page.on('response', response => {
      const url = new URL(response.url());
      if (url.origin === fixture.api_origin) result.http.push({ method: response.request().method(), path: url.pathname, status: response.status() });
    });
    const check = async (name, action) => {
      step = name; await save(); await action(); result.checks.push(name); await save();
    };
    const screen = async name => {
      await page.screenshot({ path: path.join(output, name + '.png'), mask: [page.locator('input')] });
      await fs.writeFile(path.join(output, name + '-aria.txt'), safe(await page.locator('body').ariaSnapshot()));
    };
    const route = suffix => fixture.api_origin + suffix;
    const login = async role => {
      await page.goto(route('/admin/login'));
      sensitive = true;
      await page.getByLabel('管理员账号', { exact: true }).fill(credentials[role].username);
      await page.getByLabel('密码', { exact: true }).fill(credentials[role].password);
      await page.getByRole('button', { name: '登录后台', exact: true }).click();
      await page.getByRole('heading', { name: '服务概况', exact: true }).waitFor();
      sensitive = false;
    };
    const logout = async () => {
      await page.goto(route('/admin/overview'));
      await page.getByRole('button', { name: '退出登录', exact: true }).click();
      await page.getByRole('heading', { name: '流迹管理', exact: true }).waitFor();
    };
    const catalog = async () => {
      await page.goto(route('/admin/backups/retention'));
      await page.getByRole('heading', { name: '备份保留与保护', exact: true }).waitFor();
    };
    const preview = async () => {
      for (const id of selected) await page.getByRole('checkbox', { name: '选择备份 ' + id, exact: true }).check();
      await page.getByLabel('当前管理密码', { exact: true }).fill(credentials.owner.password);
      await page.locator('[name=confirm_target]').check();
      await page.getByRole('button', { name: '验证所选备份并预览', exact: true }).click();
      await page.getByRole('heading', { name: '零删除预览报告', exact: true }).waitFor();
      for (const id of selected) assert.equal(await page.getByRole('heading', { name: id, exact: true }).count(), 1);
      const text = await page.locator('main').innerText();
      for (const key of ['pinned', 'unregistered', 'newest_witness']) assert.ok(!text.includes(fixture.packages[key].id));
      await page.getByRole('link', { name: '核对隔离所选备份', exact: true }).click();
      await page.getByRole('heading', { name: '确认隔离所选备份', exact: true }).waitFor();
    };
    if (phase === 'enqueue') {
      await login('owner');
      await check('real-candidate-entry-protected-and-only-two-eligible', async () => {
        await page.goto(route('/admin/backups'));
        await page.getByRole('link', { name: '查看保留候选', exact: true }).click();
        for (const id of selected) assert.equal(await page.getByRole('checkbox', { name: '选择备份 ' + id, exact: true }).isEnabled(), true);
        for (const key of ['pinned', 'unregistered', 'newest_witness']) assert.equal(
          await page.getByRole('checkbox', { name: '选择备份 ' + fixture.packages[key].id, exact: true }).isDisabled(), true);
        await screen('candidate-desktop');
      });
      await check('new-zero-delete-preview-and-explicit-closed-confirmation', async () => {
        await preview();
        const form = page.locator('form[action$="/quarantine"]');
        assert.equal(await form.count(), 1);
        result.first_preview_id = new URL(page.url()).pathname.split('/').at(-2);
        assert.ok(uuid(result.first_preview_id));
        assert.ok((await form.locator('[name=csrf_token]').inputValue()).length > 10);
        assert.equal(await form.locator('[name=confirm_target]').inputValue(), result.first_preview_id);
        assert.equal(await form.locator('[name=confirm_target]').isChecked(), false);
        assert.equal(await form.getByLabel('当前管理密码').inputValue(), '');
        await screen('confirmation-desktop');
      });
      await check('wrong-current-password-rejected-with-no-password-echo', async () => {
        await page.getByLabel('当前管理密码', { exact: true }).fill(credentials.wrong_password);
        await page.locator('[name=confirm_target]').check();
        await page.getByRole('button', { name: '排队隔离这些备份', exact: true }).click();
        await page.getByRole('alert').filter({ hasText: '当前管理密码验证失败' }).waitFor();
        assert.equal(await page.getByLabel('当前管理密码', { exact: true }).inputValue(), '');
        await screen('wrong-password');
      });
      await check('fresh-preview-narrow-layout-and-keyboard-target-confirmation', async () => {
        await catalog(); await preview();
        result.preview_id = new URL(page.url()).pathname.split('/').at(-2);
        assert.notEqual(result.preview_id, result.first_preview_id);
        await page.setViewportSize({ width: 390, height: 844 });
        await page.emulateMedia({ reducedMotion: 'reduce' });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await page.getByLabel('当前管理密码', { exact: true }).fill(credentials.owner.password);
        await page.getByLabel('当前管理密码', { exact: true }).focus();
        await page.keyboard.press('Tab');
        const target = page.locator('[name=confirm_target]');
        assert.equal(await target.evaluate(element => element === document.activeElement), true);
        await page.keyboard.press('Space'); assert.equal(await target.isChecked(), true);
        await screen('confirmation-narrow-keyboard');
        await page.keyboard.press('Tab');
        const button = page.getByRole('button', { name: '排队隔离这些备份', exact: true });
        assert.equal(await button.evaluate(element => element === document.activeElement), true);
        await page.keyboard.press('Enter');
        await page.waitForURL(/\/admin\/jobs\?kind=backup_quarantine#job-[0-9a-f-]{36}$/);
        result.job_id = new URL(page.url()).hash.slice('#job-'.length);
        assert.ok(uuid(result.job_id));
      });
      await check('genuine-pending-job-list-no-generic-cancel-or-retry', async () => {
        const row = page.locator('#job-' + result.job_id);
        await row.getByText('待执行', { exact: true }).waitFor();
        assert.equal(await row.getByRole('link', { name: '取消', exact: true }).count(), 0);
        assert.equal(await row.getByRole('link', { name: '重试', exact: true }).count(), 0);
        await screen('queued-narrow');
        await page.setViewportSize({ width: 1280, height: 900 });
        await screen('queued-desktop');
      });
      result.original_admin_session_kept_active_for_worker = true;
    } else if (phase === 'failed') {
      assert.ok(uuid(jobArgument)); result.job_id = jobArgument;
      result.overall_quarantine_acceptance = 'failed';
      await check('actual-cli-failure-observed-with-reservations-preserved', async () => {
        await page.goto(route('/admin/jobs?kind=backup_quarantine#job-' + jobArgument));
        const row = page.locator('#job-' + jobArgument);
        await row.getByText('失败', { exact: true }).waitFor();
        await row.getByText('backup_package_unavailable', { exact: true }).waitFor();
        assert.equal(await row.getByRole('link', { name: /取消|重试/ }).count(), 0);
        await screen('failed-desktop');
        await page.setViewportSize({ width: 390, height: 844 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await screen('failed-narrow');
        await page.setViewportSize({ width: 1280, height: 900 });
        await catalog();
        for (const id of selected) assert.equal(await page.getByRole('checkbox', { name: '选择备份 ' + id, exact: true }).isDisabled(), true);
        await screen('reserved-after-failure');
        await logout();
      });
    } else {
      assert.ok(uuid(jobArgument)); result.job_id = jobArgument;
      await check('real-cli-completion-visible-in-normal-job-list', async () => {
        await page.goto(route('/admin/jobs?kind=backup_quarantine#job-' + jobArgument));
        const row = page.locator('#job-' + jobArgument);
        await row.getByText('已完成', { exact: true }).waitFor();
        await row.getByText('backup_quarantined', { exact: true }).waitFor();
        assert.equal(await row.getByRole('link', { name: /取消|重试/ }).count(), 0);
        await screen('completed-desktop');
        await page.setViewportSize({ width: 390, height: 844 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await screen('completed-narrow');
        await page.setViewportSize({ width: 1280, height: 900 });
      });
      await check('post-effect-protection-metadata-remains-conservative', async () => {
        await catalog();
        for (const id of selected) {
          const row = page.locator('tr').filter({ has: page.getByRole('checkbox', { name: '选择备份 ' + id, exact: true }) });
          assert.equal(await row.getByText(/已隔离/).count() > 0, true);
          assert.equal(await row.getByRole('checkbox').isDisabled(), true);
        }
        await screen('post-effect-candidate');
      });
      await check('service-only-role-denied-quarantine-route', async () => {
        await logout(); await login('recovery_only'); await catalog();
        const configuration = await page.goto(route('/admin/configuration'));
        assert.equal(configuration.status(), 403);
        await logout(); await login('service_only');
        const response = await page.goto(route('/admin/backups/retention'));
        assert.equal(response.status(), 403);
        const body = await page.locator('body').innerText();
        for (const id of selected) assert.ok(!body.includes(id));
        await logout();
      });
    }
    assert.deepEqual(result.errors, []);
    result.result = 'passed';
  } catch (error) {
    result.result = 'failed'; result.failure = { step, name: error.name, message: safe(error.message).slice(0, 900) };
    if (page && !sensitive) {
      await page.screenshot({ path: path.join(output, 'failure.png'), mask: [page.locator('input')] }).catch(() => {});
      await fs.writeFile(path.join(output, 'failure-aria.txt'), safe(await page.locator('body').ariaSnapshot())).catch(() => {});
    }
  } finally {
    if (context) await context.close();
    result.ended_at = new Date().toISOString(); await save();
    console.log(JSON.stringify({ result: result.result, phase, checks: result.checks.length,
      job_id: result.job_id, receipt: path.join(output, 'receipt.json'), failure: result.failure }));
    if (result.result === 'failed') process.exitCode = 1;
  }
}
main().catch(error => { console.error(JSON.stringify({ result: 'failed-before-browser', name: error.name })); process.exitCode = 1; });
