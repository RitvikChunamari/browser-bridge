import {captureBrowser,browserNames} from './engine.mjs';
const api=globalThis.browser||globalThis.chrome;
const $=id=>document.getElementById(id);
for(const [id,name] of Object.entries(browserNames)){
  if(id==='safari')continue;
  const option=document.createElement('option');option.value=id;option.textContent=name;$('browser').append(option);
}
$('capture-form').addEventListener('submit',async event=>{
  event.preventDefault();
  const browser=$('browser').value,history=$('history').checked;
  try{
    if(!api?.windows)throw Error('Load this folder as an extension in the source browser and click its toolbar icon.');
    // Requests run within the button gesture; unsupported group permissions degrade to plain tabs.
    if(history&&!await api.permissions.request({permissions:['history']}))throw Error('History permission was declined. Uncheck history to capture without it.');
    try{await api.permissions.request({permissions:['tabGroups']});}catch{}
    document.querySelectorAll('button,input,select').forEach(el=>el.disabled=true);
    $('status').textContent='Reading this profile…';
    const capture=await captureBrowser(api,{browser,history});
    const url=URL.createObjectURL(new Blob([JSON.stringify(capture,null,2)],{type:'application/json'}));
    const link=document.createElement('a');link.href=url;link.download=`browser-bridge-${browser}-capture.json`;link.click();setTimeout(()=>URL.revokeObjectURL(url),30000);
    $('status').textContent=`Capture prepared for download: ${capture.snapshot.tabs.length} tabs, ${capture.snapshot.bookmarks.length} bookmark entries, ${capture.snapshot.history.length} history URLs. Select the saved JSON in Browser Bridge. ${capture.snapshot.warnings.join(' ')}`;
  }catch(error){$('status').textContent=`Capture failed: ${error.message}`;}
  finally{document.querySelectorAll('button,input,select').forEach(el=>el.disabled=false);}
});
