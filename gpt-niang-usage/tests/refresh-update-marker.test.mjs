import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {widgetUpdating,requestRefresh,readPendingRequests,completeRequests} from '../runtime/refresh-client.mjs';

function fixture(t){
  const dataDir=fs.mkdtempSync(path.join(os.tmpdir(),'niang-update-marker-'));
  t.after(()=>{assert.equal(fs.realpathSync(path.dirname(dataDir)),fs.realpathSync(os.tmpdir()));fs.rmSync(dataDir,{recursive:true,force:true});});
  const file=path.join(dataDir,'update-installing.json');
  return {dataDir,file,write:value=>fs.writeFileSync(file,JSON.stringify(value))};
}

async function expectStaleMarkerClears(dataDir){
  // A loaded CI runner can take longer than the production two-second process
  // probe deadline to start PowerShell. A failed probe safely reports UPDATING;
  // verify that a later successful probe unblocks the real request.
  const deadline=Date.now()+15000;
  do{
    if(!widgetUpdating(dataDir))return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }while(Date.now()<deadline);
  assert.fail('The stale marker stayed blocked after repeated bounded probes');
}

test('absent, malformed and dead update owners do not block quota work',t=>{
  const {dataDir,file,write}=fixture(t);
  assert.equal(widgetUpdating(dataDir),false);
  fs.writeFileSync(file,'{broken');assert.equal(widgetUpdating(dataDir),false);
  for(const pid of [0,-1,'12',null]){write({pid});assert.equal(widgetUpdating(dataDir),false);}
});

test('a reused Windows update PID cannot block a headless worker',{skip:process.platform!=='win32'},async t=>{
  const {dataDir,file,write}=fixture(t);
  write({pid:process.pid,startedAt:'2000-01-01T00:00:00.000Z',token:'stale'});
  const marker=fs.readFileSync(file,'utf8');await expectStaleMarkerClears(dataDir);
  let starts=0;
  const expected={ok:true,queryOk:true,windows:[]};
  const actual=await requestRefresh({dataDir},'unused',{timeoutMs:5000,startWorker:()=>{
    starts++;completeRequests(dataDir,readPendingRequests(dataDir),expected);
  }});
  assert.deepEqual(actual,expected);assert.equal(starts,1);
  assert.equal(fs.readFileSync(file,'utf8'),marker,'Readers must not delete or replace a concurrent update marker');
});

test('a matching live Windows update still blocks every worker start',{skip:process.platform!=='win32'},async t=>{
  const {dataDir,write}=fixture(t);
  const shell=path.join(process.env.WINDIR,'System32','WindowsPowerShell','v1.0','powershell.exe');
  const observation=spawnSync(shell,['-NoProfile','-NonInteractive','-Command',`(Get-Process -Id ${process.pid}).StartTime.ToUniversalTime().ToString('o')`],{windowsHide:true,encoding:'utf8',timeout:5000});
  assert.equal(observation.status,0,observation.stderr);
  const startedAt=observation.stdout.trim();assert.ok(Number.isFinite(Date.parse(startedAt)));
  write({pid:process.pid,startedAt:'2000-01-01T00:00:00.000Z',token:'earlier'});await expectStaleMarkerClears(dataDir);
  write({pid:process.pid,startedAt,token:'live'});assert.equal(widgetUpdating(dataDir),true);
  const snapshot=await requestRefresh({dataDir},'unused',{startWorker:()=>assert.fail('Live update started a worker')});
  assert.equal(snapshot.errorCode,'UPDATING');assert.equal(snapshot.retryable,true);
  write({pid:process.pid,startedAt:'invalid'});assert.equal(widgetUpdating(dataDir),false);
});

test('legacy live markers retain their existing update exclusion',t=>{
  const {dataDir,write}=fixture(t);write({pid:process.pid});assert.equal(widgetUpdating(dataDir),true);
});
