import {importPackage, rollbackPackage, getJournal} from './engine.mjs';
const api = globalThis.browser || globalThis.chrome;
const $ = id => document.getElementById(id);
let payload, sessionID;
const status = text => {$('status').textContent = text;};
let working = false;
const busy = value => {working=value;for (const b of document.querySelectorAll('button,input,select')) b.disabled = value;};
window.addEventListener('beforeunload',event=>{if(working){event.preventDefault();event.returnValue='';}});
async function exclusive(work) {
  return navigator.locks.request('zenbridge-import', {ifAvailable:true}, async lock => {
    if (!lock) throw Error('Another importer is running in this profile. Wait for it to finish.');
    return work();
  });
}
try {
  if (!api?.storage) throw Error('Load this folder as an unpacked extension in the destination browser, then click its toolbar icon. Opening this HTML file directly cannot import browser data.');
  const response = await fetch('data.json');
  if (!response.ok) throw Error('Package data is missing. Create a new package in the Mac app.');
  payload = await response.json();
  let session = await api.storage.session.get('zenbridge-session');
  sessionID = session['zenbridge-session'] || crypto.randomUUID();
  await api.storage.session.set({'zenbridge-session':sessionID});
  const names = {helium:'Helium',arc:'Arc',zen:'Zen',dia:'Dia',chrome:'Chrome',firefox:'Firefox',brave:'Brave',safari:'Safari',edge:'Edge',opera:'Opera',vivaldi:'Vivaldi'};
  document.querySelectorAll('[data-target]').forEach(el => el.textContent = payload.targetName || names[payload.targetBrowser] || 'your destination browser');
  const s = payload.snapshot;
  for (const [label,count] of [['Tabs',s.tabs.length],['Spaces',s.spaces.length],['Folders',s.folders.length],['History URLs',s.history.length]]) {
    const block = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
    dt.textContent = label; dd.textContent = count.toLocaleString(); block.append(dt,dd); $('inventory').append(block);
  }
  for (const w of s.spaces) {const option = document.createElement('option');option.value=w.id;option.textContent=w.name;$('space').append(option);}
  const orphan = document.createElement('option');orphan.value='';orphan.textContent='Unassigned tabs';$('space').append(orphan);
  const previous = await getJournal(api,payload.packageID);
  if (previous) status(`Previous run: ${previous.state}. ${previous.tabs.length} tabs recorded; ${previous.remainingTabs || 0} remaining in its last selection. Save the journal for details.`);
  $('loading').hidden=true;$('content').hidden=false;
} catch(error) {$('loading').textContent=error.message;}
$('import-form').addEventListener('submit',async event=>{
  event.preventDefault();
  if (!['bookmarks','history','tabs'].some(id=>$(id).checked)) {status('Select at least one category.');return;}
  busy(true);
  try {
    if ($('tabs').checked) { try { await api.permissions.request({permissions:['tabGroups']}); } catch {} }
    const result=await exclusive(()=>importPackage(api,payload,{bookmarks:$('bookmarks').checked,history:$('history').checked,tabs:$('tabs').checked,space:$('space').value,limit:50,sessionID},status));
    status(`Selected import finished (${result.state}). ${result.tabs.length} tabs recorded; ${result.remainingTabs || 0} remain in this selection. ${result.errors.length} warnings; ${result.skippedURLs} unsupported URL entries left in the archive. Native spaces, Favorites, passwords and cookies were not imported. Groups are approximations where the browser exposes its grouping API.`);
  } catch(error){status(`Import interrupted: ${error.message}. Save the journal; retry or roll back this package.`);}finally{busy(false);}
});
$('journal').addEventListener('click',async()=>{
  const journal=await getJournal(api,payload.packageID);
  const blob=new Blob([JSON.stringify(journal||{state:'not-started'},null,2)],{type:'application/json'});
  const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`zenbridge-journal-${payload.packageID}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
});
$('rollback').addEventListener('click',async()=>{
  if (!confirm('Remove this helper’s bookmark trees (including edits inside them) and close unchanged tabs created this browser session? History stays in place for review. Existing data elsewhere stays intact.')) return;
  busy(true);try{const j=await exclusive(()=>rollbackPackage(api,payload.packageID,sessionID));status(`Rollback: ${j.state}. ${j.tabs.length} tabs and ${j.history.length} history URLs retained for review. Save the journal.`);}catch(e){status(e.message);}finally{busy(false);}
});
