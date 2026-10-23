import {captureBrowser} from './capture.mjs';
import {importPackage, rollbackPackage} from './import.mjs';
import {verifyImport} from './verify.mjs';
import {runSession} from './sessions.mjs';
const api = globalThis.browser || chrome;
const host = 'local.browserbridge.connector';
let port, pending, busy = false;
function request(message) {
  if (pending) return Promise.reject(Error('Connector is busy; try again shortly.'));
  if (!port) {
    port = api.runtime.connectNative(host);
    port.onMessage.addListener(response => {const p=pending;pending=null;p?.resolve(response);});
    port.onDisconnect.addListener(() => {const error=api.runtime.lastError?.message||'Local host disconnected. Open Browser Bridge and install the host.';const p=pending;pending=null;port=null;p?.reject(Error(error));});
  }
  return new Promise((resolve,reject)=>{pending={resolve,reject};port.postMessage(message);});
}
async function identity() {
  const data=await api.storage.local.get(['bridgeProfileID','bridgeConnection']);
  if(!data.bridgeProfileID){data.bridgeProfileID=crypto.randomUUID();await api.storage.local.set({bridgeProfileID:data.bridgeProfileID});}
  return data;
}
async function capabilities(){const result=['bookmarks','tabs'];for(const [name,permission] of [['history','history'],['groups','tabGroups']]){try{if(await api.permissions.contains({permissions:[permission]}))result.push(name);}catch{}}return result;}
async function sessionID(){const storage=api.storage.session; if(!storage)throw Error("This browser lacks session storage required for safe tab recovery."); let {bridgeSessionID}=await storage.get("bridgeSessionID");if(!bridgeSessionID){bridgeSessionID=crypto.randomUUID();await storage.set({bridgeSessionID});}return bridgeSessionID;}
async function run(job,browser) {
  const payload=job.payload;
  if(job.operation.startsWith('cookies.'))return runSession(api,job.operation,payload);
  switch(job.operation){
    case 'capture':return {capture:await captureBrowser(api,{browser,history:Boolean(payload.history)})};
    case 'import':return {journal:await importPackage(api,payload.package||payload,{bookmarks:true,tabs:true,history:false,groups:true,space:'*',limit:50,...payload.options,sessionID:await sessionID()})};
    case 'verify':return verifyImport(api,{...payload,options:{...payload.options,sessionID:await sessionID()}});
    case 'rollback':return {journal:await rollbackPackage(api,payload.packageID,await sessionID())};
    default:throw Error('Unsupported local operation.');
  }
}
async function poll(){
  if(busy||pending)return;busy=true;
  try{
    const {bridgeProfileID,bridgeConnection:c}=await identity();if(!c)return;
    const auth={connectionID:c.connectionID,secret:c.secret,profileID:bridgeProfileID};
    const response=await request({action:'poll',...auth,capabilities:await capabilities()});
    if(!response.ok)throw Error(response.error);
    await api.storage.local.set({bridgeStatus:'Connected to '+response.browser,bridgeLastSeen:Date.now()});
    const job=response.job;if(!job)return;
    // Persist a completed result before acknowledgement. A lost acknowledgement must not repeat effects.
    const key='bridgeResult:'+job.id;let result=(await api.storage.local.get(key))[key];
    if(!result){try{result={ok:true,...await run(job,response.browser)};}catch(error){result={ok:false,error:job.operation.startsWith('cookies.')?'Sensitive operation needs permission or renewed consent. Review selected origins and restage.':String(error.message||error)};}if(new TextEncoder().encode(JSON.stringify(result)).length>=8*1024*1024)result={ok:false,error:'Capture exceeds the 8 MiB connector limit. Use a guided file package.'};await api.storage.local.set({[key]:result});}
    const ack=await request({action:'complete',...auth,jobID:job.id,result});if(!ack.ok)throw Error(ack.error);await api.storage.local.remove(key);
  }catch(error){await api.storage.local.set({bridgeStatus:String(error.message||error)});}finally{busy=false;}
}
api.runtime.onMessage.addListener((message,sender,sendResponse)=>{
  if(sender.id!==api.runtime.id)return false;
  if(message.action==='pair'){
    (async()=>{if(busy||pending)throw Error('Connector is busy. Try again shortly.');const {bridgeProfileID}=await identity();const response=await request({action:'pair',code:message.code,profileID:bridgeProfileID,label:message.label||'Connected profile'});if(!response.ok)throw Error(response.error);await api.storage.local.set({bridgeConnection:response,bridgeStatus:'Connected to '+response.browser});return {ok:true};})().then(sendResponse,error=>sendResponse({ok:false,error:error.message}));return true;
  }
  if(message.action==='poll'){poll().then(()=>sendResponse({ok:true}));return true;}
  return false;
});
api.alarms.create('bridge-connect',{periodInMinutes:0.5});
api.alarms.onAlarm.addListener(alarm=>{if(alarm.name==='bridge-connect')poll();});
setInterval(poll,3000);poll();
