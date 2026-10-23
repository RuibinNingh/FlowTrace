// Local app E2E only. Reuses the dedicated profile created for this synthetic
// run, never a personal Chrome profile. Each phase uses normal visible UI.
'use strict';

const fs = require('node:fs/promises');
const { createHash } = require('node:crypto');
const path = require('node:path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../..');
const output = path.join(root, 'outputs/validation/P3');
const phase = process.argv[2] || 'inspect';
const allowed = new Set(['inspect', 'reports', 'reports-narrow', 'reports-after-entry', 'budget-inspect', 'budget-create', 'budget-edit', 'budget-copy', 'calendar', 'calendar-save', 'search-export', 'search-export-debug', 'sync', 'logout', 'logout-reload']);
if (!allowed.has(phase)) throw new Error('Unknown fixed UI phase');

async function readJson(file) {
  return JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
}

async function main() {
  const fixture = await readJson(path.join(output, 'web-fixture.json'));
  const receipt = await readJson(path.join(output, 'web-browser-receipt.json'));
  const accounts = await readJson(path.join(root, 'work/flowtrace-dev/client-auth-qa.json'));
  try {
    const previous = await readJson(path.join(output, `web-p3-${phase}-receipt.json`));
    if (previous.result === 'failed') {
      const tag = previous.started_at.replace(/[^0-9TZ]/g, '');
      for (const [source, suffix] of [[`web-p3-${phase}-receipt.json`, '.json'], [`web-p3-${phase}-aria.txt`, '-aria.txt'], [`web-p3-${phase}-failure.png`, '.png']]) {
        try {
          const bytes = await fs.readFile(path.join(output, source));
          await fs.writeFile(path.join(output, `web-p3-${phase}-previous-failure-${tag}${suffix}`), bytes, { flag: 'wx' });
        } catch (error) {
          if (!['ENOENT', 'EEXIST'].includes(error.code)) throw error;
        }
      }
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const profile = path.resolve(receipt.profile);
  const expected = path.resolve(root, 'work/flowtrace-dev/browser-profiles') + path.sep;
  if (!profile.startsWith(expected) || !path.basename(profile).startsWith('chrome-p3-ui-')) {
    throw new Error('Refusing non-test profile');
  }
  const artifactHash = createHash('sha256').update(await fs.readFile(path.join(root, 'apps/flowtrace/build/web/main.dart.js'))).digest('hex');
  const result = { phase, result: 'running', started_at: new Date().toISOString(), checks: [], errors: [], http: [], main_js_sha256: artifactHash };
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, locale: 'zh-CN', viewport: phase === 'reports-narrow' ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    acceptDownloads: true, timeout: 15000,
  });
  const page = context.pages()[0];
  result.browser_version = context.browser().version();
  result.node_pid = process.pid;
  result.dedicated_test_profile = true;
  page.setDefaultTimeout(8000);
  page.on('pageerror', (error) => result.errors.push({ type: 'pageerror', name: error.name }));
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) {
      result.errors.push({ type: message.type(), category: /RenderFlex|overflow/i.test(message.text()) ? 'layout' : 'other' });
    }
  });
  page.on('response', (response) => {
    const url = new URL(response.url());
    if (url.origin !== 'http://127.0.0.1:18080') return;
    const category = url.pathname === '/api/v1/sync/scopes' ? 'sync_scopes'
      : /^\/api\/v1\/attachments\/[^/]+\/content$/.test(url.pathname) ? 'attachment_content'
      : /^\/api\/v1\/attachments\/[^/]+$/.test(url.pathname) ? 'attachment_metadata'
      : url.pathname.startsWith('/api/v1/sync/') ? 'sync_other'
      : url.pathname.startsWith('/api/v1/auth/') ? 'identity' : 'other';
    // Fixed categories, method and status only; no URL, headers or bodies.
    if (result.http.length < 100) result.http.push({ category, method: response.request().method(), status: response.status() });
  });
  let step = 'open-app';
  let debuggerSession;
  const sanitize = (value) => {
    let safe = value;
    for (const account of accounts) for (const key of ['username', 'password', 'invite_token']) {
      if (account[key]) safe = safe.split(account[key]).join(`[redacted-${key}]`);
    }
    return safe;
  };
  const aria = async () => sanitize(await page.locator('body').ariaSnapshot());
  const click = async (name, role = 'button') => {
    step = `click-${name}`;
    await page.getByRole(role, { name, exact: true, disabled: false }).click();
  };
  const checkAriaTerms = async (label, terms) => {
    step = `check-${label}`;
    const deadline = Date.now() + 8000;
    do {
      const current = (await aria()).replace(/\s+/g, ' ');
      if (terms.every((term) => current.includes(term))) {
        result.checks.push(label);
        return;
      }
      await page.waitForTimeout(100);
    } while (Date.now() < deadline);
    throw new Error('Visible accessible values did not match fixed expectations');
  };
  try {
    const incomingMain = page.waitForResponse((response) => new URL(response.url()).pathname === '/main.dart.js', { timeout: 15000 });
    await page.goto('http://127.0.0.1:18181/', { waitUntil: 'domcontentloaded', timeout: 15000 });
    const deliveredMain = await incomingMain;
    const deliveredHash = createHash('sha256').update(await deliveredMain.body()).digest('hex');
    if (deliveredMain.status() !== 200 || deliveredHash !== artifactHash) throw new Error('Served artifact differs from fixed build');
    result.checks.push('Real browser received fixed normal-main artifact');
    await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 15000 });
    await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    await page.getByRole('button', { name: phase === 'logout-reload' ? '登录' : '打开导航菜单', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
    if (phase !== 'logout-reload') {
      step = 'select-fixture-book';
      await click('打开导航菜单');
      await click(fixture.book_name);
      await page.getByRole('button', { name: '统计、日历与预算', exact: true, disabled: false }).waitFor({ state: 'visible' });
      result.checks.push('Persisted Web session and fixture book selected through UI');
    }

    if (phase === 'inspect') {
      await page.screenshot({ path: path.join(output, 'web-p3-home.png') });
    } else if (phase === 'reports' || phase === 'reports-narrow' || phase === 'reports-after-entry') {
      await click('统计、日历与预算');
      step = 'check-period-boundary';
      await page.getByRole('group', { name: '2026-09-30 至 2026-10-30', exact: true }).waitFor({ state: 'visible' });
      result.checks.push('31-day period boundary');
      step = 'check-exact-metrics';
      // Flutter merges these visible Text widgets into their section's
      // accessible group. Check that real group, not a synthetic test API.
      const updated = phase === 'reports-after-entry';
      await page.getByRole('group', { name: updated ? /^期间概览 · CNY 收入 100\.00 支出 14\.75 结余 85\.25 / : /^期间概览 · CNY 收入 100\.00 支出 13\.50 结余 86\.50 / }).waitFor({ state: 'visible' });
      result.checks.push(updated ? 'Exact income100.00 expense14.75 net85.25 after UI entry' : 'Exact income100.00 expense13.50 net86.50');
      const suffix = updated ? '-after-entry' : phase === 'reports-narrow' ? '-narrow' : '';
      await page.screenshot({ path: path.join(output, `web-p3-statistics${suffix}.png`) });
      await click('全屏趋势');
      await click('折线图', 'radio');
      await page.screenshot({ path: path.join(output, `web-p3-line-fullscreen${suffix}.png`) });
      result.checks.push('Fullscreen line chart opened through UI');
      if (updated) {
        await click('返回');
        await click('预算', 'radio');
        await checkAriaTerms('Budget changed only by included new bill', ['限额 100.01', '已用 25.00 · 剩余 75.01']);
        await page.screenshot({ path: path.join(output, 'web-p3-budget-after-entry.png') });
      }
    } else if (phase === 'budget-inspect') {
      await click('统计、日历与预算');
      await click('预算', 'radio');
      await page.screenshot({ path: path.join(output, 'web-p3-budget-inspect.png') });
      result.checks.push('Budget read-only reload inspected; no new mutation');
    } else if (['budget-create', 'budget-edit', 'budget-copy'].includes(phase)) {
      await click('统计、日历与预算');
      await click('预算', 'radio');
      if (phase === 'budget-create') {
        await click('设置本期预算');
      } else if (phase === 'budget-edit') {
        await click('编辑预算');
      } else {
        await click('下一期');
        await click('沿用上期金额与分类');
      }
      step = 'budget-exact-amount-input';
      const field = page.getByRole('textbox', { name: '总预算 (CNY)', exact: true });
      // Flutter populates the native editing element when it receives focus.
      // Read that real control only after the same click a user performs.
      await field.click();
      if (phase === 'budget-copy') {
        if (await field.inputValue() !== '100.01') throw new Error('Previous limit was not copied exactly');
        result.checks.push('Previous budget100.01 prefilled through UI');
      } else {
        if (phase === 'budget-edit' && await field.inputValue() !== '100.00') {
          throw new Error('Existing limit was not retained exactly');
        }
        await field.fill(phase === 'budget-create' ? '100.00' : '100.01');
      }
      await click('保存到本机并待同步');
      step = 'budget-return-to-report';
      await page.getByRole('heading', { name: '统计、日历与预算', exact: true }).waitFor({ state: 'visible' });
      await page.getByRole('button', { name: '编辑预算', exact: true, disabled: false }).waitFor({ state: 'visible' });
      const values = {
        'budget-create': ['限额 100.00', '已用 23.75 · 剩余 76.25'],
        'budget-edit': ['限额 100.01', '已用 23.75 · 剩余 76.26'],
        'budget-copy': ['2026-10-31 至 2026-11-29', '限额 100.01', '已用 2.00 · 剩余 98.01'],
      };
      await checkAriaTerms('Exact budget limit/spent/remaining', values[phase]);
      await page.screenshot({ path: path.join(output, `web-p3-${phase}.png`) });
      result.checks.push('Budget saved through normal editor; exact visible values recorded');
    } else if (phase === 'calendar' || phase === 'calendar-save') {
      await click('统计、日历与预算');
      await click('日历', 'radio');
      await click('下一个日历月');
      await click('15 +0.00 −0.00');
      await page.screenshot({ path: path.join(output, 'web-p3-calendar.png') });
      await click('查看当天流水');
      step = 'calendar-day-original-bill';
      await page.getByRole('button', { name: new RegExp('预算样本-' + fixture.run_id.slice(0, 8)) }).waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-calendar-day-search.png') });
      result.checks.push('Selected October15 opens correct original bill, although excluded from statistics');
      await click('返回');
      await click('16');
      await click('补记一笔');
      step = 'calendar-new-entry-date';
      await page.getByRole('checkbox', { name: '2026-10-16', exact: true }).waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-calendar-entry-date.png') });
      result.checks.push('Calendar October16 opens entry with exact selected business day');
      if (phase === 'calendar-save') {
        const marker = fixture.run_id.slice(0, 8);
        await click('FT餐饮-' + marker);
        await click('FT咖啡-' + marker);
        step = 'calendar-enter-unique-note';
        await page.getByRole('textbox', { name: '备注', exact: true }).fill('UI补记-' + marker);
        for (const key of ['1', '.', '2', '5']) await click(key);
        await click('保存');
        step = 'calendar-return-after-local-save';
        await page.getByRole('heading', { name: '统计、日历与预算', exact: true }).waitFor({ state: 'visible' });
        await checkAriaTerms('Calendar October16 exact saved total', ['收入 0.00 · 支出 1.25 · 结余 -1.25']);
        await page.screenshot({ path: path.join(output, 'web-p3-calendar-saved.png') });
        await click('查看当天流水');
        await page.getByRole('button', { name: new RegExp('UI补记-' + marker) }).waitFor({ state: 'visible' });
        if (await page.getByRole('button', { name: new RegExp('UI补记-' + marker) }).count() !== 1) throw new Error('New daily entry is not unique');
        await page.screenshot({ path: path.join(output, 'web-p3-calendar-saved-search.png') });
        result.checks.push('Real calendar entry saved once at October16 and appears in original daily flow');
      } else {
        result.not_run = ['This phase checks calendar navigation without saving a new bill'];
      }
    } else if (phase === 'search-export' || phase === 'search-export-debug') {
      await click('搜索账单');
      step = 'search-unique-picture-bill';
      await page.getByRole('textbox', { name: '备注、分类、标签或金额', exact: true }).fill(fixture.expected.picture_search_keyword);
      const item = page.getByRole('button', { name: new RegExp(fixture.expected.picture_search_keyword) });
      await item.waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-picture-search.png') });
      result.checks.push('Keyword search shows synthetic picture bill');
      step = 'select-picture-bill-by-long-press';
      // Installed Flutter engine queues semantics pointerdown for 200ms.
      // Hold longer than that plus the framework's 500ms long-press threshold.
      await item.click({ delay: 1200 });
      await click('导出图片');
      step = 'image-export-preview';
      await page.getByRole('button', { name: '选择位置并导出ZIP', exact: true, disabled: false }).waitFor({ state: 'visible' });
      await checkAriaTerms('Exact selected bill/image preview', ['1 笔账单 · 1 张图片']);
      await page.screenshot({ path: path.join(output, 'web-p3-image-export-preview.png') });
      result.checks.push('Selected image preview is exportable');
      if (phase === 'search-export-debug') {
        result.caught_exceptions = [];
        debuggerSession = await context.newCDPSession(page);
        await debuggerSession.send('Debugger.enable');
        debuggerSession.on('Debugger.paused', async (event) => {
          const description = event.data?.description?.split('\n')[0] || '';
          // Do not fetch exception properties, locals, scopes, URLs or bodies.
          // Persist a bounded static category instead of arbitrary messages.
          const category = /getSaveLocation|getSavePath|FileSaveLocation/.test(description) ? 'save_location'
            : /Unsupported|not supported|not implemented|Unimplemented/.test(description) ? 'unsupported'
            : /FormatException/.test(description) ? 'format'
            : /TypeError/.test(description) ? 'type'
            : /StateError/.test(description) ? 'state' : 'other';
          const className = event.data?.className;
          result.caught_exceptions.push({
            class_name: typeof className === 'string' && /^[A-Za-z_$][A-Za-z0-9_$]{0,79}$/.test(className) ? className : 'unknown',
            category,
            frames: event.callFrames.slice(0, 8).map((frame) => ({
              script_id: frame.location.scriptId,
              line: frame.location.lineNumber + 1,
              column: frame.location.columnNumber + 1,
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
      step = 'download-original-images-zip';
      const incoming = page.waitForEvent('download', { timeout: 15000 });
      await click('选择位置并导出ZIP');
      const download = await incoming;
      await download.saveAs(path.join(output, 'p3-browser-images.zip'));
      if (await download.failure()) throw new Error('Browser download failed');
      await checkAriaTerms('UI confirms the real browser download', ['已开始下载 1 张原图，请查看浏览器下载。']);
      await page.getByRole('button', { name: '选择位置并导出ZIP', exact: true, disabled: false }).waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-image-export-download.png') });
      result.checks.push('Real browser ZIP download saved for byte verification');
    } else if (phase === 'sync') {
      await click('查看');
      await click('立即同步');
      await checkAriaTerms('Real UI sync completed', ['已与服务器同步。']);
      await page.getByRole('button', { name: '立即同步', exact: true, disabled: false }).waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-sync-complete.png') });
    } else if (phase === 'logout-reload') {
      await click('设置');
      await click('登录账号 邀请码注册、登录和会话管理');
      step = 'fresh-load-signed-out-controls';
      await page.getByRole('textbox', { name: '用户名', exact: true, disabled: false }).waitFor({ state: 'visible' });
      await page.getByRole('textbox', { name: '密码', exact: true, disabled: false }).waitFor({ state: 'visible' });
      if (await page.getByRole('button', { name: '退出登录', exact: true }).count() !== 0) throw new Error('Signed-in controls returned after logout reload');
      await page.screenshot({ path: path.join(output, 'web-p3-logout-reload.png') });
      result.checks.push('Reopened dedicated Chrome stays signed out, with actual enabled login fields and no account controls');
    } else if (phase === 'logout') {
      await click('设置');
      await click(accounts[0].username + ' 账号、可访问账本与登录设备');
      await click('退出登录');
      await click('确认');
      step = 'logged-out-form-visible';
      await page.getByRole('textbox', { name: '用户名', exact: true, disabled: false }).waitFor({ state: 'visible' });
      await page.screenshot({ path: path.join(output, 'web-p3-logout.png') });
      result.checks.push('Explicit UI logout returns to enabled login form');
      await page.reload({ waitUntil: 'domcontentloaded' });
      await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 15000 });
      await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
      await page.getByRole('button', { name: '设置', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
      await click('设置');
      await click('登录账号 邀请码注册、登录和会话管理');
      await page.getByRole('textbox', { name: '用户名', exact: true, disabled: false }).waitFor({ state: 'visible' });
      if (await page.getByRole('button', { name: '退出登录', exact: true }).count() !== 0) throw new Error('Signed-in UI returned after logout reload');
      await page.screenshot({ path: path.join(output, 'web-p3-logout-reload.png') });
      result.checks.push('Reload keeps signed-out state without old account controls');
    } else {
      throw new Error('UI phase not implemented before observing controls');
    }
    if (result.errors.some((error) => error.type === 'pageerror' || error.category === 'layout')) {
      throw new Error('Real browser runtime or layout error');
    }
    result.result = 'passed';
  } catch (error) {
    result.result = 'failed';
    result.failed_step = step;
    result.error_class = error.name;
    // Playwright call logs can contain typed values; never persist raw errors.
    result.error_category = /strict mode/.test(error.message) ? 'ambiguous_semantics' : /Timeout/.test(error.message) ? 'ui_timeout' : 'assertion_or_runtime';
    try { await page.screenshot({ path: path.join(output, `web-p3-${phase}-failure.png`) }); } catch (_) {}
    process.exitCode = 1;
  } finally {
    if (debuggerSession) {
      try { await debuggerSession.send('Debugger.setPauseOnExceptions', { state: 'none' }); await debuggerSession.detach(); } catch (_) {}
    }
    try {
      const tree = await aria();
      await fs.writeFile(path.join(output, `web-p3-${phase}-aria.txt`), tree);
      console.log(tree.slice(-9000));
    } catch (_) {}
    await context.close();
    result.closed_at = new Date().toISOString();
    await fs.writeFile(path.join(output, `web-p3-${phase}-receipt.json`), JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
  }
}

main().catch(() => {
  console.error('Browser fixture setup failed; no credentials logged');
  process.exitCode = 1;
});
