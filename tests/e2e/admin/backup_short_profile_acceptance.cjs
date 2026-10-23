'use strict';
// One normal UI download attempt in a fresh short owned profile. No proxy,
// external download manager, browser policy or user profile is changed.
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const {randomUUID,createHash}=require('node:crypto');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'../../..');
const fixturePath=path.resolve(process.argv[process.argv.indexOf('--fixture')+1]);
const id=randomUUID(),output=path.join(path.dirname(fixturePath),'backup-short-profile-'+id),profile=path.join(root,'work/browser-probes',id);
let context,page;
const receipt={kind:'single-native-backup-zip-short-profile-cross-check',run_id:id,headed:true,personal_profile:false,profile,phase:'starting',responses:[],failures:[],download_event:false};
const read=async p=>JSON.parse((await fs.readFile(p,'utf8')).replace(/^\uFEFF/,''));
async function save(){await fs.writeFile(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2));}
async function main(){
 if(!fixturePath.startsWith(path.join(root,'outputs/validation/P5/admin')+path.sep))throw new Error('Unexpected fixture');
 const fixture=await read(fixturePath),credentials=await read(fixture.credentials_path);
 await fs.mkdir(output);await fs.mkdir(profile,{recursive:true});
 context=await chromium.launchPersistentContext(profile,{executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:false,acceptDownloads:true,downloadsPath:path.join(output,'downloads'),viewport:{width:1280,height:900}});
 receipt.browser=context.browser().version();page=context.pages()[0];page.setDefaultTimeout(20000);
 await page.goto(fixture.origin+'/admin/login');await page.getByLabel('管理员账号',{exact:true}).fill(credentials.recovery.username);await page.getByLabel('密码',{exact:true}).fill(credentials.recovery.password);await page.getByRole('button',{name:'登录后台',exact:true}).click();await page.getByRole('heading',{name:'服务概况',exact:true}).waitFor();
 const url=fixture.origin+'/admin/backups/'+fixture.backup_id+'/download';
 await page.goto(url);await page.locator('[name=current_password]').fill(credentials.recovery.password);await page.locator('[name=confirm_target]').check();
 page.on('response',async r=>{if(r.request().method()!=='POST'||r.url()!==url)return;const headers=await r.allHeaders();receipt.responses.push({status:r.status(),headers:Object.fromEntries(['content-type','content-disposition','content-length','x-flowtrace-archive-sha256'].filter(k=>k in headers).map(k=>[k,headers[k]]))});});
 page.on('requestfailed',r=>{if(r.method()==='POST'&&r.url()===url)receipt.failures.push({error:r.failure()?.errorText});});
 receipt.phase='normal-ui-submit';await save();
 const downloadPromise=page.waitForEvent('download',{timeout:15000}).catch(()=>null);
 await page.getByRole('button',{name:'验证并下载',exact:true}).click();
 const download=await downloadPromise;
 if(download){receipt.download_event=true;receipt.suggested_filename=download.suggestedFilename();receipt.download_failure=await download.failure();assert.equal(receipt.download_failure,null);const local=path.join(output,'native-backup.zip');await download.saveAs(local);const bytes=await fs.readFile(local);receipt.bytes=bytes.length;receipt.sha256=createHash('sha256').update(bytes).digest('hex');receipt.phase='native-file-received-needs-independent-package-verification';}
 else receipt.phase='native-download-unpassed-no-event';
 await save();await page.goto(fixture.origin+'/admin/overview');await page.getByRole('button',{name:'退出登录',exact:true}).click();await page.getByRole('heading',{name:'流迹管理',exact:true}).waitFor();console.log(JSON.stringify({receipt:path.join(output,'receipt.json'),phase:receipt.phase,download_event:receipt.download_event}));
}
main().catch(async e=>{receipt.phase='failed';receipt.failure={name:e.name};await save();console.error('FAILED '+e.name);process.exitCode=1;}).finally(async()=>{if(context)await context.close();});
