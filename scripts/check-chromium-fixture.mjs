import {spawn} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import http from 'node:http';
import path from 'node:path';
// Optional native format check; every browser launch uses this synthetic .build profile.
// No real Claude/Chrome profile, credentials or application processes are used.
process.chdir(path.dirname(path.dirname(fileURLToPath(import.meta.url))));
async function run(command,args,env=process.env) {
 const processHandle=spawn(command,args,{stdio:'inherit',env});
 await new Promise((resolve,reject)=>{processHandle.once('error',reject);processHandle.once('exit',code=>code===0?resolve():reject(Error('Fixture command failed: '+code)));});
}
if(!process.argv.includes('--seed')&&!process.argv.includes('--verify')) {
 await run(process.execPath,[fileURLToPath(import.meta.url),'--seed']);
 for(let round=0;round<2;round++) {
  await run('swift',['test','--filter','LevelDBSnapshotTests'],{...process.env,CLAUDE_SWITCH_CHROMIUM_FIXTURE:'1'});
  await run(process.execPath,[fileURLToPath(import.meta.url),'--verify']);
 }
 process.exit(0);
}
const root=path.resolve('.build/chromium-continuity-fixture');
await mkdir(root,{recursive:true});
const server=http.createServer((q,r)=>{r.end('<!doctype html><title>Synthetic fixture</title>');});
await new Promise(r=>server.listen(18763,'127.0.0.1',r));
const child=spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',[
 '--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-sync','--disable-default-apps','--disable-extensions','--disable-features=OptimizationHints,MediaRouter','--metrics-recording-only','--remote-debugging-pipe',`--user-data-dir=${root}`,'--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1','about:blank'
],{stdio:['ignore','ignore','pipe','pipe','pipe']});
child.stderr.resume();
child.on('error',()=>{for(const call of pending.values()){clearTimeout(call.timer);call.reject(Error('Fixture Chrome could not start'));}pending.clear();});
let seq=0,buffer='',pending=new Map();
child.stdio[4].on('data',data=>{buffer+=data;let n;while((n=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,n));buffer=buffer.slice(n+1);if(msg.id){const call=pending.get(msg.id);pending.delete(msg.id);clearTimeout(call?.timer);msg.error?call?.reject(new Error(msg.error.message)):call?.resolve(msg.result);}}});
function command(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++seq;const timer=setTimeout(()=>{pending.delete(id);reject(Error('Fixture browser request timed out'));},30000);pending.set(id,{resolve,reject,timer});child.stdio[3].write(JSON.stringify({id,method,params,sessionId})+'\0');});}
try{
 const target=await command('Target.createTarget',{url:'http://127.0.0.1:18763'});
 const {sessionId}=await command('Target.attachToTarget',{targetId:target.targetId,flatten:true});
 await command('Page.enable',{},sessionId);
 let ready=false;
 for(let i=0;i<100&&!ready;i++) {const r=await command('Runtime.evaluate',{expression:'location.origin',returnByValue:true},sessionId);ready=r.result.value==='http://127.0.0.1:18763';if(!ready)await new Promise(r=>setTimeout(r,25));}
 if(!ready)throw Error('fixture page unavailable');
 if(process.argv.includes('--verify')){
  const {result}=await command('Runtime.evaluate',{expression:'JSON.stringify(Object.fromEntries(Object.entries(localStorage)))',returnByValue:true},sessionId);
  const state=JSON.parse(result.value);if(state['synthetic-target-auth']!=='target-only'||state['fixture-merged']!=='\u6d4b\u8bd5\ud83d\ude80'||state['fixture-deleted']!==undefined)throw Error('native reopen mismatch');
  console.log('PASS: Chromium reopened rebuilt fixture; target bytes, Unicode merge and deletion preserved.');
 }else{
  const {exceptionDetails}=await command('Runtime.evaluate',{expression:`localStorage.clear();localStorage.setItem('synthetic-target-auth','target-only');localStorage.setItem('fixture-unicode','\\u6d4b\\u8bd5\\ud83d\\ude80');for(let i=0;i<2000;i++)localStorage.setItem('bulk-'+i,'synthetic '.repeat(200));localStorage.setItem('fixture-deleted','obsolete');localStorage.removeItem('fixture-deleted');'done'`,returnByValue:true},sessionId);if(exceptionDetails)throw Error('fixture storage write failed');
  await command('DOMStorage.enable',{},sessionId);
  console.log('Synthetic Chromium fixture created.');
 }
}finally{await command('Browser.close').catch(()=>{});if(child.exitCode===null)await new Promise(r=>child.once('exit',r));server.close();}
