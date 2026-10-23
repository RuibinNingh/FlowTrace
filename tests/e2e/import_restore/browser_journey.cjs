// Normal main, visible UI and an isolated installed Chrome profile only.
// Network observation records synthetic operation receipts, never credentials.
'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../..');
const phases = new Set(['login', 'login-inspect', 'inspect', 'native-preview', 'native-apply', 'offline-prepared', 'offline',
  'csv-preview', 'csv-apply', 'csv-repeat', 'export-json', 'export-xlsx', 'csv-undo', 'csv-undo-readback', 'online-image',
  'history', 'logout', 'remote-refresh']);
const phase = process.argv[2];
const fixturePath = process.argv[3];
const build = path.resolve(process.argv[4] || '');
const expectedMain = process.argv[5] || '40db38642e86bf075386b14aa138b2e60488c6bf4925e758da079b8fe0eccac6';
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const inside = (folder, file) => path.resolve(file).startsWith(path.resolve(folder) + path.sep);

async function main() {
  if (!phases.has(phase)) throw new Error('Unknown fixed browser phase');
  if (!/^[a-f0-9]{64}$/.test(expectedMain)) throw new Error('Explicit fixed build hash required');
  const fixture = await read(fixturePath);
  if (fixture.purpose !== 'flowtrace-data-tools-normal-browser-synthetic'
      || !inside(path.join(root, 'work/flowtrace-dev/browser-profiles'), fixture.profile_directory)
      || !/^chrome-data-tools-[0-9a-f]{32}$/.test(path.basename(fixture.profile_directory))
      || !inside(path.join(root, 'work/p5/browser'), fixture.credentials_file)
      || !inside(path.join(root, 'apps/flowtrace/build'), build)) throw new Error('Invalid isolated fixture');
  if (sha(await fs.readFile(path.join(build, 'main.dart.js'))) !== expectedMain) throw new Error('Wrong fixed build');
  const credentials = await read(fixture.credentials_file);
  const out = fixture.output_directory;
  const stamp = new Date().toISOString().replace(/[^0-9TZ]/g, '');
  const stem = `browser-${phase}-${stamp}`;
  const result = { run_id: fixture.run_id, phase, started_at: new Date().toISOString(), result: 'running',
    normal_main_sha256: expectedMain, profile: fixture.profile_directory, browser_surface: 'dedicated-headful-installed-Chrome',
    checks: [], http: [], operations: [], errors: [] };
  let context, page, sensitive = false, step = 'launch';
  const pending = [];
  const sanitize = (text) => {
    for (const value of Object.values(credentials)) if (typeof value === 'string') text = text.split(value).join('[redacted]');
    return text;
  };
  try {
    context = await chromium.launchPersistentContext(fixture.profile_directory, {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
      locale: 'zh-CN', viewport: { width: 1280, height: 900 }, acceptDownloads: true, timeout: 20000,
    });
    result.browser_version = context.browser().version();
    page = context.pages()[0]; page.setDefaultTimeout(12000);
    page.on('pageerror', (error) => result.errors.push({ type: 'pageerror', name: error.name }));
    page.on('console', (message) => {
      if (message.type() === 'error' && /overflow|RenderFlex/i.test(message.text())) result.errors.push({ type: 'layout' });
    });
    page.on('response', (response) => {
      const url = new URL(response.url());
      if (url.origin !== fixture.api_origin) return;
      const method = response.request().method();
      const category = url.pathname.startsWith('/api/v1/data-tools/') ? url.pathname.slice('/api/v1/data-tools/'.length)
        : url.pathname.startsWith('/api/v1/attachments') ? 'attachments'
        : url.pathname.startsWith('/api/v1/sync/') ? 'sync' : 'identity-or-other';
      result.http.push({ category, method, status: response.status(),
        ...(url.searchParams.has('batch_id') ? { filtered_batch_id: url.searchParams.get('batch_id') } : {}) });
      if (method === 'GET' && response.status() === 200 && /^\/api\/v1\/attachments\/[^/]+$/.test(url.pathname)) {
        pending.push((async () => {
          const metadata = await response.json();
          result.attachment_reads ??= [];
          result.attachment_reads.push({ attachment_id: metadata.attachment_id, scope_id: metadata.scope_id,
            sha256: metadata.sha256, size_bytes: metadata.size_bytes, status: metadata.status });
        })());
      }
      if (method === 'POST' && /^\/api\/v1\/data-tools\/imports\/(preview|apply|[^/]+\/undo)$/.test(url.pathname)) {
        pending.push((async () => {
          const body = response.request().postData() || '';
          const receipt = await response.json();
          result.operations.push({ category, status: response.status(), request_sha256: sha(Buffer.from(body)), receipt });
        })());
      }
    });
    if (phase.startsWith('offline')) await context.setOffline(true);
    step = 'open-normal-main';
    const mainResponse = page.waitForResponse((r) => new URL(r.url()).pathname === '/main.dart.js', { timeout: 30000 });
    await page.goto(fixture.web_origin + '/', { waitUntil: 'domcontentloaded', timeout: 30000 });
    const delivered = await mainResponse;
    if (delivered.status() !== 200 || sha(await delivered.body()) !== expectedMain) throw new Error('Delivered main differs from fixed candidate');
    result.checks.push('Fixed ordinary main received by actual Chrome');
    await page.getByRole('button', { name: '设置', exact: true }).first().waitFor({ state: 'visible', timeout: 45000 });
    const aria = async () => sanitize(await page.locator('body').ariaSnapshot());
    const terms = async (label, values, timeout = 20000) => {
      step = label; const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const current = (await aria()).replace(/\s+/g, ' ');
        if (values.every((value) => current.includes(value))) { result.checks.push(label); return; }
        await page.waitForTimeout(150);
      }
      throw new Error('Expected visible synthetic values absent');
    };
    const expose = async (control) => {
      for (let attempt = 0; attempt < 38; attempt++) {
        const box = await control.count() === 1 ? await control.boundingBox() : null;
        if (box && box.y >= 0 && box.y + box.height <= 900) return;
        const direction = box ? (box.y < 0 ? -1 : 1) : (attempt < 20 ? 1 : -1);
        await page.mouse.move(850, 650); await page.mouse.wheel(0, direction * 420);
        await page.waitForTimeout(100);
      }
      throw new Error('Control outside actual Flutter scroll viewport');
    };
    const click = async (name, role = 'button') => {
      step = 'click-visible-control';
      const control = page.getByRole(role, { name, exact: typeof name === 'string', disabled: false }).first();
      await expose(control); await control.click(); await page.waitForTimeout(350);
    };
    const field = async (label, value) => {
      const control = page.getByRole('textbox', { name: new RegExp(label), disabled: false });
      await expose(control); await control.click(); await control.fill(value);
    };
    const choose = async (button, file) => {
      const chooser = page.waitForEvent('filechooser'); await click(button); await (await chooser).setFiles(file);
    };
    const dropdown = async (label, choice) => {
      await click(new RegExp(label), 'button'); await click(choice, 'menuitem');
    };
    const dataTools = async () => {
      await click('设置'); await click('数据迁移与导出 预览导入、下载账目、查看与撤销本人迁移批次');
      await terms('Data tools loaded through Settings', ['选择文件与目标', '生成导入预览']);
    };
    const prepareCsv = async () => {
      await dropdown('文件格式', '钱迹公开 CSV 模板');
      await dropdown('目标账本', fixture.names.book);
      await choose('选择数据文件', fixture.files.qianji);
      await terms('Public V10 missing mappings exposed', ['账户：' + fixture.names.cash, '分类：' + fixture.names.category, '标签：' + fixture.names.tag]);
      for (const [kind, title] of [['cash', '账户'], ['category', '分类'], ['tag', '标签']]) {
        await dropdown(title + '：' + fixture.names[kind], fixture.names[kind]);
      }
      await click('生成导入预览');
      await terms('Public V10 exact two-row preview', ['共2条记录', '校验通过，可以确认导入。']);
    };
    const confirm = async () => {
      await click('确认正式导入'); await click('确认导入');
      await terms('Formal import and local pull completed', ['导入已确认，本机账本已刷新。'], 45000);
    };
    const home = async () => {
      for (let attempt = 0; attempt < 5; attempt++) {
        if (await page.getByRole('button', { name: '打开导航菜单', exact: true }).count()
            || await page.getByRole('button', { name: '管理账本、分类与标签', exact: true }).count()) return;
        await click('返回');
      }
      throw new Error('Normal home not reached after observed back controls');
    };
    const balance = async (minor) => {
      await home();
      if (await page.getByRole('button', { name: '打开导航菜单', exact: true }).count()) await click('打开导航菜单');
      await click(fixture.names.book); await click('资金账户');
      const amount = (BigInt(minor) / 100n).toString() + '.' + (BigInt(minor) % 100n).toString().padStart(2, '0');
      await terms('Exact account balance ' + minor, [fixture.names.cash, amount]);
    };
    if (phase === 'login' || phase === 'login-inspect') {
      await click('设置');
      const address = page.getByRole('textbox', { name: /服务器地址/, disabled: false });
      await expose(address); await address.click();
      if (await address.inputValue() !== fixture.api_origin) {
        await address.fill(fixture.api_origin); await click('保存地址');
        await page.waitForTimeout(5000);
      }
      await click('登录账号 邀请码注册、登录和会话管理');
      await page.getByRole('heading', { name: '账号与设备', exact: true }).waitFor({ state: 'visible' });
      if (phase === 'login-inspect') {
        await page.waitForTimeout(2000);
        await fs.writeFile(path.join(out, stem + '-aria.txt'), await aria());
        await page.screenshot({ path: path.join(out, stem + '.png'), mask: [page.locator('input,textarea')] });
        result.result = 'inspected'; return;
      }
      sensitive = true;
      await field('用户名', credentials.username); await field('密码', credentials.password); await click('登录');
      await page.getByRole('button', { name: '退出登录', exact: true, disabled: false }).waitFor({ state: 'visible', timeout: 20000 });
      await page.getByRole('textbox', { name: '密码', exact: true }).waitFor({ state: 'detached' }); sensitive = false;
      result.checks.push('Synthetic account authenticated through visible login form');
      await home();
      const deadline = Date.now() + 30000;
      do {
        result.shell = await page.evaluate(() => window.FlowTraceShell?.status?.() ?? null);
        if (result.shell?.complete) break;
        await page.waitForTimeout(250);
      } while (Date.now() < deadline);
      if (!result.shell?.complete) throw new Error('Sealed normal shell not offline ready');
      result.checks.push('Public shell reports complete offline cache');
    } else if (phase === 'inspect') {
      await dataTools();
    } else if (phase === 'native-preview') {
      await dataTools(); await choose('选择数据文件', fixture.files.native);
      await terms('Native file parsed with original image requirement', ['共6条记录', '我的个人资产与账户', '选择原图']);
      await choose('选择原图', fixture.files.image);
      await terms('Original PNG uploaded through file picker', ['原图已选择并上传']);
      await click('生成导入预览'); await terms('Native six-row frozen preview', ['校验通过，可以确认导入。', '共6条记录']);
    } else if (phase === 'native-apply' || phase === 'csv-apply') {
      await dataTools(); await click('继续预览');
      await terms('Persisted frozen preview resumed after browser restart', ['校验通过，可以确认导入。']);
      await confirm(); await balance(phase === 'native-apply' ? '9900' : '9650');
    } else if (phase === 'offline-prepared') {
      await terms('Cold offline normal home retained authenticated local book', ['默认账本', '离线 · 会话待验证']);
      result.shell = await page.evaluate(() => window.FlowTraceShell.status());
      if (!result.shell.complete) throw new Error('Offline release cache incomplete');
      result.checks.push('Offline sealed cache complete; no import confirmation sent');
    } else if (phase === 'offline' || phase === 'online-image') {
      if (phase === 'offline') result.checks.push('Browser cold opened while offline');
      await balance('9900'); await home(); await click('搜索账单（Ctrl+Alt+F）');
      await field('备注、分类、标签或金额', fixture.names.expense_note);
      await terms('Imported expense searchable from local projection', [fixture.names.expense_note, '1.25']);
      await click(new RegExp(fixture.names.expense_note));
      await click('预览图片1');
      await terms('Imported original opened in production image preview', ['图片预览']);
      // An odd width centers the three-pixel original on integer device pixels.
      await page.setViewportSize({ width: 1279, height: 900 });
      await page.waitForTimeout(500);
      const image = page.getByRole('img');
      await image.waitFor({ state: 'visible' });
      result.rendered_image = path.join(out, stem + '-original-rendered.png');
      result.rendered_image_box = await image.boundingBox();
      await image.screenshot({ path: result.rendered_image });
      const current = await aria();
      if (/图片未缓存在本机|图片无法显示|资料空间已变化|附件暂时不可读/.test(current)) throw new Error('Original not available in preview');
      result.checks.push('Original viewer has no offline/cache/access/decode error');
    } else if (phase === 'csv-preview') {
      await dataTools(); await prepareCsv();
    } else if (phase === 'csv-repeat') {
      await dataTools(); await prepareCsv();
      await terms('Same-source duplicate identities retained', ['已有同来源记录，将保留原记录']);
      await confirm(); await balance('9650');
    } else if (phase.startsWith('export-')) {
      await dataTools(); await click('导出', 'tab');
      const books = await page.getByRole('checkbox').all();
      for (const box of books) {
        const label = await box.getAttribute('aria-label') || '';
        if (label.includes('包含账本') || label.includes('Excel') || label.includes('个人资产')) continue;
        const wanted = label.includes(fixture.names.book), checked = await box.getAttribute('aria-checked') === 'true';
        if (wanted !== checked) { await expose(box); await box.click(); }
      }
      if (phase === 'export-xlsx') { await click('Excel', 'radio'); await click('在Excel中嵌入原图 未嵌入时保留需要登录后访问的图片链接', 'checkbox'); }
      const download = page.waitForEvent('download'); await click('导出并保存');
      const received = await download;
      const file = path.join(out, stem + (phase === 'export-json' ? '.json' : '.xlsx'));
      await received.saveAs(file); result.download = { file, sha256: sha(await fs.readFile(file)), bytes: (await fs.stat(file)).size };
      result.checks.push('Authorized export downloaded through actual browser UI');
    } else if (phase === 'csv-undo') {
      await dataTools(); await click('操作历史', 'tab');
      const card = page.getByRole('group', { name: /^qianji-public-template-v10 .*新增2条 · 同来源0条$/ });
      if (await card.count() !== 1) throw new Error('Created CSV batch not uniquely visible');
      await card.getByRole('button', { name: '查看撤销预览', exact: true }).click();
      await click('确认撤销');
      await terms('CSV UI undo refreshed local ledger', ['迁移已撤销，本机账本已刷新。'], 45000); await balance('9900');
    } else if (phase === 'csv-undo-readback') {
      result.mode = 'read-only-recovery-after-formal-ui-undo';
      await dataTools(); await click('操作历史', 'tab');
      await terms('Created CSV operation remains undone after cold browser restart', ['新增2条', '已撤销']);
      await balance('9900');
    } else if (phase === 'history') {
      await dataTools(); await click('操作历史', 'tab'); await terms('Own operation metadata history visible', ['qianji-public-template-v10', fixture.native_namespace]);
    } else if (phase === 'remote-refresh') {
      const remote = await read(path.join(out, 'remote-native-undo-receipt.json'));
      if (remote.result !== 'passed' || remote.run_id !== fixture.run_id) throw new Error('Formal second-client metadata required');
      await dataTools(); await click('操作历史', 'tab');
      await terms('Remote undone operation visible after cold restart', [fixture.native_namespace, '已撤销']);
      await Promise.all(pending);
      if (!result.http.some((entry) => entry.filtered_batch_id === remote.batch_id && entry.status === 200)) throw new Error('Client did not check exact remote batch status');
      if (!result.attachment_reads?.some((entry) => entry.attachment_id === remote.attachment_id
          && entry.scope_id === fixture.user_id && entry.sha256 === fixture.image_sha256 && entry.status === 'ready')) {
        throw new Error('Reverse local adoption did not reauthorize private original metadata');
      }
      if (result.operations.some((entry) => /apply|\/undo$/.test(entry.category))) throw new Error('UI resent a financial mutation during remote refresh');
      result.checks.push('Client exact-status GET and private-scope hash reauthorization observed; no apply/undo resend');
      await home();
      const current = await aria();
      if (current.includes(fixture.names.book)) throw new Error('Remote-deleted book remained visible');
      const parent = await read(path.join(path.dirname(out), 'browser-fixture.json'));
      await click(parent.names.book); await click('资金账户');
      await terms('Other migration remains intact after remote undo', [parent.names.cash, '99.00']);
      if ((await aria()).includes(fixture.names.cash)) throw new Error('Remote-deleted account remained visible');
      result.checks.push('Remote book/account removed while earlier book/account retained');
    } else if (phase === 'logout') {
      await click('设置'); await click(credentials.username + ' 账号、可访问账本与登录设备');
      await click('退出登录'); await click('确认'); await terms('Normal UI logout completed', ['用户名', '密码', '登录']);
    }
    await Promise.all(pending);
    if (result.errors.length) throw new Error('Unexpected browser page/layout error');
    if (!sensitive) { await fs.writeFile(path.join(out, stem + '-aria.txt'), await aria()); await page.screenshot({ path: path.join(out, stem + '.png') }); }
    result.result = 'passed';
  } catch (error) {
    result.result = 'failed'; result.failure = { step, name: error.name, message: sanitize(error.message).slice(0, 1200) };
    await Promise.allSettled(pending);
    if (page && !sensitive) {
      await fs.writeFile(path.join(out, stem + '-aria.txt'), sanitize(await page.locator('body').ariaSnapshot())).catch(() => {});
      await page.screenshot({ path: path.join(out, stem + '-failure.png') }).catch(() => {});
    }
  } finally {
    if (context) await context.close();
    result.ended_at = new Date().toISOString();
    const receipt = path.join(out, stem + '-receipt.json');
    await fs.writeFile(receipt, JSON.stringify(result, null, 2), { flag: 'wx' });
    console.log(JSON.stringify({ phase, result: result.result, checks: result.checks.length, receipt, failure: result.failure }));
    if (result.result === 'failed') process.exitCode = 1;
  }
}
main().catch((error) => { console.error(JSON.stringify({ result: 'failed-before-browser', name: error.name })); process.exitCode = 1; });
