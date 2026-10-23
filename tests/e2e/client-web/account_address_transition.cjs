'use strict';
// Ordinary UI only, fresh owned Chrome profile; no credentials or app-state injection.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { chromium } = require('playwright');

async function main() {
  const root = path.resolve(__dirname, '../../..');
  const build = path.resolve(process.argv[2] || '');
  const expectedHash = process.argv[3];
  const origin = process.argv[4] || 'http://127.0.0.1:18190';
  const timing = process.argv[5] || 'immediate';
  const navigation = process.argv[6] || 'keyboard';
  const coldStart = process.argv[7] === 'cold';
  if (!build.startsWith(path.join(root, 'apps/flowtrace/build') + path.sep)
      || !/^[a-f0-9]{64}$/.test(expectedHash)
      || !['http://127.0.0.1:18190', 'http://127.0.0.1:18191'].includes(origin)
      || !['immediate', 'settled'].includes(timing)
      || !['keyboard', 'mouse'].includes(navigation)) {
    throw new Error('Fixed owned ordinary candidate required');
  }
  const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
  if (sha(await fs.readFile(path.join(build, 'main.dart.js'))) !== expectedHash) {
    throw new Error('Wrong candidate');
  }
  const run = randomUUID();
  const out = path.join(root, 'outputs/validation/P6', `account-address-${run}`);
  // Chromium's Windows CacheStorage can reject every put with
  // InvalidAccessError on deeply nested profiles; keep our isolated path short.
  const profile = path.join(root, 'work/browser-probes', run);
  await fs.mkdir(out, { recursive: true });
  const result = { run_id: run, ordinary_main_sha256: expectedHash, result: 'running',
    profile, timing, navigation, offline_cold_start_requested: coldStart,
    credentials_entered: false, checks: [], page_errors: [],
    resource_failures: [], shell_messages: [] };
  let context, page;
  try {
    context = await chromium.launchPersistentContext(profile, {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
      headless: false, locale: 'zh-CN', viewport: { width: 1280, height: 900 },
    });
    page = context.pages()[0];
    page.setDefaultTimeout(12000);
    context.on('requestfailed', (request) => {
      const url = new URL(request.url());
      if (url.origin === origin) result.resource_failures.push({
        path: url.pathname, failure: request.failure()?.errorText,
        service_worker: Boolean(request.serviceWorker()),
      });
    });
    await context.addInitScript(() => {
      window.flowtraceObservedShellMessages = [];
      navigator.serviceWorker?.addEventListener('message', ({ data }) => {
        if (data?.type === 'FLOWTRACE_PREPARATION_FAILED') {
          window.flowtraceObservedShellMessages.push(data);
        }
      });
    });
    page.on('pageerror', (error) => result.page_errors.push(error.name));
    const mainResponse = page.waitForResponse((response) => new URL(response.url()).pathname === '/main.dart.js');
    await page.goto(origin, { waitUntil: 'domcontentloaded' });
    const received = await mainResponse;
    if (received.status() !== 200 || sha(await received.body()) !== expectedHash) {
      throw new Error('Actual browser main hash mismatch');
    }
    const settings = page.getByRole('button', { name: '设置', exact: true }).first();
    await settings.waitFor({ state: 'visible', timeout: 45000 });
    result.shell_at_start = await page.evaluate(() => window.FlowTraceShell?.status?.() ?? null);
    // A first-load offline status can cover the top-right mouse target. Use
    // ordinary focus/Enter and preserve that separate UI observation.
    if (navigation === 'mouse') {
      const dismiss = page.getByRole('button', {name: '收起提示', exact: true});
      if (await dismiss.isVisible()) {
        await dismiss.press('Enter');
        result.checks.push('Dismissed nonblocking shell feedback with keyboard');
      }
      await settings.click();
      result.checks.push('Normal settings mouse target is reachable');
    } else await settings.press('Enter');
    const address = page.getByRole('textbox', { name: /服务器地址/ });
    for (let i = 0; i < 25; i++) {
      if (await address.count()) break;
      await page.mouse.move(900, 650); await page.mouse.wheel(0, 450);
      await page.waitForTimeout(100);
    }
    await address.click();
    await address.fill('http://127.0.0.1:18090');
    await page.getByRole('button', { name: '保存地址', exact: true }).click();
    await page.getByText('地址已保存；已切换到对应资料空间。', { exact: true }).first().waitFor();
    result.checks.push('Normal settings saved new server and exposed confirmation');
    if (timing === 'settled') await page.waitForTimeout(5000);
    const account = page.getByRole('button', { name: '登录账号 邀请码注册、登录和会话管理', exact: true });
    for (let i = 0; i < 25; i++) {
      const box = await account.count() ? await account.boundingBox() : null;
      if (box && box.y >= 0 && box.y + box.height <= 900) break;
      await page.mouse.move(900, 350); await page.mouse.wheel(0, -450);
      await page.waitForTimeout(100);
    }
    await account.click();
    await page.getByRole('heading', { name: '账号与设备', exact: true }).waitFor();
    await page.waitForTimeout(timing === 'settled' ? 2000 : 700);
    result.shell_messages = await page.evaluate(() => window.flowtraceObservedShellMessages);
    result.shell_at_form = await page.evaluate(() => window.FlowTraceShell.status());
    await fs.writeFile(path.join(out, 'account-aria.txt'), await page.locator('body').ariaSnapshot());
    await page.screenshot({ path: path.join(out, 'account.png') });
    const username = page.getByRole('textbox', { name: /用户名/, disabled: false });
    const password = page.getByRole('textbox', { name: /^密码/, disabled: false });
    result.username_controls = await username.count();
    result.password_controls = await password.count();
    if (result.username_controls !== 1 || result.password_controls !== 1) {
      throw new Error('Account form semantics absent after normal address-save transition');
    }
    await username.click();
    await username.fill('synthetic_focus_probe');
    await page.keyboard.press('Tab');
    if (!await password.evaluate((element) => element === document.activeElement)) {
      throw new Error('Keyboard traversal did not reach password');
    }
    await username.fill('');
    result.checks.push('Enabled username/password exposed and keyboard traversal works');
    if (coldStart) {
      if (result.shell_at_form.complete !== true) throw new Error('Offline package is not ready');
      await context.close();
      context = await chromium.launchPersistentContext(profile, {
        executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
        headless: false, locale: 'zh-CN', viewport: {width:1280,height:900}, offline: true,
      });
      page = context.pages()[0];
      page.on('pageerror', error => result.page_errors.push(error.name));
      await page.goto(origin, {waitUntil:'domcontentloaded'});
      await page.getByRole('button', {name:'设置',exact:true}).first().waitFor({timeout:45000});
      result.offline_cold_shell = await page.evaluate(() => window.FlowTraceShell.status());
      if (result.offline_cold_shell.complete !== true
          || result.offline_cold_shell.releaseId !== result.shell_at_form.releaseId) {
        throw new Error('Offline cold start did not use the verified same release');
      }
      await page.screenshot({path:path.join(out,'offline-cold.png')});
      result.checks.push('Entire Chrome closed; offline cold start uses the same complete release');
    }
    result.result = 'passed';
  } catch (error) {
    result.result = 'failed';
    result.error = error.message;
    if (page) {
      await fs.writeFile(path.join(out, 'failure-aria.txt'), await page.locator('body').ariaSnapshot()).catch(() => {});
      await page.screenshot({ path: path.join(out, 'failure.png') }).catch(() => {});
    }
    process.exitCode = 1;
  } finally {
    if (context) await context.close();
    result.finished_at = new Date().toISOString();
    await fs.writeFile(path.join(out, 'receipt.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify({ result: result.result, output_directory: out,
      username_controls: result.username_controls, password_controls: result.password_controls }));
  }
}
main().catch((error) => { console.error(error.message); process.exitCode = 1; });
