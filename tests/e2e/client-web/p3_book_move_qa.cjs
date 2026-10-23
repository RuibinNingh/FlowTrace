// Dedicated local app E2E. No personal browser, token injection or DB editing.
'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../..');
const output = path.join(root, 'outputs/validation/P3');
const phase = process.argv[2] || 'inspect';
const phases = new Set(['login', 'login-inspect', 'sync-seed', 'inspect', 'inspect-target', 'move', 'sync-move', 'verify', 'verify-debug', 'logout', 'logout-reload']);
if (!phases.has(phase)) throw new Error('Unknown fixed book-move UI phase');
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const uuid = (value) => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

async function main() {
  const fixture = await read(path.join(output, 'web-book-move-fixture.json'));
  if (fixture.purpose !== 'flowtrace-p3-book-move-ui-synthetic' || fixture.state === 'cleaned') throw new Error('Requires active synthetic move fixture');
  const original = await read(path.join(output, 'web-browser-receipt.json'));
  const accounts = await read(path.join(root, 'work/flowtrace-dev/client-auth-qa.json'));
  const profile = path.resolve(original.profile);
  if (!profile.startsWith(path.resolve(root, 'work/flowtrace-dev/browser-profiles') + path.sep)
      || !path.basename(profile).startsWith('chrome-p3-ui-')) throw new Error('Refusing non-test profile');
  const receiptPath = path.join(output, `web-book-move-${phase}-receipt.json`);
  try {
    const previous = await read(receiptPath);
    const tag = previous.started_at.replace(/[^0-9TZ]/g, '');
    for (const [source, suffix] of [[`web-book-move-${phase}-receipt.json`, '.json'], [`web-book-move-${phase}-aria.txt`, '-aria.txt'], [`web-book-move-${phase}-failure.png`, '.png']]) {
      try { await fs.writeFile(path.join(output, `web-book-move-${phase}-previous-${tag}${suffix}`), await fs.readFile(path.join(output, source)), { flag: 'wx' }); }
      catch (error) { if (!['ENOENT', 'EEXIST'].includes(error.code)) throw error; }
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const result = { phase, result: 'running', started_at: new Date().toISOString(), main_js_sha256: hash(await fs.readFile(path.join(root, 'apps/flowtrace/build/web/main.dart.js'))),
    dedicated_test_profile: true, checks: [], errors: [], http: [], move_requests: [], move_responses: [] };
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
    locale: 'zh-CN', viewport: { width: 1280, height: 900 }, timeout: 15000,
  });
  result.browser_version = context.browser().version();
  result.node_pid = process.pid;
  const page = context.pages()[0];
  page.setDefaultTimeout(8000);
  let step = 'open-normal-main';
  let debuggerSession;
  const pending = [];
  const safe = (value) => {
    for (const account of accounts) for (const key of ['username', 'password', 'invite_token']) {
      if (account[key]) value = value.split(account[key]).join(`[redacted-${key}]`);
    }
    return value;
  };
  const aria = async () => safe(await page.locator('body').ariaSnapshot());
  const click = async (name, role = 'button') => {
    step = 'click-' + (name.includes(accounts[0].username) ? 'account' : name);
    await page.getByRole(role, { name, exact: true, disabled: false }).click();
  };
  const terms = async (label, expected, timeout = 10000) => {
    step = 'check-' + label;
    const end = Date.now() + timeout;
    do {
      const current = (await aria()).replace(/\s+/g, ' ');
      if (expected.every((value) => current.includes(value))) { result.checks.push(label); return; }
      await page.waitForTimeout(100);
    } while (Date.now() < end);
    throw new Error('Accessible UI does not match fixed expectations');
  };
  const shot = async (label) => {
    if (!phase.startsWith('login')) await page.screenshot({ path: path.join(output, `web-book-move-${label}.png`) });
  };
  const selectBook = async (label) => {
    await click('打开导航菜单');
    await click(fixture.names[label]);
    await page.getByRole('button', { name: '搜索账单', exact: true }).waitFor({ state: 'visible' });
  };
  const dropdown = async (label, option) => {
    step = 'select-' + label;
    await page.getByRole('button', { name: new RegExp('^' + escape(label) + '( |$)'), disabled: false }).click();
    await click(option, 'menuitem');
  };
  const accountBalance = async (label) => {
    await click('打开导航菜单');
    await click('资金账户');
    step = 'account-row-exact-balance';
    await page.getByRole('button', { name: new RegExp('^' + escape(fixture.names.account) + ' .*CNY 98\\.75$') }).waitFor({ state: 'visible' });
    result.checks.push(label + ': own private account98.75');
    await shot(label);
    await click('返回');
  };
  const synchronize = async () => {
    await click('查看');
    await click('立即同步');
    await terms('Real UI sync finished', ['已与服务器同步。'], 20000);
    await page.getByRole('button', { name: '立即同步', exact: true, disabled: false }).waitFor({ state: 'visible', timeout: 15000 });
    await shot(phase + '-sync');
  };
  page.on('pageerror', (error) => result.errors.push({ category: 'pageerror', name: error.name }));
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) result.errors.push({ category: /RenderFlex|overflow/.test(message.text()) ? 'layout' : 'console', type: message.type() });
  });
  page.on('request', (request) => {
    if (request.url() !== 'http://127.0.0.1:18080/api/v1/sync/push' || request.method() !== 'POST') return;
    try {
      const body = request.postData(), value = JSON.parse(body);
      for (const operation of value.operations || []) {
        if (operation.entity_id !== fixture.ids.bill || operation.move == null) continue;
        if (!uuid(operation.operation_id) || !uuid(operation.scope_id) || !uuid(operation.move.target_scope_id)) throw new Error('Invalid safe marker');
        const replacements = operation.move.attachment_replacements;
        if (!Array.isArray(replacements) || replacements.length !== 1 || replacements.some((row) => !uuid(row.source_id) || !uuid(row.target_id))) throw new Error('Invalid safe image marker');
        result.move_requests.push({ operation_id: operation.operation_id, entity_id: operation.entity_id, scope_id: operation.scope_id,
          move: { target_scope_id: operation.move.target_scope_id, attachment_replacements: replacements.map(({ source_id, target_id }) => ({ source_id, target_id })) }, wire_sha256: hash(body) });
      }
    } catch (_) { result.errors.push({ category: 'move_marker_parse' }); }
  });
  page.on('response', (response) => {
    const url = new URL(response.url());
    if (url.origin !== 'http://127.0.0.1:18080') return;
    const category = url.pathname.startsWith('/api/v1/attachments/') ? 'attachments'
      : url.pathname.startsWith('/api/v1/sync/') ? 'sync' : url.pathname.startsWith('/api/v1/auth/') ? 'identity' : 'other';
    if (result.http.length < 150) result.http.push({ category, method: response.request().method(), status: response.status() });
    if (url.pathname !== '/api/v1/sync/push' || response.status() !== 200) return;
    pending.push((async () => {
      const body = await response.json();
      for (const row of body.results || []) {
        if (!result.move_requests.some((sent) => sent.operation_id === row.operation_id)) continue;
        if (!uuid(row.operation_id) || row.status !== 'applied' || !uuid(row.commit_id) || !/^[0-9]+$/.test(row.revision)) throw new Error('Invalid safe receipt');
        result.move_responses.push({ operation_id: row.operation_id, status: row.status, entity_id: row.entity_id,
          revision: row.revision, commit_id: row.commit_id, replayed: row.replayed });
      }
    })().catch(() => result.errors.push({ category: 'move_receipt_parse' })));
  });
  try {
    const servedMain = page.waitForResponse((response) => new URL(response.url()).pathname === '/main.dart.js', { timeout: 15000 });
    await page.goto('http://127.0.0.1:18181/', { waitUntil: 'domcontentloaded', timeout: 15000 });
    const main = await servedMain;
    if (main.status() !== 200 || hash(await main.body()) !== result.main_js_sha256) throw new Error('Wrong fixed artifact');
    await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 15000 });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    result.checks.push('Actual browser received fixed normal main');

    if (phase === 'login-inspect') {
      await click('设置');
      await click('登录账号 邀请码注册、登录和会话管理');
      await page.waitForTimeout(1500);
      // Labels only, never input values or a login screenshot.
      result.form_labels = await page.getByRole('textbox').evaluateAll((nodes) => nodes.map((node) => ({ tag: node.tagName, label: node.getAttribute('aria-label') })));
      result.username_exact_count = await page.getByRole('textbox', { name: '用户名', exact: true }).count();
      result.password_exact_count = await page.getByRole('textbox', { name: '密码', exact: true }).count();
      result.visible_form_controls = await page.getByRole('textbox').evaluateAll((nodes) => nodes.map((node) => ({ label: node.getAttribute('aria-label'), rect: { width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height }, blank: node.value === '' })));
      result.heading_labels = await page.getByRole('heading').allTextContents();
      result.button_labels = await page.getByRole('button').allTextContents();
    } else if (phase === 'login') {
      await click('设置');
      await click('登录账号 邀请码注册、登录和会话管理');
      step = 'fill-real-username';
      const username = page.getByRole('textbox', { name: '用户名', exact: true });
      await username.click();
      await username.fill(accounts[0].username);
      step = 'fill-real-password';
      const password = page.getByRole('textbox', { name: '密码', exact: true });
      await password.click();
      await password.fill(accounts[0].password);
      await click('登录');
      await terms('Real UI login connected', ['已连接 · 此账号资料独立保存'], 15000);
    } else if (phase === 'logout-reload') {
      await page.getByRole('button', { name: '登录', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
      await click('设置');
      await click('登录账号 邀请码注册、登录和会话管理');
      await page.getByRole('textbox', { name: '用户名', exact: true, disabled: false }).waitFor({ state: 'visible' });
      if (await page.getByRole('button', { name: '退出登录', exact: true }).count()) throw new Error('Old account controls returned');
      result.checks.push('Dedicated Chrome reopen stays logged out');
      await shot('logout-reload');
    } else {
      await page.getByRole('button', { name: '打开导航菜单', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
      if (phase === 'sync-seed') {
        await synchronize();
      } else if (phase === 'logout') {
        await click('设置');
        await click(accounts[0].username + ' 账号、可访问账本与登录设备');
        await click('退出登录');
        await click('确认');
        await terms('Real UI logout acknowledged', ['已退出并撤销此设备会话。']);
        await shot('logout');
        result.known_semantics_issue = await page.getByRole('textbox', { name: '用户名', exact: true }).count() === 0;
        if (result.known_semantics_issue) {
          step = 'immediate-logout-accessibility';
          throw new Error('Visible login fields missing from immediate semantics');
        }
      } else {
        await selectBook('source');
        if (phase === 'inspect' || phase === 'inspect-target' || phase === 'move') {
          await accountBalance('balance-before');
          await click('搜索账单');
          await page.getByRole('textbox', { name: '备注、分类、标签或金额', exact: true }).fill(fixture.names.bill_note);
          await terms('Only one source bill selected', ['1笔匹配', '名义金额合计 1.25']);
          await page.getByRole('button', { name: new RegExp(escape(fixture.names.bill_note)) }).click({ delay: 1200 });
          await click('移动到账本');
          await page.getByRole('heading', { name: '移动到账本', exact: true }).waitFor({ state: 'visible' });
          await shot('mapping-initial');
          if (phase === 'inspect-target') await click('目标账本');
          if (phase === 'move') {
            if (await page.getByRole('button', { name: '核对移动方案', exact: true, disabled: true }).count() !== 1) throw new Error('Mapping was silently preselected');
            await dropdown('目标账本', fixture.names.target);
            await dropdown('目标分类', fixture.names.target_category);
            await dropdown('目标标签', '选择目标标签');
            await click('选择目标账本标签');
            await click(fixture.names.target_tag, 'checkbox');
            await click('使用所选标签');
            if (await page.getByRole('button', { name: /^目标手续费分类/ }).count()) throw new Error('Expense unexpectedly exposes fee mapping');
            await click('核对移动方案');
            await terms('Explicit preview with one bill and one image clone', ['核对结果：1笔 · 1张图片副本', fixture.names.target_category, fixture.names.target_tag]);
            await shot('preview');
            await click('准备图片并复核账单');
            await page.getByRole('button', { name: '确认移动到本机并待同步', exact: true, disabled: false }).waitFor({ state: 'visible', timeout: 20000 });
            await terms('Original image prepared and checked', ['图片和账单已核对，可重新复核']);
            await shot('prepared');
            await click('确认移动到本机并待同步');
            await page.getByRole('heading', { name: '搜索账单', exact: true }).waitFor({ state: 'visible' });
            await terms('Local source search no longer contains selected bill', ['0笔匹配']);
            result.queued_to_local = true;
            await shot('source-empty-pending');
            await click('返回');
            await accountBalance('balance-pending-move');
            result.checks.push('Local confirmation moves only selected bill, balance remains98.75 before sync');
          }
        } else if (phase === 'sync-move') {
          await synchronize();
          await Promise.allSettled(pending);
          if (result.move_requests.length === 0 || result.move_responses.length === 0) throw new Error('UI did not push an applied move marker');
          result.checks.push('Real UI sends frozen move marker and receives applied receipt');
        } else if (phase === 'verify' || phase === 'verify-debug') {
          await terms('Source no longer contains the bill', ['0项待同步 · 0笔记录']);
          await shot('source-empty-after-sync');
          await selectBook('target');
          await terms('Target contains exactly one moved bill', ['0项待同步 · 1笔记录', fixture.names.bill_note, '月支出 CNY 1.25']);
          await accountBalance('balance-after');
          await click('搜索账单');
          await page.getByRole('textbox', { name: '备注、分类、标签或金额', exact: true }).fill(fixture.names.bill_note);
          await terms('Target exact one result', ['1笔匹配', '名义金额合计 1.25']);
          await page.getByRole('button', { name: new RegExp(escape(fixture.names.bill_note)) }).click();
          await terms('Explicit target mapping and historical time displayed', [fixture.names.target_category, fixture.names.target_tag,
            '2026-10-21 · Asia/Shanghai', '2026-10-21T05:06:07.123456Z', '图片附件']);
          await shot('target-detail');
          if (phase === 'verify-debug') {
            result.caught_exceptions = [];
            debuggerSession = await context.newCDPSession(page);
            await debuggerSession.send('Debugger.enable');
            debuggerSession.on('Debugger.paused', async (event) => {
              const firstLine = event.data?.description?.split('\n')[0] || '';
              const className = event.data?.className;
              result.caught_exceptions.push({
                class_name: typeof className === 'string' && /^[A-Za-z_$][A-Za-z0-9_$]{0,79}$/.test(className) ? className : 'unknown',
                message_category: /Unimplemented|not implemented/.test(firstLine) ? 'unimplemented'
                  : /Unsupported|not supported/.test(firstLine) ? 'unsupported'
                  : /decode|Codec|ImageDescriptor|ImageDecoder/.test(firstLine) ? 'image_codec' : 'other',
                frames: event.callFrames.slice(0, 8).map((frame) => ({
                  script_id: frame.location.scriptId, line: frame.location.lineNumber + 1, column: frame.location.columnNumber + 1,
                  function_name: /^[A-Za-z0-9_$]{0,80}$/.test(frame.functionName) ? frame.functionName : 'other',
                })),
              });
              try {
                if (result.caught_exceptions.length >= 20) await debuggerSession.send('Debugger.setPauseOnExceptions', { state: 'none' });
                await debuggerSession.send('Debugger.resume');
              } catch (_) {}
            });
            await debuggerSession.send('Debugger.setPauseOnExceptions', { state: 'all' });
          }
          await click('预览图片1');
          await page.getByRole('heading', { name: '图片预览', exact: true }).waitFor({ state: 'visible' });
          await page.getByRole('img').waitFor({ state: 'visible', timeout: 15000 });
          await shot('target-original-image');
          result.checks.push('Target original image really rendered through preview UI');
        }
      }
    }
    if (result.errors.some((error) => ['pageerror', 'layout', 'move_marker_parse', 'move_receipt_parse'].includes(error.category))) throw new Error('Browser runtime/layout or marker failure');
    result.result = 'passed';
  } catch (error) {
    result.result = 'failed';
    result.failed_step = step;
    result.error_class = error.name;
    result.error_category = /strict mode/.test(error.message) ? 'ambiguous_semantics' : /Timeout/.test(error.message) ? 'ui_timeout' : 'assertion_or_runtime';
    await shot(phase + '-failure').catch(() => {});
    process.exitCode = 1;
  } finally {
    if (debuggerSession) {
      try { await debuggerSession.send('Debugger.setPauseOnExceptions', { state: 'none' }); await debuggerSession.detach(); } catch (_) {}
    }
    await Promise.allSettled(pending);
    if (!phase.startsWith('login')) {
      try { const tree = await aria(); await fs.writeFile(path.join(output, `web-book-move-${phase}-aria.txt`), tree); console.log(tree.slice(-9000)); } catch (_) {}
    }
    await context.close();
    result.closed_at = new Date().toISOString();
    await fs.writeFile(receiptPath, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  }
}
main().catch(() => { console.error('Dedicated move UI setup failed; no credentials logged'); process.exitCode = 1; });
