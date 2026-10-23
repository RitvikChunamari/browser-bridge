const api=globalThis.browser||chrome;
const status=document.querySelector('#status');
async function refresh(){const {bridgeStatus}=await api.storage.local.get('bridgeStatus');status.textContent=bridgeStatus||'Open the Mac app and install this browser’s local host first.';}
document.querySelector('#pair').addEventListener('submit',async event=>{event.preventDefault();status.textContent='Connecting…';try{const result=await api.runtime.sendMessage({action:'pair',code:document.querySelector('#code').value.trim(),label:document.querySelector('#label').value.trim()});if(!result.ok)throw Error(result.error);document.querySelector('#code').value='';await refresh();}catch(error){status.textContent=error.message;}});
for(const [id,permission,label] of [['history-permission','history','History'],['groups-permission','tabGroups','Tab groups']]) {
 document.getElementById(id).addEventListener('click',async()=>{try{const granted=await api.permissions.request({permissions:[permission]});status.textContent=granted?`${label} permission granted.`:`${label} permission was not granted.`;await api.runtime.sendMessage({action:'poll'});}catch(error){status.textContent=`${label} permission is unavailable in this browser: ${error.message}`;}});
}
refresh();setInterval(refresh,3000);
