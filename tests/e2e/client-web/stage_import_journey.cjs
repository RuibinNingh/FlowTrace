'use strict';
// Ordinary main and visible UI only. The separate Python harness owns fixture
// preparation, worker execution and server-side postconditions.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../..');
const phases = new Set(['login', 'inspect', 'save', 'upload', 'resources', 'preview',
  'queue-apply', 'applied', 'balance', 'queue-undo', 'undone', 'release-server', 'release-local', 'reopen', 'logout']);
const [phase, fixtureFile, buildArg, mainSha, sourceKind = 'native'] = process.argv.slice(2);
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const inside = (folder, file) => path.resolve(file).startsWith(path.resolve(folder) + path.sep);
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

async function main() {
  if (!phases.has(phase) || !['native', 'qianji'].includes(sourceKind) || !/^[0-9a-f]{64}$/.test(mainSha)) {
    throw new Error('Explicit phase, source and ordinary main SHA required');
  }
  const privatePath = path.resolve(fixtureFile || '');
  if (!inside(path.join(root, 'work/flowtrace-stage/live'), privatePath)) {
    throw new Error('Fresh stage fixture required');
  }
  const fixture = await read(privatePath);
  if (fixture.purpose !== 'flowtrace-stage-tcp-normal-client-synthetic-v1' ||
      fixture.version !== 1 || fixture.genuine_main_stage_and_group !== true ||
      fixture.expected_head !== '0016_backup_quarantine') {
    throw new Error('Seeded actual-main stage fixture required');
  }
  const manifest = { ...fixture, api_origin: fixture.server, sources: fixture.inputs,
    image: fixture.inputs.image, names: { ...fixture.inputs.names,
      native_book: fixture.inputs.names.book, csv_book: '默认账本' } };
  const run = manifest.run_id;
  if (!/^[0-9a-f]{32}$/.test(run) || manifest.api_origin !== 'http://127.0.0.1:18094' ||
      manifest.web_origin !== 'http://127.0.0.1:18194') {
    throw new Error('Fixed isolated stage origins required');
  }
  const actualFixture = await fs.realpath(privatePath);
  const actualRun = await fs.realpath(fixture.run_directory);
  if (path.dirname(actualFixture) !== actualRun ||
      !inside(await fs.realpath(path.join(root, 'work/flowtrace-stage/live')), actualFixture)) {
    throw new Error('Actual fixture must remain in its exact owned run');
  }
  const build = path.resolve(buildArg || '');
  if (!inside(path.join(root, 'apps/flowtrace/build'), build) ||
      sha(await fs.readFile(path.join(build, 'main.dart.js'))) !== mainSha) {
    throw new Error('Wrong ordinary candidate');
  }
  const credentials = fixture.account;
  if (typeof credentials.username !== 'string' || typeof credentials.password !== 'string') {
    throw new Error('Synthetic fixture credentials required');
  }
  const source = { ...manifest.sources[sourceKind], choices: sourceKind === 'native' ? [{
    label: `个人范围 · 原文件第${manifest.sources.native.source_user_requirement.first_line}行`,
    target_name: '当前个人范围',
  }] : [
    { label: '账户：' + manifest.sources.qianji.account_name, target_name: manifest.names.csv_cash },
    { label: '分类：' + manifest.sources.qianji.category_name, target_name: manifest.names.csv_category },
  ] };
  const sourceFile = path.resolve(source.path);
  const imageFile = path.resolve(manifest.image.path);
  for (const file of [sourceFile, imageFile]) {
    if (!inside(actualRun, await fs.realpath(file))) {
      throw new Error('Synthetic input must remain inside this private fixture');
    }
  }
  const sourceBytes = await fs.readFile(sourceFile);
  if (sha(sourceBytes) !== source.sha256 || sha(await fs.readFile(imageFile)) !== manifest.image.sha256) {
    throw new Error('Frozen synthetic source changed');
  }
  // Reuse the locally verified short-path strategy. No claim is made about a
  // universal Chromium path limit, and no old profile is inspected or removed.
  const profile = path.resolve('C:/ft-chrome', `st-${run.slice(0, 12)}`);
  const out = path.join(root, 'outputs/validation/P5/stage-browser', run);
  await fs.mkdir(out, { recursive: true });
  const marker = path.join(out, 'owned-profile.json');
  const profileBinding = { purpose: 'flowtrace-stage-ordinary-chrome-v1', run_id: run, profile };
  try {
    const existing = await read(marker);
    if (JSON.stringify(existing) !== JSON.stringify(profileBinding)) {
      throw new Error('Owned profile binding changed');
    }
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
    try {
      await fs.access(profile);
      throw new Error('Unbound preexisting browser profile refused');
    } catch (profileError) {
      if (profileError.code !== 'ENOENT') {
        throw profileError;
      }
    }
    await fs.writeFile(marker, JSON.stringify(profileBinding, null, 2), { flag: 'wx' });
  }
  const stamp = new Date().toISOString().replace(/[^0-9TZ]/g, '');
  const stem = `${sourceKind}-${phase}-${stamp}`;
  const result = { run_id: run, phase, source: sourceKind, ordinary_main_sha256: mainSha,
    source_sha256: source.sha256, source_bytes: sourceBytes.length,
    source_expected_chunks: Math.ceil(sourceBytes.length / (512 * 1024)),
    browser_surface: 'owned-installed-headed-Chrome', profile,
    started_at: new Date().toISOString(), result: 'running', checks: [], http: [], stages: [], jobs: [],
    commands: [], group_pages: [], chunk_puts: [], errors: [] };
  const sanitize = (input) => [credentials.username, credentials.password].reduce(
    (text, secret) => text.split(secret).join('[redacted]'), String(input));
  let context, page, sensitive = false, step = 'launch';
  const pending = [];
  const select = (body, keys) => Object.fromEntries(keys.filter((key) => key in body).map((key) => [key, body[key]]));
  try {
    context = await chromium.launchPersistentContext(profile, {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
      locale: 'zh-CN', viewport: { width: 1280, height: 960 }, acceptDownloads: true, timeout: 20000,
    });
    result.browser_version = context.browser().version();
    page = context.pages()[0];
    page.setDefaultTimeout(15000);
    page.on('request', (request) => {
      if (new URL(request.url()).hostname === 'invalid.example') {
        result.errors.push({ type: 'unexpected-original-image-url-fetch' });
      }
    });
    page.on('pageerror', (error) => result.errors.push({ type: 'pageerror', name: error.name }));
    page.on('console', (message) => {
      if (message.type() === 'error' && /RenderFlex|overflowed|Unhandled Exception/.test(message.text())) {
        result.errors.push({ type: 'layout-or-runtime' });
      }
    });
    page.on('response', (response) => {
      const url = new URL(response.url()), request = response.request();
      if (url.origin !== manifest.api_origin) {
        return;
      }
      const method = request.method(), endpoint = url.pathname;
      result.http.push({ method, path: endpoint, status: response.status() });
      if (method === 'POST' && endpoint.endsWith('/sync/push')) {
        result.errors.push({ type: 'unexpected-sync-push' });
      }
      if (method === 'PUT' && /\/import-stages\/[^/]+\/chunks\/\d+$/.test(endpoint)) {
        const bytes = request.postDataBuffer();
        result.chunk_puts.push({ path: endpoint, bytes: bytes?.length ?? 0,
          sha256: bytes ? sha(bytes) : null, header_sha256: request.headers()['x-chunk-sha256'], status: response.status() });
      }
      if (!endpoint.includes('/import-stages') && !endpoint.includes('/sync/group-pulls')) {
        return;
      }
      pending.push((async () => {
        if (!response.ok()) {
          return;
        }
        const body = await response.json();
        if (endpoint.includes('/import-stages') && typeof body.stage_id === 'string') {
          const metadata = select(body, ['stage_id', 'batch_id', 'stage_version', 'status', 'expected_bytes',
            'received_bytes', 'received_chunks', 'row_count', 'error_count', 'preview_hash', 'mapping_hash',
            'requirements_version', 'requirements_hash', 'requirements_count', 'source_released',
            'has_more', 'next_cursor', 'job_id', 'parse_job_id', 'preview_job_id', 'apply_job_id', 'undo_job_id']);
          if (body.items) {
            metadata.item_count = body.items.length;
          }
          if (body.rows) {
            metadata.row_page_count = body.rows.length;
            metadata.row_positions = body.rows.map((row) => row.position);
          }
          result.stages.push({ path: endpoint, ...metadata });
          if (Array.isArray(body.jobs)) {
            result.jobs.push({ stage_id: body.stage_id, stage_version: body.stage_version, jobs: body.jobs });
          }
        }
        if (endpoint.includes('/sync/group-pulls')) {
          result.group_pages.push({ method, path: endpoint, body_sha256: sha(await response.body()),
            next: body.next ?? null, status: body.status ?? null });
        }
        if (['POST', 'PUT'].includes(method) && !endpoint.includes('/chunks/')) {
          const data = request.postDataBuffer();
          result.commands.push({ method, path: endpoint, body_sha256: data ? sha(data) : null });
        }
      })().catch((error) => { result.errors.push({ type: 'response-inspection', name: error.name }); }));
    });
    const deliveredPromise = page.waitForResponse((r) => new URL(r.url()).pathname === '/main.dart.js', { timeout: 45000 });
    await page.goto(manifest.web_origin, { waitUntil: 'domcontentloaded', timeout: 45000 });
    const delivered = await deliveredPromise;
    if (delivered.status() !== 200 || sha(await delivered.body()) !== mainSha) {
      throw new Error('Actual browser main differs from fixed candidate');
    }
    result.checks.push('Ordinary main received with exact fixed SHA');
    await page.getByRole('button', { name: '设置', exact: true }).first().waitFor({ state: 'visible', timeout: 45000 });
    const feedback = page.getByRole('button', { name: '收起提示', exact: true });
    if (await feedback.isVisible()) {
      await feedback.press('Enter');
      result.checks.push('Dismissed public shell feedback using its visible control');
    }
    const aria = async () => sanitize(await page.locator('body').ariaSnapshot());
    const terms = async (label, values, timeout = 30000) => {
      step = label;
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        const text = (await aria()).replace(/\s+/g, ' ');
        if (values.every((value) => text.includes(value))) {
          result.checks.push(label);
          return;
        }
        await page.waitForTimeout(200);
      }
      throw new Error('Expected visible phase state absent');
    };
    const expose = async (control) => {
      for (let attempt = 0; attempt < 48; attempt++) {
        const box = await control.count() ? await control.boundingBox() : null;
        if (box && box.y >= 0 && box.y + box.height <= 960) {
          return;
        }
        await page.mouse.move(900, 700);
        await page.mouse.wheel(0, box ? (box.y < 0 ? -420 : 420) : (attempt < 26 ? 420 : -420));
        await page.waitForTimeout(120);
      }
      throw new Error('Visible Flutter control not reachable by actual scrolling');
    };
    const click = async (name, role = 'button') => {
      step = 'click-visible-' + role;
      const control = page.getByRole(role, { name, exact: typeof name === 'string', disabled: false }).first();
      await expose(control);
      await control.click();
      await page.waitForTimeout(300);
    };
    const field = async (label, value) => {
      const input = page.getByRole('textbox', { name: label, disabled: false });
      await expose(input);
      await input.click();
      await input.fill(value);
    };
    const dropdown = async (label, value) => {
      step = 'open-visible-dropdown';
      const control = page.getByRole('button', { name: new RegExp(escaped(label)), disabled: false }).first();
      await expose(control);
      await control.click();
      await page.getByRole('menu').waitFor({ state: 'visible' });
      await page.getByRole('menuitem', { name: value, exact: true }).waitFor({ state: 'visible' });
      await fs.writeFile(path.join(out, stem + '-dropdown-' + result.checks.length + '-aria.txt'),
        await aria(), { flag: 'wx' });
      await click(value, 'menuitem');
    };
    const choose = async (label, file) => {
      const event = page.waitForEvent('filechooser');
      await click(label);
      await (await event).setFiles(file);
    };
    const disabled = async (label) => {
      const button = page.getByRole('button', { name: label, exact: true });
      const deadline = Date.now() + 20000;
      while (Date.now() < deadline) {
        if (await button.isDisabled()) {
          result.checks.push('Confirmed visible control disabled after actual ' + label);
          return;
        }
        await page.waitForTimeout(200);
      }
      throw new Error('Expected confirmed action remained enabled');
    };
    const home = async () => {
      for (let attempt = 0; attempt < 6; attempt++) {
        if (await page.getByRole('button', { name: '管理账本、分类与标签', exact: true }).count() ||
            await page.getByRole('button', { name: '打开导航菜单', exact: true }).count()) {
          return;
        }
        await click('返回');
      }
      throw new Error('Normal home not reached');
    };
    const stagePage = async () => {
      await click('设置');
      await click('数据迁移与导出 预览导入、下载账目、查看与撤销本人迁移批次');
      await click('大文件导入', 'tab');
      await terms('Ordinary staged import tab available', ['原件先保存在当前资料空间', '选择并保存原件']);
    };
    const selectSource = async () => {
      await stagePage();
      await click(new RegExp('^' + escaped(path.basename(sourceFile))));
      await terms('Durable original selected after browser restart', [path.basename(sourceFile), '继续上传与解析']);
    };
    const refresh = async () => {
      await click('获取服务器状态');
      await page.waitForTimeout(750);
    };
    if (phase === 'login') {
      await click('设置');
      await field(/服务器地址/, manifest.api_origin);
      await click('保存地址');
      await terms('Fixed isolated server saved', ['地址已保存']);
      await click('登录账号 邀请码注册、登录和会话管理');
      sensitive = true;
      await field(/用户名/, credentials.username);
      await field(/密码/, credentials.password);
      await click('登录');
      await page.getByRole('button', { name: '退出登录', exact: true }).waitFor({ state: 'visible' });
      await page.getByRole('textbox', { name: '密码', exact: true }).waitFor({ state: 'detached' });
      sensitive = false;
      result.checks.push('Synthetic owner logged in using visible ordinary fields');
      await home();
    } else if (phase === 'save') {
      await stagePage();
      await dropdown('原始文件格式', sourceKind === 'native' ? '流迹 JSON' : '钱迹公开 CSV 模板');
      if (sourceKind === 'qianji') {
        await dropdown('目标账本', manifest.names.csv_book);
      }
      await choose('选择并保存原件', sourceFile);
      await terms('Actual selected source saved locally before HTTP', ['原始文件已保存在本机', path.basename(sourceFile)]);
      if (result.http.some((item) => item.path.includes('/import-stages'))) {
        throw new Error('Saving original unexpectedly sent a stage request');
      }
    } else if (phase === 'inspect') {
      await stagePage();
      result.visible_control_bounds = await Promise.all(['原始文件格式', '目标账本', '选择并保存原件'].map(async (label) => ({
        label, bounds: await page.getByRole('button', { name: new RegExp(escaped(label)) }).first().boundingBox(),
      })));
    } else if (phase === 'balance') {
      await home();
      if (await page.getByRole('button', { name: '打开导航菜单', exact: true }).count()) {
        await click('打开导航菜单');
      }
      await click(sourceKind === 'native' ? manifest.names.native_book : manifest.names.csv_book);
      await click('资金账户');
      const minor = BigInt(sourceKind === 'native' ? source.balance_minor :
        (10000n - BigInt(source.expense_minor)).toString());
      const amount = `${minor / 100n}.${(minor % 100n).toString().padStart(2, '0')}`;
      await terms('Cold-reopened ordinary account shows exact balance ' + minor.toString(),
        [sourceKind === 'native' ? manifest.names.cash : manifest.names.csv_cash, amount]);
    } else if (phase === 'logout') {
      await click('设置');
      await click(new RegExp('账号、可访问账本与登录设备$'));
      await click('退出登录');
      await click('确认');
      await terms('Ordinary browser session logged out', ['用户名', '密码', '登录']);
    } else {
      await selectSource();
      if (phase === 'upload') {
        await click('继续上传与解析');
        await terms('Frozen original uploaded and parse request retained', ['等待解析']);
      } else if (phase === 'resources') {
        await refresh();
        await click('查看原始资源清单');
        await terms('Requirements complete before mapping', ['清单已完整核对']);
        for (const choice of source.choices) {
          await dropdown(choice.label, choice.target_name);
        }
        if (sourceKind === 'native') {
          await click('读取原文件内账本');
          await dropdown('明确选择这张原图所属的账本', '原文件账本：' + manifest.names.native_book);
        }
        await choose('选择并上传原图', imageFile);
        await terms('Selected original uploaded and paired draft persisted', ['原图已上传并保存选择']);
        await click('保存资源选择并重新解析');
        await terms('Mapping frozen for reparse', ['资源选择已保存，服务器正在重新解析']);
      } else if (phase === 'preview') {
        await refresh();
        await click('查看原始资源清单');
        await terms('Complete requirements rechecked after mapping version changed', ['清单已完整核对']);
        await click('生成完整导入预览');
        await terms('Actual preview queued without financial confirmation', ['已提交预览请求']);
      } else if (phase === 'queue-apply') {
        await refresh();
        await terms('Real preview ready', ['预览完成，等待确认', '错误项：0']);
        const rowPage = async (label) => {
          const response = page.waitForResponse((item) =>
            new URL(item.url()).origin === manifest.api_origin &&
            /\/import-stages\/[^/]+\/rows$/.test(new URL(item.url()).pathname) && item.status() === 200);
          await click(label);
          await response;
        };
        await rowPage('查看逐行预览');
        await terms('Actual row metadata preview visible', ['逐行预览']);
        for (let index = 1; index < Math.ceil(source.row_count / 100); index++) {
          await rowPage('下一页逐行预览');
        }
        await Promise.all(pending);
        const rowPages = result.stages.filter((item) => Array.isArray(item.row_positions));
        const positions = rowPages.flatMap((item) => item.row_positions);
        if (rowPages.length !== Math.ceil(source.row_count / 100) ||
            positions.length !== source.row_count || positions.some((value, index) => value !== index + 1) ||
            rowPages.some((item) => item.stage_id !== rowPages[0].stage_id ||
              item.stage_version !== rowPages[0].stage_version) || rowPages.at(-1).has_more !== false) {
          throw new Error('Actual visible row pagination did not cover the exact fixed source');
        }
        await disabled('下一页逐行预览');
        result.checks.push('Normal UI row pagination covers exact consecutive positions 1..' + source.row_count);
        await click('确认正式导入');
        await terms('Explicit whole batch confirmation dialog visible', ['确认导入整个批次']);
        await click('确认导入整个批次');
        await click('刷新任务状态');
        await terms('Real apply job queued rather than inferred from stage.ready', ['正式导入：已排队']);
      } else if (phase === 'applied') {
        await refresh();
        await terms('Actual applied stage and fresh group projection agreed', ['已导入并同步最新资料。'], 60000);
      } else if (phase === 'queue-undo') {
        await refresh();
        await click('撤销这次正式导入');
        await terms('Explicit batch undo dialog visible', ['确认撤销这个批次']);
        await click('确认撤销这个批次');
        await click('刷新任务状态');
        await terms('Real undo job queued', ['正式撤销：已排队']);
      } else if (phase === 'undone') {
        await refresh();
        await terms('Actual undone stage and fresh group projection agreed', ['已撤销并同步最新资料。'], 60000);
      } else if (phase === 'release-server' || phase === 'release-local') {
        await refresh();
        await click('原件、续接与清理');
        if (phase === 'release-server') {
          await click('释放服务器原件');
          await click('确认释放服务器原件');
          await disabled('释放服务器原件');
          await terms('Server source release confirmed', ['已撤销并同步最新资料。']);
        } else {
          await click('释放本机原件副本');
          await click('确认释放本机副本');
          await terms('Actual active local bytes released', ['本机原件已释放']);
        }
      } else if (phase === 'reopen') {
        await terms('Owned profile cold reopen retains source metadata', [path.basename(sourceFile)]);
      }
    }
    for (let count = 0; count < 5; count++) {
      const length = pending.length;
      await Promise.all(pending);
      if (length === pending.length) {
        break;
      }
    }
    if (result.errors.length) {
      throw new Error('Unexpected browser or response inspection failure');
    }
    for (const chunk of result.chunk_puts) {
      if (chunk.bytes < 1 || chunk.bytes > 512 * 1024 || chunk.sha256 !== chunk.header_sha256) {
        throw new Error('Actual upload bytes and dedicated chunk header disagree');
      }
      const index = Number(chunk.path.match(/\/chunks\/(\d+)$/)[1]);
      const expected = sourceBytes.subarray(index * 512 * 1024, (index + 1) * 512 * 1024);
      if (expected.length !== chunk.bytes || sha(expected) !== chunk.sha256) {
        throw new Error('Actual uploaded chunk differs from fixed source bytes');
      }
    }
    if (phase === 'upload' && !result.stages.some((item) =>
      item.received_bytes === sourceBytes.length && item.received_chunks === result.source_expected_chunks)) {
      throw new Error('Actual stage response does not confirm complete source chunks');
    }
    result.result = 'passed';
    if (!sensitive) {
      await fs.writeFile(path.join(out, stem + '-aria.txt'), await aria(), { flag: 'wx' });
      await page.screenshot({ path: path.join(out, stem + '.png'), mask: [page.locator('input,textarea')] });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.waitForTimeout(500);
      await fs.writeFile(path.join(out, stem + '-390-aria.txt'), await aria(), { flag: 'wx' });
      await page.screenshot({ path: path.join(out, stem + '-390.png'), mask: [page.locator('input,textarea')] });
      if (result.errors.length) {
        throw new Error('Unexpected browser failure after narrow viewport layout');
      }
    }
  } catch (error) {
    result.result = 'failed';
    result.failure = { step, name: error.name, message: sanitize(error.message).slice(0, 800) };
    await Promise.allSettled(pending);
    if (page && !sensitive) {
      await fs.writeFile(path.join(out, stem + '-aria.txt'), sanitize(await page.locator('body').ariaSnapshot()), { flag: 'wx' }).catch(() => {});
      await page.screenshot({ path: path.join(out, stem + '-failure.png'), mask: [page.locator('input,textarea')] }).catch(() => {});
    }
  } finally {
    if (context) {
      await context.close();
    }
    result.ended_at = new Date().toISOString();
    const receipt = path.join(out, stem + '-receipt.json');
    await fs.writeFile(receipt, JSON.stringify(result, null, 2), { flag: 'wx' });
    console.log(JSON.stringify({ phase, source: sourceKind, result: result.result, receipt, failure: result.failure }));
    if (result.result === 'failed') {
      process.exitCode = 1;
    }
  }
}
main().catch((error) => { console.error(JSON.stringify({ result: 'failed-before-browser', name: error.name })); process.exitCode = 1; });
