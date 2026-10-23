// Actual normal-main UI only. Dedicated installed Chrome, no injected tokens,
// service calls, IndexedDB edits, internal Flutter functions or fake success.
'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../../..');
const output = path.join(root, 'outputs/validation/P4');
const profileRoot = path.join(root, 'work/flowtrace-dev/browser-profiles');
const buildDirectory = process.argv.find((value) => value.startsWith('--build-directory='))?.split('=')[1] || 'web-p4';
if (!['web-p4', 'web-p4-semantics', 'web-p4-fonts', 'web-p4-logout', 'web-p4-auth-card'].includes(buildDirectory)) throw new Error('Unknown fixed P4 build directory');
const build = path.join(root, 'apps/flowtrace/build', buildDirectory);
const webOrigin = 'http://127.0.0.1:18185';
const apiOrigin = 'http://127.0.0.1:18085';
const phaseFlag = process.argv.indexOf('--phase');
const phase = (phaseFlag >= 0 ? process.argv[phaseFlag + 1] : process.argv[2]) || 'inspect';
const readOnlyValuation = process.argv.includes('--verify-valuation-only');
const evidenceTag = readOnlyValuation ? phase + '-valuation-readback' : phase;
const phases = new Set(['login', 'inspect', 'sync', 'overview', 'overview-narrow',
  'group-create', 'account-create', 'account-metadata', 'money-privacy',
  'fund-repayment', 'fund-borrow', 'fund-lend', 'fund-collect', 'fund-repay', 'fund-fx',
  'currency-preferences', 'rate-create', 'rate-replace',
  'read-details', 'read-credit', 'read-history', 'verify-reopen', 'logout', 'logout-reopen']);
const checkpoints = new Set(['font-verify', 'font-narrow', 'configuration-feedback', 'logout-form-only']);
const read = async (file) => JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, ''));
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const uuid = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const inside = (folder, file) => path.resolve(file).startsWith(path.resolve(folder) + path.sep);
function required(object, key) {
  const value = object?.[key];
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('Missing fixed synthetic value');
  return value;
}

async function main() {
  if (!phases.has(phase) && !checkpoints.has(phase)) throw new Error('Unknown fixed P4 phase');
  const fixture = await read(path.join(output, 'web-assets-fixture.json'));
  if (fixture.purpose !== 'flowtrace-p4-assets-ui-synthetic' || fixture.state !== 'seeded'
      || fixture.api_origin !== apiOrigin || !uuid(fixture.run_id) || !uuid(fixture.instance_id)
      || !uuid(fixture.sync_epoch) || !uuid(fixture.user_id)) throw new Error('Invalid active synthetic fixture');
  const credentialsPath = path.resolve(root, required(fixture, 'credentials_path'));
  if (!inside(path.join(root, 'work/flowtrace-dev'), credentialsPath)) throw new Error('Credentials outside synthetic workspace');
  const credentials = await read(credentialsPath);
  const account = Array.isArray(credentials) ? credentials[fixture.account_index ?? 0] : credentials;
  required(account, 'username'); required(account, 'password');
  if (!checkpoints.has(phase) && !['login', 'inspect', 'sync', 'logout', 'logout-reopen'].includes(phase)
      && (!Array.isArray(fixture.expected?.[phase]) || fixture.expected[phase].length === 0)) {
    throw new Error('Prepare exact visible expectations before opening a mutation phase');
  }
  await fs.mkdir(output, { recursive: true });
  await fs.mkdir(profileRoot, { recursive: true });
  const sessionPath = path.join(output, 'web-assets-browser-session.json');
  let session;
  try { session = await read(sessionPath); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (session) {
    if (session.run_id !== fixture.run_id || session.instance_id !== fixture.instance_id
        || session.sync_epoch !== fixture.sync_epoch || session.user_id !== fixture.user_id
        || !inside(profileRoot, session.profile) || !/^chrome-p4-assets-[0-9a-f-]{36}$/.test(path.basename(session.profile))) {
      throw new Error('Refusing unrelated or personal browser profile');
    }
  } else {
    const profile = path.join(profileRoot, `chrome-p4-assets-${randomUUID()}`);
    await fs.mkdir(profile); // Fresh UUID, never an existing personal directory.
    session = { run_id: fixture.run_id, instance_id: fixture.instance_id, sync_epoch: fixture.sync_epoch,
      user_id: fixture.user_id, profile, web_origin: webOrigin, api_origin: apiOrigin, created_at: new Date().toISOString() };
    await fs.writeFile(sessionPath, JSON.stringify(session, null, 2), { flag: 'wx' });
  }
  if (readOnlyValuation && !['rate-create', 'rate-replace'].includes(phase)) throw new Error('Unsupported read-only recovery phase');
  const receiptPath = path.join(output, `web-assets-${evidenceTag}-receipt.json`);
  try {
    const previous = await read(receiptPath);
    const stamp = previous.started_at.replace(/[^0-9TZ]/g, '');
    for (const suffix of ['receipt.json', 'aria.txt', 'failure.png']) {
      try { await fs.copyFile(path.join(output, `web-assets-${evidenceTag}-${suffix}`),
        path.join(output, `web-assets-${evidenceTag}-previous-${stamp}-${suffix}`), require('node:fs').constants.COPYFILE_EXCL); }
      catch (error) { if (!['ENOENT', 'EEXIST'].includes(error.code)) throw error; }
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const journalPath = path.join(output, 'web-assets-ui-mutations.json');
  let journal;
  try { journal = await read(journalPath); }
  catch (error) { if (error.code !== 'ENOENT') throw error; journal = { run_id: fixture.run_id, mutations: {} }; }
  if (journal.run_id !== fixture.run_id) throw new Error('Different mutation journal');
  const result = { phase, result: 'running', started_at: new Date().toISOString(),
    mode: readOnlyValuation ? 'read-only-valuation-readback' : 'normal-ui-phase',
    build_directory: buildDirectory,
    main_js_sha256: hash(await fs.readFile(path.join(build, 'main.dart.js'))),
    run_id: fixture.run_id, dedicated_test_profile: true, profile: session.profile,
    attached_to_existing_browser: false, web_origin: webOrigin, api_origin: apiOrigin,
    viewport: ['overview-narrow', 'font-narrow'].includes(phase) ? { width: 390, height: 844 } : { width: 1280, height: 900 },
    checks: [], errors: [], http: [], operations: [], applied: [] };
  const context = await chromium.launchPersistentContext(session.profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: false,
    locale: 'zh-CN', viewport: result.viewport, timeout: 15000,
  });
  result.browser_version = context.browser().version();
  result.node_pid = process.pid;
  const page = context.pages()[0];
  if (process.argv.includes('--block-remote-fonts')) {
    result.blocked_remote_fonts = [];
    await context.route(/https:\/\/(?:fonts\.gstatic\.com|fonts\.googleapis\.com)\//, async (route) => {
      const url = new URL(route.request().url());
      result.blocked_remote_fonts.push({ origin: url.origin, pathname: url.pathname });
      await route.abort('blockedbyclient');
    });
  }
  if (phase === 'font-narrow') {
    const cdp = await context.newCDPSession(page);
    await cdp.send('Emulation.setEmulatedOSTextScale', { scale: 1.8 });
    result.browser_os_text_scale_emulation = 1.8;
  }
  page.setDefaultTimeout(10000);
  let step = 'open-fixed-normal-main';
  let sensitiveForm = false;
  let credentialsEntered = false;
  const pending = [];
  const safe = (value) => {
    for (const key of ['username', 'password', 'invite_token']) if (account[key]) value = value.split(account[key]).join(`[redacted-${key}]`);
    return value;
  };
  const aria = async () => safe(await page.locator('body').ariaSnapshot());
  const pointControl = async (control) => {
    // Browser DOM scrolling cannot move Flutter's canvas Scrollable. Use actual
    // wheel input until the observed semantics rectangle is within the viewport.
    for (let attempt = 0; attempt < 16; attempt++) {
      const rect = await control.boundingBox();
      if (rect && rect.y >= 0 && rect.y + rect.height <= result.viewport.height) return;
      const direction = rect && rect.y < 0 ? -1 : 1;
      await page.mouse.move(result.viewport.width / 2, result.viewport.height * 0.7);
      await page.mouse.wheel(0, direction * 450);
      await page.waitForTimeout(120);
    }
    throw new Error('Actual Flutter scroll did not expose observed control');
  };
  const click = async (name, role = 'button') => {
    step = `click-${role}`;
    const control = page.getByRole(role, { name, exact: typeof name === 'string', disabled: false });
    if (role === 'menuitem') {
      await page.getByRole('menu').waitFor({ state: 'visible' });
      for (let attempt = 0; await control.count() === 0 && attempt < 22; attempt++) {
        const targetCode = typeof name === 'string' && /^[A-Z]{3} /.test(name) ? name.slice(0, 3) : null;
        const visibleLabels = await page.getByRole('menuitem').evaluateAll((nodes) => nodes.map((node) => node.getAttribute('aria-label') || node.textContent || ''));
        const firstCode = visibleLabels.find((label) => /^[A-Z]{3} /.test(label))?.slice(0, 3);
        const direction = targetCode && firstCode && targetCode < firstCode ? -1 : 1;
        await page.mouse.move(result.viewport.width / 2, result.viewport.height * 0.65);
        await page.mouse.wheel(0, direction * 450);
        await page.waitForTimeout(120);
      }
    }
    await control.waitFor({ state: 'visible', timeout: 15000 });
    await pointControl(control);
    await control.click();
  };
  const field = async (label, value) => {
    step = 'fill-control-' + label;
    // Flutter may merge the preceding section text into aria-label. Require
    // the real field label as an exact suffix, preserving strict uniqueness.
    const control = page.getByRole('textbox', { name: new RegExp('(?:^|\\s)' + escaped(label) + '$'), disabled: false });
    await control.waitFor({ state: 'visible', timeout: 30000 });
    await pointControl(control); await control.click(); await control.fill(value);
  };
  const dropdown = async (label, value) => {
    await click(new RegExp('^' + escaped(label) + '( |$)'));
    await click(value, 'menuitem');
  };
  const terms = async (label, values, timeout = 15000) => {
    if (!Array.isArray(values) || values.length === 0 || values.some((value) => typeof value !== 'string' || !value)) throw new Error('Missing fixed visible expectations');
    step = `verify-${label}`;
    const until = Date.now() + timeout;
    do {
      const tree = (await aria()).replace(/\s+/g, ' ');
      if (values.every((value) => tree.includes(value))) { result.checks.push(label); return; }
      await page.waitForTimeout(100);
    } while (Date.now() < until);
    throw new Error('Actual accessible UI differs from fixed synthetic expectations');
  };
  const expectPhase = async () => {
    const expectedPhase = ['font-verify', 'font-narrow'].includes(phase) ? 'verify-reopen' : phase;
    await terms(phase, fixture.expected?.[expectedPhase]);
    const initialTree = (await aria()).replace(/\s+/g, ' ');
    for (const absent of fixture.absent?.[expectedPhase] || []) {
      if (typeof absent !== 'string' || !absent || initialTree.includes(absent)) throw new Error('Expected-hidden synthetic data is still accessible');
    }
    if (phase === 'font-narrow') await screenshot('font-narrow-summary');
    for (const [key, amount] of Object.entries(fixture.expected_rows?.[expectedPhase] || {})) {
      const name = required(fixture.names, key);
      const row = page.getByRole('button', { name: new RegExp('^' + escaped(name) + ' .*' + escaped(amount)) });
      if (phase === 'font-narrow') {
        for (let attempt = 0; await row.count() === 0 && attempt < 12; attempt++) {
          await page.mouse.move(195, 600); await page.mouse.wheel(0, 350); await page.waitForTimeout(120);
        }
        await pointControl(row);
      }
      await row.waitFor({ state: 'visible' });
      result.checks.push('Associated account row and exact native balance: ' + key);
    }
    const tree = (await aria()).replace(/\s+/g, ' ');
    for (const absent of fixture.absent?.[expectedPhase] || []) {
      if (typeof absent !== 'string' || !absent || tree.includes(absent)) throw new Error('Expected-hidden synthetic data is still accessible');
    }
  };
  const screenshot = async (suffix = evidenceTag) => {
    if (!sensitiveForm) await page.screenshot({ path: path.join(output, `web-assets-${suffix}.png`), mask: /^(?:login|logout)/.test(phase) && !suffix.endsWith('-public-input') ? [page.locator('input,textarea'), page.getByRole('textbox')] : [] });
  };
  const mutate = async (label, action) => {
    const key = `${phase}.${label}`;
    if (journal.mutations[key]) throw new Error('Mutation already attempted; inspect persisted evidence before any retry');
    journal.mutations[key] = { state: 'started', started_at: new Date().toISOString() };
    await fs.writeFile(journalPath, JSON.stringify(journal, null, 2));
    await action();
    journal.mutations[key].state = 'completed';
    journal.mutations[key].completed_at = new Date().toISOString();
    await fs.writeFile(journalPath, JSON.stringify(journal, null, 2));
  };
  const assets = async () => { await click('打开导航菜单'); await click('资金账户'); await terms('assets-route', ['净资产', '私人账户只属于你']); };
  const selectBook = async () => {
    await click('打开导航菜单');
    if (checkpoints.has(phase) || ['currency-preferences', 'rate-create', 'rate-replace', 'read-details', 'read-credit', 'read-history', 'verify-reopen'].includes(phase)) {
      await page.getByRole('button', { name: '同步与恢复 · 0项待处理', exact: true }).waitFor({ state: 'visible' });
      result.checks.push('Actual drawer confirms zero pending sync commands');
    }
    await click(required(fixture.names, 'book'));
  };
  const actionMenu = async (name, action) => { await click(name + '操作'); await click(action, 'menuitem'); };
  const openAccount = async (name) => { await click(new RegExp('^' + escaped(name) + '( |$)')); await terms('account-details-route', ['账户明细', name]); };
  const refreshRead = async () => { await click('刷新服务器资料'); await terms('read-confirmed', ['服务器已确认'], 20000); };
  const menu = async (action) => { await click('资产设置'); await click(action, 'menuitem'); };
  const refreshConfiguration = async () => {
    const requests = ['/api/v1/assets/groups', '/api/v1/currencies/preferences', '/api/v1/currencies/rates']
      .map((pathname) => page.waitForResponse((response) => new URL(response.url()).origin === apiOrigin
        && new URL(response.url()).pathname === pathname && response.request().method() === 'GET'));
    await click('联网刷新');
    for (const response of await Promise.all(requests)) if (response.status() !== 200) throw new Error('Configuration refresh was not confirmed');
    await page.getByRole('button', { name: '联网刷新', exact: true, disabled: false }).waitFor({ state: 'visible' });
    if (!(await aria()).includes('配置已刷新。')) {
      result.accessibility_gaps ??= [];
      result.accessibility_gaps.push('Visible configuration feedback absent from accessible tree');
      result.accessibility_result = 'failed';
    }
    result.checks.push('All three configuration GET200 responses and enabled refresh control observed');
  };
  const focusFacts = () => page.evaluate(() => {
    let node = document.activeElement;
    while (node?.shadowRoot?.activeElement) node = node.shadowRoot.activeElement;
    return node ? { tag: node.tagName, type: node.getAttribute('type'), label: node.getAttribute('aria-label'), disabled: node.disabled ?? null, read_only: node.readOnly ?? null } : null;
  });
  const diagnoseSemantics = async (reason) => {
    const collect = () => page.evaluate(() => {
      const labelWhitelist = new Set(['用户名', '密码', '登录', '邀请码注册', '账号与设备', '返回', '确认', '退出确认']);
      const safeLabel = (value) => labelWhitelist.has(value) ? value : { category: 'other', length: value.length };
      const numericId = (node) => {
        const match = /^flt-semantic-node-(\d+)$/.exec(node.getAttribute('id') || '');
        return match ? match[1] : null;
      };
      const ids = new WeakMap(); let nextId = 1;
      const localId = (node) => { if (!ids.has(node)) ids.set(node, nextId++); return ids.get(node); };
      const parentOf = (node) => node.parentElement || node.getRootNode()?.host || null;
      const aria = (node) => {
        const attributes = {};
        for (const attribute of node.attributes) {
          const name = attribute.name;
          if (!name.startsWith('aria-')) continue;
          if (/value|data/.test(name)) { attributes[name] = '[redacted-value-attribute]'; continue; }
          const value = node.getAttribute(name) || '';
          if (['aria-label', 'aria-description', 'aria-roledescription'].includes(name)) attributes[name] = safeLabel(value);
          else if (['aria-owns', 'aria-controls', 'aria-labelledby', 'aria-describedby', 'aria-activedescendant'].includes(name)) {
            attributes[name] = value.split(/\s+/).filter(Boolean).map((item) => /^flt-semantic-node-\d+$/.test(item) ? item : 'other-id');
          } else attributes[name] = /^[A-Za-z0-9_ .:+-]{0,80}$/.test(value) ? value : { category: 'other', length: value.length };
        }
        return attributes;
      };
      const brief = (node) => ({ diagnostic_id: localId(node), tag: node.tagName, node_id: numericId(node), role: node.getAttribute('role'), child_count: node.children.length });
      const facts = (node) => {
        const rect = node.getBoundingClientRect(), style = getComputedStyle(node);
        return { ...brief(node), aria: aria(node), tabindex: node.getAttribute('tabindex'),
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          style: { display: style.display, visibility: style.visibility, pointer_events: style.pointerEvents,
            overflow: style.overflow, overflow_x: style.overflowX, overflow_y: style.overflowY,
            clip: style.clip, clip_path: style.clipPath, transform: style.transform, opacity: style.opacity },
          children: Array.from(node.children).map(brief) };
      };
      const ancestors = (node) => { const result = []; for (let count = 0; node && count < 6; count++, node = parentOf(node)) result.push(facts(node)); return result; };
      const all = []; let openShadowRoots = 0;
      const visit = (root) => { for (const node of root.querySelectorAll('*')) { all.push(node); if (node.shadowRoot) { openShadowRoots++; visit(node.shadowRoot); } } };
      visit(document);
      const underSemantics = (node) => { for (let item = node; item; item = parentOf(item)) if (item.tagName.includes('SEMANTICS')) return true; return false; };
      const semantics = all.filter(underSemantics);
      const editors = all.filter((node) => ['INPUT', 'TEXTAREA'].includes(node.tagName) || node.hasAttribute('contenteditable'));
      const focus = []; let focused = document.activeElement;
      while (focused) { focus.push({ ...facts(focused), type: focused.getAttribute('type'), disabled: focused.disabled ?? null, read_only: focused.readOnly ?? null }); focused = focused.shadowRoot?.activeElement; }
      const points = [{ x: 450, y: 205 }, { x: 450, y: 268 }, { x: 450, y: 355 }, { x: 640, y: 445 }];
      return { semantic_node_count: semantics.length, editor_count: editors.length, open_shadow_root_count: openShadowRoots,
        nodes: semantics.map((node) => ({ ...facts(node), ancestors: ancestors(parentOf(node)) })),
        editors: editors.map((node) => ({ ...facts(node), type: node.getAttribute('type'), disabled: node.disabled ?? null, read_only: node.readOnly ?? null })),
        focus_chain: focus,
        observed_safe_form_points: points.map((point) => ({ ...point, hits: document.elementsFromPoint(point.x, point.y).slice(0, 8).map((node) => ancestors(node)) })) };
    });
    const before = await collect();
    await page.keyboard.press('Tab'); await page.waitForTimeout(200);
    const after = await collect();
    const file = path.join(output, `web-assets-${evidenceTag}-semantics-${reason}.json`);
    try { await fs.copyFile(file, file.replace('.json', `-previous-${Date.now()}.json`), require('node:fs').constants.COPYFILE_EXCL); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await fs.writeFile(file, JSON.stringify({ phase, reason, build_directory: buildDirectory, main_js_sha256: result.actual_main_js_sha256, before_tab: before, after_tab: after }, null, 2));
    result.semantics_diagnostics ??= [];
    result.semantics_diagnostics.push({ file, reason, before_nodes: before.semantic_node_count, after_nodes: after.semantic_node_count,
      before_editors: before.editor_count, after_editors: after.editor_count,
      before_focus: before.focus_chain.map((node) => ({ tag: node.tag, role: node.role, type: node.type })),
      after_focus: after.focus_chain.map((node) => ({ tag: node.tag, role: node.role, type: node.type })) });
  };
  const verifySignedOutControls = async () => {
    step = 'verify-immediate-signed-out-controls';
    const username = page.getByRole('textbox', { name: '用户名', exact: true, disabled: false });
    const password = page.getByRole('textbox', { name: '密码', exact: true, disabled: false });
    await username.waitFor({ state: 'visible' }); await password.waitFor({ state: 'visible' });
    await page.getByRole('button', { name: '登录', exact: true, disabled: false }).waitFor({ state: 'visible' });
    if (await page.getByRole('button', { name: '退出登录', exact: true }).count()) throw new Error('Old signed-in control remains');
    if (process.argv.includes('--diagnose-semantics') && !process.argv.includes('--public-input-with-diagnostics')) {
      result.checks.push('Signed-out controls strictly present; diagnostic cycle did not read or type field values');
      return;
    }
    await username.click(); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
    await page.keyboard.type('public_logout_probe_01');
    if (await username.inputValue() !== 'public_logout_probe_01') throw new Error('Public username text was not accepted');
    await page.keyboard.press('Tab');
    result.signed_out_tab_focus = await focusFacts();
    if (result.signed_out_tab_focus?.type !== 'password' || result.signed_out_tab_focus?.disabled !== false || result.signed_out_tab_focus?.read_only !== false) throw new Error('Keyboard Tab did not focus real editable password field');
    await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
    await page.keyboard.type('public_password_probe_01');
    if (await password.inputValue() !== 'public_password_probe_01') throw new Error('Public password probe was not accepted');
    sensitiveForm = false;
    await screenshot(evidenceTag + '-public-input');
    await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
    await page.keyboard.press('Shift+Tab'); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
    if (await username.inputValue() !== '' || await password.inputValue() !== '') throw new Error('Public probes were not cleared');
    result.checks.push('Signed-out username/password/login exposed; real Tab and public input accepted and cleared without submitting');
  };
  const input = fixture.inputs?.[phase] ?? {};

  page.on('pageerror', (error) => result.errors.push({ category: 'pageerror', class: error.name }));
  page.on('requestfailed', (request) => {
    const url = new URL(request.url());
    if (url.origin === apiOrigin) result.errors.push({ category: 'api_transport_failed', method: request.method(), error: request.failure()?.errorText?.replace(/[^A-Za-z0-9_:.-]/g, '').slice(0, 80) });
  });
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) result.errors.push({ category: /RenderFlex|overflow/.test(message.text()) ? 'layout' : 'console', type: message.type() });
  });
  page.on('request', (request) => {
    const url = new URL(request.url());
    if (url.origin !== apiOrigin || !['POST', 'PATCH', 'PUT', 'DELETE'].includes(request.method())
        || !/^\/api\/v1\/(sync\/push|assets\/groups|currencies\/)/.test(url.pathname)) return;
    try {
      const body = request.postData(), value = JSON.parse(body);
      const commands = url.pathname.endsWith('/sync/push') ? value.operations : [value];
      for (const command of commands) {
        if (!uuid(command.operation_id)) throw new Error('Invalid safe operation marker');
        const marker = { operation_id: command.operation_id, method: request.method(),
          category: command.entity_type || (url.pathname.includes('/groups') ? 'group' : url.pathname.includes('/rates') ? 'rate' : 'preference'), wire_sha256: hash(body) };
        if (command.entity_id != null) { if (!uuid(command.entity_id)) throw new Error('Invalid safe entity marker'); marker.entity_id = command.entity_id; }
        if (command.payload?.bill_type) marker.bill_type = command.payload.bill_type;
        // Only exact synthetic monetary scalars; never auth headers or full bodies.
        for (const key of ['money', 'target_money', 'transfer_fx']) if (command.payload?.[key]) marker[key] = command.payload[key];
        if (command.group?.id) marker.group_id = command.group.id;
        if (command.rate?.id) marker.rate_id = command.rate.id;
        result.operations.push(marker);
      }
    } catch (_) { result.errors.push({ category: 'safe_marker_invalid' }); }
  });
  page.on('response', (response) => {
    const url = new URL(response.url());
    if (url.origin === webOrigin && /\.(?:ttf|otf|woff2?)$/.test(url.pathname)) {
      result.local_font_resources ??= [];
      const resource = { pathname: url.pathname, status: response.status(), from_service_worker: response.fromServiceWorker() };
      result.local_font_resources.push(resource);
      pending.push((async () => {
        const body = await response.body();
        resource.bytes = body.length; resource.sha256 = hash(body);
      })().catch(() => { resource.body_capture = 'unavailable'; }));
    }
    if (url.origin !== apiOrigin) return;
    const category = /^\/api\/v1\/auth\//.test(url.pathname) ? 'identity'
      : url.pathname.includes('/sync/') ? 'sync' : url.pathname.includes('/assets/') ? 'assets' : url.pathname.includes('/currencies/') ? 'currencies' : 'other';
    if (result.http.length < 250) result.http.push({ category, method: response.request().method(), status: response.status() });
    if (!url.pathname.endsWith('/sync/push') || response.status() !== 200) return;
    pending.push((async () => {
      const body = await response.json();
      for (const item of body.results || []) {
        if (!uuid(item.operation_id) || !['applied', 'conflict', 'rejected', 'blocked'].includes(item.status)) throw new Error('Invalid safe receipt');
        result.applied.push({ operation_id: item.operation_id, status: item.status, revision: item.revision, replayed: item.replayed });
      }
    })().catch(() => result.errors.push({ category: 'safe_receipt_invalid' })));
  });
  try {
    const fixedMain = page.waitForResponse((response) => new URL(response.url()).pathname === '/main.dart.js');
    await page.goto(webOrigin, { waitUntil: 'domcontentloaded', timeout: 15000 });
    const main = await fixedMain;
    result.actual_main_js_sha256 = hash(await main.body());
    result.main_from_service_worker = main.fromServiceWorker();
    result.effective_html_font_size = await page.evaluate(() => getComputedStyle(document.documentElement).fontSize);
    if (phase === 'font-narrow') result.large_text_validation = Math.abs(parseFloat(result.effective_html_font_size) - 28.8) < 0.05
      ? 'effective-html-scale-1.8' : 'requested-1.8-not-confirmed-effective';
    if (process.argv.includes('--observe-worker-update')) {
      step = 'observe-normal-service-worker-lifecycle';
      // Public browser lifecycle read only. Do not update/unregister workers,
      // send skipWaiting, clear caches, or change application storage.
      const deadline = Date.now() + 15000;
      do {
        result.service_workers = await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).map((registration) => ({
          installing: registration.installing?.state ?? null,
          waiting: registration.waiting?.state ?? null,
          active: registration.active?.state ?? null,
        })));
        if (result.service_workers.some((worker) => worker.waiting)) break;
        await page.waitForTimeout(250);
      } while (Date.now() < deadline);
      result.result = 'inspected';
      result.checks.push('Normal worker lifecycle observed without application writes; browser will close normally');
      return;
    }
    if (main.status() !== 200 || result.actual_main_js_sha256 !== result.main_js_sha256) throw new Error('Wrong fixed normal-main build');
    if (buildDirectory === 'web-p4') {
      await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 15000 });
      await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
    }
    // The semantics candidate owns its lifecycle. Wait for a real production
    // control; do not synthesize DOM nodes or invoke private Flutter functions.
    await page.getByRole('button', { name: '设置', exact: true }).waitFor({ state: 'visible', timeout: 30000 });
    result.checks.push('Actual Chrome received fixed normal P4 main');
    if (phase === 'login') {
      await click('设置');
      if (process.argv.includes('--inspect-controls')) {
        result.form_labels = await page.getByRole('textbox').evaluateAll((nodes) => nodes.map((node) => ({ tag: node.tagName, label: node.getAttribute('aria-label') })));
        result.native_controls = await page.locator('input,textarea').evaluateAll((nodes) => nodes.map((node) => ({ tag: node.tagName, type: node.getAttribute('type'), role: node.getAttribute('role'), label: node.getAttribute('aria-label'), placeholder: node.getAttribute('placeholder'), read_only: node.readOnly, disabled: node.disabled, rect: { width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height } })));
        result.safe_button_labels = (await page.getByRole('button').allTextContents()).map(safe);
        await screenshot('login-controls'); result.result = 'inspected';
        result.checks.push('Read-only settings control labels inspected; no login submitted');
        return;
      }
      if (!process.argv.includes('--reopen-current-address')) {
        await field('服务器地址', apiOrigin); await click('保存地址');
      }
      await click('登录账号 邀请码注册、登录和会话管理');
      if (process.argv.includes('--inspect-login-controls')) {
        await page.waitForTimeout(12000);
        result.form_labels = await page.getByRole('textbox').evaluateAll((nodes) => nodes.map((node) => ({ tag: node.tagName, label: node.getAttribute('aria-label') })));
        result.native_controls = await page.locator('input,textarea').evaluateAll((nodes) => nodes.map((node) => ({ tag: node.tagName, type: node.getAttribute('type'), role: node.getAttribute('role'), label: node.getAttribute('aria-label'), read_only: node.readOnly, disabled: node.disabled, rect: { width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height } })));
        result.safe_aria = await aria();
        await screenshot('login-form-controls'); result.result = 'inspected';
        result.checks.push('Read-only sign-in form inspected before any credential entry');
        return;
      }
      sensitiveForm = true;
      await page.getByRole('heading', { name: '账号与设备', exact: true }).waitFor({ state: 'visible' });
      // Initialization delay is not evidence of an enabled or successful form.
      if (process.argv.includes('--public-input-probe')) await page.waitForTimeout(12000);
      if (process.argv.includes('--public-input-probe')) {
        const probeSuffix = buildDirectory === 'web-p4' ? '' : '-' + buildDirectory;
        step = 'type-public-focus-probe';
        await page.mouse.click(450, 205);
        result.public_probe_dom = await page.evaluate(() => {
          const facts = (node) => {
            const rect = node.getBoundingClientRect();
            return { tag: node.tagName, role: node.getAttribute('role'), disabled: node.disabled ?? null,
              read_only: node.readOnly ?? null, contenteditable: node.getAttribute('contenteditable'),
              rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
          };
          const focus_chain = [];
          let focused = document.activeElement;
          while (focused) { focus_chain.push(facts(focused)); focused = focused.shadowRoot?.activeElement; }
          const controls = [];
          const visit = (root) => {
            for (const node of root.querySelectorAll('input,textarea,[contenteditable]')) controls.push(facts(node));
            for (const node of root.querySelectorAll('*')) if (node.shadowRoot) visit(node.shadowRoot);
          };
          visit(document);
          return { focus_chain, controls };
        });
        await page.keyboard.type('focus_probe_01');
        await page.waitForTimeout(200);
        await page.screenshot({ path: path.join(output, `web-assets-login-public-probe-type${probeSuffix}.png`) });
        await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
        step = 'insert-public-focus-probe';
        await page.keyboard.insertText('focus_probe_01');
        await page.waitForTimeout(200);
        await page.screenshot({ path: path.join(output, `web-assets-login-public-probe-insert${probeSuffix}.png`) });
        result.result = 'inspected';
        result.checks.push('Public keyboard type and insertText inspected; no credential input or login submission');
        return;
      } else {
      const usernameControl = page.getByRole('textbox', { name: '用户名', exact: true });
      if (buildDirectory !== 'web-p4' || await usernameControl.count() && await usernameControl.isEnabled()) {
        credentialsEntered = true;
        await field('用户名', account.username);
        await page.keyboard.press('Tab'); result.login_tab_focus = await focusFacts();
        if (result.login_tab_focus?.type !== 'password' || result.login_tab_focus?.disabled !== false || result.login_tab_focus?.read_only !== false) throw new Error('Real login Tab did not focus editable password');
        await page.keyboard.type(account.password);
        result.checks.push('Real login Tab focused editable password; credentials excluded from artifacts');
      } else {
        // Human-authorized continuation of the separately recorded P6 gap.
        // Coordinates come from the actually inspected 1280x900 empty form
        // screenshot, not an inferred target. Real native focus and typing only.
        if (result.viewport.width !== 1280 || result.viewport.height !== 900) throw new Error('Different observed login viewport');
        result.accessibility_gaps = ['Visible login form missing semantic controls; visual path used observed caret and physical keyboard'];
        await page.screenshot({ path: path.join(output, 'web-assets-login-before-observed-focus.png'), mask: [page.locator('input,textarea')] });
        step = 'type-observed-username';
        await page.mouse.click(450, 205);
        await page.screenshot({ path: path.join(output, 'web-assets-login-after-observed-focus.png'), mask: [page.locator('input,textarea')] });
        credentialsEntered = true;
        await page.keyboard.type(account.username);
        step = 'type-observed-password';
        await page.mouse.click(450, 292);
        await page.keyboard.type(account.password);
        result.checks.push('Credentials physically typed in observed visible form; values excluded from artifacts');
      }
      }
      if (await page.getByRole('button', { name: '登录', exact: true, disabled: false }).count()) await click('登录');
      else { step = 'click-observed-login'; result.accessibility_gaps ??= []; result.accessibility_gaps.push('Visible login button lacks semantic node'); await page.mouse.click(640, 382); }
      await terms('real-cookie-csrf-login', ['已连接 · 此账号资料独立保存'], 20000);
    } else if (phase === 'logout-form-only') {
      await page.getByRole('button', { name: '登录', exact: true }).waitFor({ state: 'visible' });
      await click('设置'); await click('登录账号 邀请码注册、登录和会话管理');
      if (process.argv.includes('--diagnose-semantics')) await diagnoseSemantics('fresh-signed-out');
      await verifySignedOutControls();
    } else if (phase === 'logout-reopen') {
      await page.getByRole('button', { name: '登录', exact: true }).waitFor({ state: 'visible' });
      await click('设置'); await click('登录账号 邀请码注册、登录和会话管理');
      await page.getByRole('textbox', { name: '用户名', exact: true }).waitFor({ state: 'visible' });
      if (await page.getByRole('button', { name: '退出登录', exact: true }).count()) throw new Error('Old logged-in controls returned');
      result.checks.push('New Chrome process reopens persisted logged-out session');
    } else if (phase === 'logout') {
      await click('设置'); await click(account.username + ' 账号、可访问账本与登录设备');
      await click('退出登录'); await click('确认');
      await terms('real-ui-logout', ['已退出并撤销此设备会话。']);
      await verifySignedOutControls();
      if (process.argv.includes('--diagnose-semantics')) await diagnoseSemantics('immediate-logout-success');
    } else if (phase === 'sync') {
      await click('打开导航菜单'); await click(/^同步与恢复 · [0-9]+项待处理$/); await click('立即同步');
      await terms('real-ui-sync', ['已与服务器同步。'], 25000);
      await page.getByRole('button', { name: '立即同步', exact: true, disabled: false }).waitFor({ state: 'visible' });
    } else {
      await selectBook(); await assets();
      if (phase === 'inspect') { result.checks.push('Read-only assets route inspected'); }
      else if (['overview', 'overview-narrow', 'verify-reopen', 'font-verify', 'font-narrow'].includes(phase)) { await expectPhase(); }
      else if (phase === 'configuration-feedback') {
        await menu('币种与手动估值'); await refreshConfiguration();
        await terms('strict-live-configuration-feedback', ['配置已刷新。', '使用估值日或之前最新报价', 'EUR → CNY 9']);
        result.checks.push('Read-only refresh exposes real confirmation text in accessible tree');
      }
      else if (phase === 'money-privacy') {
        await click('隐藏金额');
        await terms('hidden-money-ui', ['••••']);
        const tree = await aria();
        for (const amount of fixture.expected?.visible_money || []) if (tree.includes(amount)) throw new Error('Hidden exact balance remains accessible');
        await screenshot('money-hidden'); await click('显示金额'); await expectPhase();
      } else if (phase === 'group-create') {
        await menu('账户分组'); await click('联网刷新');
        await terms('configuration-confirmed', ['配置已刷新。'], 25000);
        await click('添加分组'); await field('分组名称', required(fixture.names, 'ui_group'));
        await field('排序', required(input, 'sort_order'));
        await mutate('save-group', async () => { await click('保存并确认'); await expectPhase(); });
      } else if (phase === 'account-create') {
        await click('添加资金账户'); await field('账户名称', required(fixture.names, 'ui_credit'));
        await dropdown('类型', '信用卡'); await click(/^银行 /);
        await field('搜索银行名称', '招商'); await click('招商银行');
        await field('期初余额', required(input, 'opening'));
        await field('信用额度（可单独设置，选填）', required(input, 'limit'));
        await field('每月出账日（选填）', required(input, 'statement_day'));
        await dropdown('还款日规则', '每月固定日期'); await field('每月还款日', required(input, 'due_day'));
        await mutate('save-credit', async () => { await click('保存到本机并待同步'); await expectPhase(); });
      } else if (phase === 'account-metadata') {
        const accountName = required(fixture.names, required(input, 'account_name_key'));
        await actionMenu(accountName, '编辑账户');
        await dropdown('分组（联网确认后可用）', required(fixture.names, 'ui_group'));
        await field('排序（较小的在前）', required(input, 'sort_order'));
        const control = page.getByRole('switch', { name: /^隐藏账户/ });
        if (!await control.isChecked()) await control.click();
        await mutate('save-metadata', async () => { await click('保存到本机并待同步');
          await menu('显示已隐藏账户'); await expectPhase(); });
        await actionMenu(accountName, '编辑账户');
        const order = page.getByRole('textbox', { name: '排序（较小的在前）', exact: true });
        await order.click();
        if (await order.inputValue() !== input.sort_order) throw new Error('Local account sort order was not retained');
        result.checks.push('Reopened metadata retains exact explicit sort order');
      } else if (phase.startsWith('fund-')) {
        const labels = { 'fund-repayment': '信用卡还款', 'fund-borrow': '借入本金', 'fund-lend': '借出本金',
          'fund-collect': '收回本金', 'fund-repay': '偿还本金', 'fund-fx': '转账' };
        await menu('显示已隐藏账户');
        if (phase === 'fund-fx' && input.amount !== '100') throw new Error('FX acceptance requires exact100 CNY principal');
        await actionMenu(required(fixture.names, required(input, 'account_name_key')), labels[phase]);
        await click(required(fixture.names, 'book'));
        await field('备注', required(input, 'note'));
        await dropdown('转出账户', required(fixture.names, required(input, 'from_name_key')));
        await dropdown('转入账户', required(fixture.names, required(input, 'to_name_key')));
        if (phase === 'fund-fx') {
          await field('跨币种到账金额（同币种留空）', '12.50'); await field('1 CNY 折合多少 EUR', '0.125');
          await dropdown('手续费账户（默认转出账户）', required(fixture.names, 'fee_account'));
          await field('手续费 (CNY)', required(input, 'fee'));
        }
        for (const key of required(input, 'amount')) await click(key);
        await mutate('save-funds', async () => { await click('保存'); await expectPhase(); });
      } else if (phase === 'currency-preferences') {
        await menu('币种与手动估值'); await click('联网刷新'); await terms('configuration-confirmed', ['配置已刷新。']);
        await dropdown('估值汇率日期规则', '使用估值日或之前最新报价');
        await mutate('save-preferences', async () => { await click('保存币种与估值偏好'); await expectPhase(); });
      } else if (phase === 'rate-create' || phase === 'rate-replace') {
        await menu('币种与手动估值'); await refreshConfiguration();
        await terms('persisted-valuation-policy', ['使用估值日或之前最新报价']);
        if (!readOnlyValuation && phase === 'rate-replace') {
          const previous = page.getByRole('group', { name: new RegExp('^' + escaped(required(input, 'previous_row'))) });
          await previous.getByRole('button', { name: '删除报价', exact: true }).click();
          await mutate('delete-old-quote', async () => {
            const deleted = page.waitForResponse((response) => new URL(response.url()).origin === apiOrigin
              && new URL(response.url()).pathname.startsWith('/api/v1/currencies/rates/')
              && response.request().method() === 'DELETE');
            await click('删除');
            if ((await deleted).status() !== 200) throw new Error('Exact old quote deletion was not confirmed');
            await previous.waitFor({ state: 'detached' });
            result.checks.push('Exact previous quote disappears after corresponding DELETE200');
          });
        }
        if (!readOnlyValuation) {
          await click('添加手动估值报价');
          await dropdown('来源币种', required(input, 'from_label')); await dropdown('目标币种', required(input, 'to_label'));
          await field('1来源币 = 目标币金额', required(input, 'rate')); await field('生效日期（YYYY-MM-DD）', required(input, 'date'));
          await field('来源或备注', required(input, 'source'));
          await mutate('save-quote', async () => { await click('保存并确认'); await expectPhase(); });
          await refreshConfiguration();
        } else await expectPhase();
        await click('返回');
        await terms(phase === 'rate-create' ? 'exact-valuation-at8' : 'exact-valuation-at9',
          fixture.expected[phase === 'rate-create' ? 'valuation_at_8' : 'valuation_at_9']);
      } else if (phase === 'read-details' || phase === 'read-credit') {
        await menu('显示已隐藏账户');
        await openAccount(required(fixture.names, phase === 'read-credit' ? 'credit' : 'cash'));
        if (phase === 'read-credit') await click('信用卡账期');
        await refreshRead(); await expectPhase();
      } else if (phase === 'read-history') {
        await menu('资产趋势'); await refreshRead(); await expectPhase();
      } else throw new Error('Unimplemented fixed phase');
    }
    await Promise.allSettled(pending);
    if (result.errors.some((error) => ['pageerror', 'layout', 'safe_marker_invalid', 'safe_receipt_invalid'].includes(error.category))) throw new Error('Actual browser runtime/layout failure');
    await screenshot(); result.result = 'passed';
  } catch (error) {
    result.result = 'failed'; result.failed_step = step; result.error_class = error.name;
    result.error_category = /strict mode/.test(error.message) ? 'ambiguous_semantics'
      : /Timeout/.test(error.message) ? 'ui_timeout' : 'assertion_or_runtime';
    if (process.argv.includes('--diagnose-semantics') && phase === 'logout' && result.checks.includes('real-ui-logout')) {
      try { await diagnoseSemantics('immediate-logout-failure'); }
      catch (_) { result.errors.push({ category: 'safe_semantics_diagnostic_failed' }); }
    }
    if (!credentialsEntered) sensitiveForm = false;
    await screenshot(evidenceTag + '-failure').catch(() => {}); process.exitCode = 1;
  } finally {
    await Promise.allSettled(pending);
    if (!phase.startsWith('login')) {
      try { await fs.writeFile(path.join(output, `web-assets-${evidenceTag}-aria.txt`), await aria()); } catch (_) {}
    }
    await context.close(); result.closed_at = new Date().toISOString();
    await fs.writeFile(receiptPath, JSON.stringify(result, null, 2));
    // Only safe metadata, no DOM tree, credential values or raw exception body.
    console.log(JSON.stringify(result));
  }
}
main().catch(() => { console.error('Dedicated P4 setup failed; no credentials logged'); process.exitCode = 1; });
