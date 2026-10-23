'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {chromium} = require('playwright');
const execute = promisify(execFile);
const root = path.resolve(__dirname, '../../..');
const index = process.argv.indexOf('--fixture');
if (index < 0) throw new Error('Pass --fixture');
const fixturePath = path.resolve(process.argv[index + 1]);
if (!fixturePath.startsWith(path.join(root, 'outputs/validation/P5/admin') + path.sep)) throw new Error('Unexpected fixture');
const capabilityOnly = process.argv.includes('--capability-only');
const runId = randomUUID();
const output = path.join(path.dirname(fixturePath), 'rehearsal-browser-' + runId);
const profile = path.join(root, 'work/browser-probes/' + runId);
const receipt = {run_id:runId, kind:capabilityOnly?'real-restore-unconfigured-registry':'real-restore-forms-production-cli-worker',
  headed:true,personal_profile:false,phase:'starting',checks:[],page_errors:[],console_issues:[],worker_invocations:0};
let context,page,fixture,credentials,secrets=[],previewUrl;
const read = async file => JSON.parse((await fs.readFile(file,'utf8')).replace(/^\uFEFF/,''));
const safe = value => secrets.reduce((text,item)=>text.split(item).join('[redacted]'),String(value));
async function save(){await fs.writeFile(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2));}
async function check(name,action){receipt.phase=name;await save();await action();receipt.checks.push({name,result:'passed'});await save();console.log('PASS '+name);}
async function screen(name){await page.screenshot({path:path.join(output,name+'.png'),mask:[page.locator('input[type=password]')]});await fs.writeFile(path.join(output,name+'-aria.txt'),safe(await page.locator('body').ariaSnapshot()));}
async function login(role){await page.goto(fixture.origin+'/admin/login');await page.getByLabel('管理员账号',{exact:true}).fill(credentials[role].username);await page.getByLabel('密码',{exact:true}).fill(credentials[role].password);await page.getByRole('button',{name:'登录后台',exact:true}).click();await page.getByRole('heading',{name:'服务概况',exact:true}).waitFor();}
async function logout(){await page.getByRole('button',{name:'退出登录',exact:true}).click();await page.getByRole('heading',{name:'流迹管理',exact:true}).waitFor();}
async function password(value){await page.locator('[name=current_password]').fill(value);}
async function main(){
 fixture=await read(fixturePath);assert.equal(fixture.purpose,'flowtrace-p5-restore-browser-synthetic');
 const privatePath=path.resolve(fixture.credentials_path);if(!privatePath.startsWith(path.join(root,'work/flowtrace-dev')+path.sep))throw new Error('Unexpected credentials');
 credentials=await read(privatePath);secrets=Object.values(credentials).flatMap(v=>typeof v==='string'?[v]:Object.values(v)).filter(v=>typeof v==='string'&&v.length>=8).sort((a,b)=>b.length-a.length);
 await fs.mkdir(output);await fs.mkdir(profile,{recursive:true});receipt.fixture=fixture.run_id;receipt.profile=profile;
 context=await chromium.launchPersistentContext(profile,{executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:false,locale:'zh-CN',viewport:{width:1280,height:900}});
 receipt.browser=context.browser().version();page=context.pages()[0];page.setDefaultTimeout(20000);
 page.on('pageerror',e=>receipt.page_errors.push({name:e.name,phase:receipt.phase}));
 page.on('console',m=>{if(!['error','warning'].includes(m.type()))return;const category=/Failed to load resource:.*(?:401|403|409|503)/.test(m.text())?'expected_rejected_http':m.location().url.endsWith('/favicon.ico')&&/404/.test(m.text())?'missing_favicon':'other';receipt.console_issues.push({type:m.type(),category,phase:receipt.phase,...(category==='other'?{message:safe(m.text())}:{})});});
 await login('owner');
 if(capabilityOnly){await check('unregistered-targets-have-no-execution-form',async()=>{await page.goto(fixture.origin+'/admin/restores');await page.getByText('部署未登记隔离恢复目标',{exact:false}).waitFor();assert.equal(await page.locator('form[action="/admin/restores/preview"]').count(),0);await screen('unregistered-targets');});}
 else{
 await check('ordinary-owner-form-reauthenticates-and-previews-real-empty-target-without-restoring',async()=>{
  await page.goto(fixture.origin+'/admin/backups');await page.getByRole('link',{name:'隔离恢复演练',exact:true}).click();
  await page.getByRole('heading',{name:'隔离恢复演练',exact:true}).waitFor();
  await page.getByLabel('备份UUID',{exact:true}).fill(fixture.backup_id);await password(credentials.wrong_password);
  await page.getByRole('button',{name:'校验并预览恢复',exact:true}).click();await page.getByRole('alert').filter({hasText:'当前管理密码验证失败'}).waitFor();assert.equal(await page.locator('[name=current_password]').inputValue(),'');
  await page.getByLabel('备份UUID',{exact:true}).fill(fixture.backup_id);await password(credentials.owner.password);
  await page.getByRole('button',{name:'校验并预览恢复',exact:true}).click();await page.getByRole('heading',{name:'确认隔离恢复',exact:true}).waitFor();
  previewUrl=page.url();receipt.preview_id=previewUrl.split('/').pop();
  assert.match(await page.locator('main').innerText(),/撤销.*全部会话/);assert.match(await page.locator('main').innerText(),/每个目标仅允许一个恢复意图/);
  await screen('preview-confirm-desktop');
  const result=await execute(path.join(root,'server/.venv/Scripts/python.exe'),[path.join(root,'tests/e2e/admin/validate_rehearsal_browser.py'),'--fixture',fixturePath,'--phase','preview'],{cwd:root,windowsHide:true,timeout:15000});assert.equal(JSON.parse(result.stdout.trim()).preview_did_not_restore,true);
 });
 await check('keyboard-narrow-confirmation-enqueues-and-independent-production-cli-restores',async()=>{
  await page.setViewportSize({width:390,height:844});await page.emulateMedia({reducedMotion:'reduce'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
  await page.locator('[name=current_password]').focus();await page.keyboard.press('Tab');assert.equal(await page.locator('[name=confirm_target]').evaluate(e=>e===document.activeElement),true);await screen('restore-confirm-narrow');
  await password(credentials.owner.password);await page.locator('[name=confirm_target]').check();await page.getByRole('button',{name:'确认排队恢复',exact:true}).click();await page.getByRole('heading',{name:'隔离恢复任务',exact:true}).waitFor();
  receipt.job_id=page.url().split('/').pop();assert.match(receipt.job_id,/^[0-9a-f-]{36}$/);await page.getByText('待执行',{exact:true}).waitFor();await save();
  const result=await execute(path.join(root,'server/.venv/Scripts/python.exe'),[path.join(root,'tests/e2e/admin/worker_once.py'),'--env-file',fixture.env_file,'--restore-fixture',fixturePath],{cwd:root,timeout:180000,windowsHide:true,maxBuffer:65536});receipt.worker_invocations++;assert.deepEqual(JSON.parse(result.stdout.trim()),{worked:true});assert.equal(result.stderr.trim(),'');
  await page.getByRole('link',{name:'刷新状态',exact:true}).click();await page.getByText('已完成',{exact:true}).waitFor();await page.getByText('restore_rehearsal_verified',{exact:true}).waitFor();await screen('restore-completed-narrow');
 });
 await check('same-preview-requires-current-password-and-finds-original-consumed-intent',async()=>{
  await page.goto(previewUrl);await password(credentials.wrong_password);await page.locator('[name=confirm_target]').check();await page.getByRole('button',{name:'确认排队恢复',exact:true}).click();await page.getByRole('alert').filter({hasText:'当前管理密码验证失败'}).waitFor();
  await password(credentials.owner.password);await page.locator('[name=confirm_target]').check();await page.getByRole('button',{name:'确认排队恢复',exact:true}).click();assert.equal(page.url().split('/').pop(),receipt.job_id);await page.getByText('已完成',{exact:true}).waitFor();
  await page.goto(fixture.origin+'/admin/restores');assert.equal(await page.getByRole('button',{name:'校验并预览恢复',exact:true}).count(),0);const link=page.getByRole('link',{name:'查看原恢复任务',exact:true});assert.equal(await link.getAttribute('href'),'/admin/restores/jobs/'+receipt.job_id);await screen('consumed-target-original-job');
 });
 await check('service-and-owner-without-recovery-refused-recovery-only-can-read-status',async()=>{
  await logout();for(const role of ['service','owner_without_recovery']){await login(role);const denied=await page.goto(fixture.origin+'/admin/restores');assert.equal(denied.status(),403);await page.goto(fixture.origin+'/admin/overview');await logout();}
  await login('recovery');await page.goto(fixture.origin+'/admin/restores');await page.getByRole('link',{name:'查看原恢复任务',exact:true}).click();await page.getByText('已完成',{exact:true}).waitFor();assert.equal((await page.goto(fixture.origin+'/admin/configuration')).status(),403);await page.goto(fixture.origin+'/admin/overview');await screen('recovery-only-status-role');
 });}
 await logout();assert.deepEqual(receipt.page_errors,[]);assert.deepEqual(receipt.console_issues.filter(i=>i.category==='other'),[]);receipt.phase='passed';receipt.summary={passed:receipt.checks.length,production_worker_cli_invocations:receipt.worker_invocations};await save();
}
main().catch(async e=>{receipt.phase='failed';receipt.failure={name:e.name,message:safe(e.message)};await save();console.error('FAILED '+safe(e.message));process.exitCode=1;}).finally(async()=>{if(context)await context.close();});
