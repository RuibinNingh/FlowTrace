// Starts installed Chrome with a new workspace-only profile. Never attaches to
// an existing browser or uses a personal user-data directory.
'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../../..');
const profileRoot = path.join(root, 'work/flowtrace-dev/browser-profiles');
const outputRoot = path.join(root, 'outputs/validation/P3');
const executablePath = 'C:/Program Files/Google/Chrome/Application/chrome.exe';

async function main() {
  const runId = randomUUID();
  const profile = path.join(profileRoot, `chrome-p3-${runId}`);
  const receiptPath = path.join(outputRoot, 'chrome-session.json');
  const stopPath = path.join(outputRoot, `chrome-stop-${runId}`);
  await fs.mkdir(outputRoot, { recursive: true });
  await fs.mkdir(profileRoot, { recursive: true });
  // mkdir without recursive confirms a fresh UUID directory before launch.
  await fs.mkdir(profile);
  const receipt = {
    run_id: runId,
    started_at: new Date().toISOString(),
    tool: 'Playwright',
    playwright_version: require('playwright/package.json').version,
    executable: executablePath,
    profile,
    headed: true,
    reused_personal_profile: false,
    attached_to_existing_browser: false,
    url: 'about:blank',
    phase: 'launching',
    stop_file: stopPath,
  };
  await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2));
  let context;
  try {
    context = await chromium.launchPersistentContext(profile, {
      executablePath,
      headless: false,
      viewport: { width: 1280, height: 900 },
      locale: 'zh-CN',
      timeout: 20000,
      acceptDownloads: true,
    });
    const pages = context.pages();
    if (pages.length !== 1 || pages[0].url() !== 'about:blank') {
      throw new Error('Fresh browser did not contain exactly one blank page');
    }
    receipt.browser_version = context.browser().version();
    receipt.phase = 'running';
    await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2));
    console.log('Dedicated headed Chrome started; safe receipt: outputs/validation/P3/chrome-session.json');
    // The host may collect only this profile's process metadata, then create
    // stop_file. A fixed cap prevents a forgotten fixture browser persisting.
    const expires = Date.now() + 45000;
    while (Date.now() < expires) {
      try {
        await fs.access(stopPath);
        break;
      } catch (_) {
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }
    receipt.phase = 'passed';
  } catch (error) {
    receipt.phase = 'failed';
    receipt.error = String(error.message).slice(0, 300);
    throw error;
  } finally {
    if (context) await context.close();
    receipt.closed_at = new Date().toISOString();
    await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2));
  }
}

main().catch(() => {
  console.error('Dedicated Chrome smoke failed; inspect safe receipt');
  process.exitCode = 1;
});
