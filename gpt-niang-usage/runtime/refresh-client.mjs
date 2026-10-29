import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {atomicJson} from './usage.mjs';
import {healthyWorker,readJson,processAlive} from './worker-state.mjs';
import {requestPipeRefresh} from './worker-ipc.mjs';

const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let staleUpdateMarker=null;
export function widgetUpdating(dataDir) {
  const update=readJson(path.join(dataDir,'update-installing.json'));
  if(!processAlive(update?.pid))return false;
  // Windows installer markers record process creation time. A live recycled PID
  // is not the installer; never unlink here, since a new update may replace it.
  if(process.platform==='win32' && update.startedAt){
    const expected=Date.parse(update.startedAt);
    if(!Number.isFinite(expected))return false;
    const key=JSON.stringify([path.resolve(dataDir),update.pid,update.startedAt,update.token]);
    if(staleUpdateMarker===key)return false;
    const shell=path.join(process.env.WINDIR || 'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
    const command=`try{$p=[Diagnostics.Process]::GetProcessById(${update.pid});try{$p.StartTime.ToUniversalTime().ToString('o')}finally{$p.Dispose()}}catch{exit 1}`;
    const result=spawnSync(shell,['-NoLogo','-NoProfile','-NonInteractive','-Command',command],{windowsHide:true,encoding:'utf8',timeout:2000,maxBuffer:4096});
    const actual=Date.parse(result.stdout?.trim());
    if(result.status===0 && Number.isFinite(actual)){
      // A recycled PID can never regain its earlier creation time. Remember
      // one proven stale marker so normal one-second polls do no extra work.
      if(actual>expected)staleUpdateMarker=key;
      return actual===expected;
    }
    // An observation failure cannot authorize a worker during a live update.
    return processAlive(update.pid);
  }
  return true;
}
export const updatingSnapshot=()=>({ok:false,queryOk:false,retryable:true,errorCode:'UPDATING',error:'挂件正在更新，请稍后重试',windows:[],clearPrevious:true});

// All callers request the same single writer; even headless MCP/control queries
// use watch.mjs instead of starting a separate account query.
export async function requestRefresh(config,configPath,{timeoutMs=45000,startWorker=()=>{
  const child=spawn(config.nodePath??process.execPath,[path.join(path.dirname(configPath),'runtime','watch.mjs'),configPath,'0'],{windowsHide:true,detached:true,stdio:'ignore'});
  child.on('error',()=>{});child.unref();
},pollMs=100,restartIntervalMs=5000}={}) {
  if(widgetUpdating(config.dataDir))return updatingSnapshot();
  const id=randomUUID(),at=Date.now();
  // Reserve time for the file queue if a connected pipe stops answering.
  const pipeTimeoutMs=Math.min(30000,Math.floor(timeoutMs*2/3));
  const piped=await requestPipeRefresh(config.dataDir,{timeoutMs:pipeTimeoutMs});
  if(widgetUpdating(config.dataDir))return updatingSnapshot();
  if(piped)return piped;
  const requestFile=path.join(config.dataDir,'refresh-requests',id+'.json');
  const resultFile=path.join(config.dataDir,'refresh-results',id+'.json');
  try {
    if(Date.now()-at>=timeoutMs)return {ok:false,queryOk:false,error:'额度刷新超时，请稍后重试',windows:[],clearPrevious:true};
    atomicJson(requestFile,{id,at,expiresAt:at+timeoutMs});
    let lastStart=at;
    if(!healthyWorker(config.dataDir))startWorker();
    while(Date.now()-at<timeoutMs) {
      if(widgetUpdating(config.dataDir))return updatingSnapshot();
      const result=readJson(resultFile);
      if(result?.requestId===id && result.snapshot && typeof result.snapshot==='object')return result.snapshot;
      if(Date.now()-lastStart>=restartIntervalMs && !healthyWorker(config.dataDir)) {
        lastStart=Date.now();startWorker();
      }
      await pause(pollMs);
    }
    return {ok:false,queryOk:false,error:'额度刷新超时，请稍后重试',windows:[],clearPrevious:true};
  } finally {
    for(const file of [requestFile,resultFile])try{fs.unlinkSync(file);}catch{}
  }
}

export function readPendingRequests(dataDir,now=Date.now()) {
  const dir=path.join(dataDir,'refresh-requests');
  let names;try{names=fs.readdirSync(dir);}catch{return [];}
  const requests=[];
  for(const name of names) {
    if(!/^[0-9a-f-]{36}\.json$/i.test(name))continue;
    const file=path.join(dir,name),request=readJson(file);
    if(!request || request.id+'.json'!==name || !Number.isFinite(request.expiresAt) || request.expiresAt<=now || request.expiresAt>now+60000) {
      try{fs.unlinkSync(file);}catch{};continue;
    }
    requests.push({...request,file});
  }
  return requests;
}

export function completeRequests(dataDir,requests,snapshot) {
  for(const request of requests) {
    atomicJson(path.join(dataDir,'refresh-results',request.id+'.json'),{requestId:request.id,snapshot});
    try{fs.unlinkSync(request.file);}catch{}
  }
}

export function cleanRefreshResults(dataDir,now=Date.now()) {
  const dir=path.join(dataDir,'refresh-results');
  let names;try{names=fs.readdirSync(dir);}catch{return;}
  for(const name of names) {
    if(!/^[0-9a-f-]{36}\.json$/i.test(name))continue;
    const file=path.join(dir,name);
    try{if(now-fs.statSync(file).mtimeMs>60000)fs.unlinkSync(file);}catch{}
  }
}
