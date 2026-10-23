'use strict';
// Isolated Chrome + UUID database; no application account or personal profile.
const { chromium } = require('playwright');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

async function main() {
  const root = path.resolve(__dirname, '../../..');
  const run = randomUUID();
  const profile = path.join(root, 'work/flowtrace-dev/browser-profiles', `chrome-probe-${run}`);
  await fs.mkdir(profile, { recursive: true });
  const receipt = { run, profile, isolated: true, raw_nested_baseline: process.argv[2] === 'baseline', phases: [] };
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: false, viewport: { width: 1100, height: 700 },
  });
  try {
    receipt.browser = context.browser().version();
    const modes = process.argv[2] === 'baseline' ? ['nested', 'save', 'watch'] : ['save', 'watch', 'rollback', 'conflict'];
    for (const mode of modes) {
      const page = await context.newPage();
      const result = { mode, errors: [] };
      page.on('pageerror', (e) => result.errors.push(String(e)));
      await page.goto(`http://127.0.0.1:18184/?run=${run}-${mode}&mode=${mode}`, { waitUntil: 'load' });
      try {
        await page.waitForFunction(() => document.body.textContent.includes('"passed"') || document.body.textContent.includes('"error:'), null, { timeout: 7000 });
      } catch (_) { result.timeout = true; }
      result.events = await page.locator('body').innerText();
      if (!result.timeout && result.events.includes('"passed"') && mode !== 'nested') {
        await page.goto(`http://127.0.0.1:18184/?run=${run}-${mode}&mode=reopen`, { waitUntil: 'load' });
        try {
          await page.waitForFunction(() => document.body.textContent.includes('"passed"') || document.body.textContent.includes('"error:'), null, { timeout: 7000 });
        } catch (_) { result.reopen_timeout = true; }
        result.reopen_events = await page.locator('body').innerText();
      }
      receipt.phases.push(result);
      await page.close();
    }
  } finally {
    await context.close();
    await fs.writeFile(path.join(root, 'outputs/validation/P3', `web-transaction-probe-${run}.json`), JSON.stringify(receipt, null, 2));
  }
  const passed = receipt.phases.every((p) => !p.timeout && !p.reopen_timeout && p.errors.length === 0 && p.events.includes('"passed"') && p.reopen_events?.includes('"passed"'));
  if (!receipt.raw_nested_baseline && !passed) process.exitCode = 1;
  console.log(JSON.stringify(receipt));
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
