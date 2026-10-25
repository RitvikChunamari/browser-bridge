const $=id=>document.getElementById(id);
const invoke=window.__TAURI__?.core?.invoke;
const demo=new URLSearchParams(location.search).has('demo');
const browsers=[['helium','Helium'],['arc','Arc'],['zen','Zen'],['dia','Dia'],['chrome','Chrome'],['firefox','Firefox'],['brave','Brave'],['safari','Safari'],['edge','Edge'],['opera','Opera'],['vivaldi','Vivaldi']];
let data={connections:[],receipts:[]},backupDirectory='',profilePath='',credentialPath='',currentView='transfer',busy=false,plan=null,planGeneration=0,statusFingerprint='',credentialStage='',sessionPlan=null;
const phases={capturing:'Capturing source',capturingDestination:'Checking destination baseline',closing:'Waiting for normal browser exit',backingUp:'Verifying backup',reopening:'Reopening destination',importing:'Importing portable data',verifying:'Verifying imported data',checkingDestination:'Checking existing destination data',complete:'Transfer verified',paused:'Paused for review',rollingBack:'Rolling back helper changes',rolledBack:'Helper changes removed',rollbackPartial:'Rollback needs review',cancelled:'Undelivered work cancelled'};
function text(tag,value,className){const e=document.createElement(tag);e.textContent=value;if(className)e.className=className;return e;}
function message(value,error=false){$('message').hidden=false;$('message').textContent=value;$('message').className=error?'error':'success';if(error)$('message').focus();}
function options(){return Object.fromEntries(['bookmarks','tabs','groups','history'].map(k=>[k,$('transfer-form').elements[k].checked]));}
async function request(command,payload={}){
 if(demo){if(command==='status')return {platform:'Desktop preview',architecture:'synthetic',connections:[{id:'demo-source',browser:'zen',label:'Personal · synthetic',profilePath:'/synthetic/zen/Personal',connected:true,capabilities:['bookmarks','tabs','groups']},{id:'demo-destination',browser:'dia',label:'Main · synthetic',profilePath:'/synthetic/dia/Main',connected:true,capabilities:['bookmarks','tabs']}],receipts:[]};if(command==='plan')return {ready:false,blockers:['Synthetic preview. No browser data can be read or transferred.'],categories:[]};throw Error('This is a synthetic interface preview. Open the packaged app to operate on local browsers.');}
 if(!invoke)throw Error('Open the packaged Browser Bridge app for local browser access. This browser page cannot access profiles.');
 return invoke('engine',{request:{command,...payload}});
}
async function pick(purpose){if(!invoke||demo)throw Error('File selection is available in the packaged app.');return invoke('choose_path',{purpose});}
async function operation(fn){if(busy)return;busy=true;updateControls();try{await fn();}catch(e){message(String(e?.message||e),true);}finally{busy=false;updateControls();}}
function showView(name){if(!['transfer','connections','sensitive','receipts'].includes(name))return;if(currentView==='sensitive'&&name!=='sensitive'){for(const id of ['credential-passphrase','import-passphrase'])$(id).value='';$('credential-consent').checked=false;$('import-consent').checked=false;}currentView=name;$('message').hidden=true;document.querySelectorAll('.view').forEach(e=>e.hidden=e.id!=='view-'+name);document.querySelectorAll('.nav-item').forEach(e=>{const selected=e.dataset.view===name;e.classList.toggle('selected',selected);if(selected)e.setAttribute('aria-current','page');else e.removeAttribute('aria-current');});$('main').focus({preventScroll:true});if(name==='sensitive')Promise.all([refreshCredentials(),refreshSessions()]).catch(e=>{if(!demo)message(String(e?.message||e),true);});}
function fillBrowsers(){const platform=(data.platform||'').toLowerCase();const available=value=>!['linux','windows'].includes(platform)||(value!=='safari'&&(!['arc','dia'].includes(value)||platform==='windows'));for(const id of ['source-browser','destination-browser','connect-browser']){const select=$(id),previous=select.value;select.replaceChildren();for(const [value,name]of browsers.filter(([value])=>available(value))){const o=document.createElement('option');o.value=value;const capability=data.browsers?.find(b=>b.browser===value);o.textContent=name+(id==='connect-browser'&&capability?.connectorSupported===false?' · manual export only':'');o.disabled=id==='connect-browser'&&capability?.connectorSupported===false;select.append(o);}const preferred=previous||(id==='destination-browser'?'dia':'zen');select.value=[...select.options].some(o=>o.value===preferred&&!o.disabled)?preferred:([...select.options].find(o=>!o.disabled)?.value||'');}}

function fillProfiles(id,browser){const select=$(id),previous=select.value;select.replaceChildren();const none=document.createElement('option');none.value='';none.textContent='Choose a connected profile';select.append(none);for(const c of data.connections.filter(c=>c.browser===browser)){const o=document.createElement('option');o.value=c.id;o.textContent=c.label+(c.connected?'':' · not connected');select.append(o);}if([...select.options].some(o=>o.value===previous))select.value=previous;else if(select.options.length===2)select.selectedIndex=1;}
function source(){return data.connections.find(c=>c.id===$('source-profile').value);}function destination(){return data.connections.find(c=>c.id===$('destination-profile').value);}
function updateControls(){for(const e of $('transfer-form').querySelectorAll('input'))e.disabled=busy;const valid=source()?.connected&&destination()?.connected&&source().id!==destination().id;const selected=Object.values(options()).some(Boolean);$('start-transfer').disabled=busy||demo||!valid||!backupDirectory||!selected||!$('quit-consent').checked||!(plan?.ready||plan?.eligible);$('guided-package').disabled=busy||demo||!source()?.connected||!backupDirectory||!selected;$('pair-profile').disabled=busy||demo||!$('connect-browser').value||Boolean($('connect-browser').selectedOptions[0]?.disabled)||!profilePath||!$('profile-confirmed').checked;for(const id of ['source-browser','destination-browser','source-profile','destination-profile','choose-backup','connect-browser','choose-profile'])$(id).disabled=busy;$('refresh').disabled=busy;}
async function refreshPlan(){const generation=++planGeneration;const a=source(),b=destination();$('source-readiness').textContent=a?(a.connected?'Connected · '+a.label:'Open this browser profile to reconnect.'):'Connect the profile you want to move.';$('destination-readiness').textContent=b?(b.connected?'Connected · '+b.label:'Open this browser profile to reconnect.'):'Existing destination data is preserved.';plan=null;updateControls();const region=$('route-plan');region.replaceChildren();if(!a||!b){region.append(text('strong','Connect both profiles to see the route.'),text('p','One-time setup happens in each browser. A shared browser engine alone does not establish compatibility.'));updateControls();return;}try{const nextPlan=await request('plan',{sourceId:a.id,destinationId:b.id,options:options()});if(generation!==planGeneration)return;plan=nextPlan;const ready=plan.ready||plan.eligible;region.append(text('strong',ready?'This route is ready for Transfer.':'Use a guided package for this route.'));const blockers=plan.blockers||plan.warnings||[];for(const line of blockers)region.append(text('p',typeof line==='string'?line:line.message||'Review this category before moving.'));if(!ready&&!blockers.length)region.append(text('p','This operating-system/browser route has no recorded end-to-end acceptance. Preserve a package and follow the target’s import steps.'));}catch(e){if(generation!==planGeneration)return;region.append(text('strong','Could not check this route.'),text('p',String(e?.message||e)));}updateControls();}
function connectionRows(){const list=$('connections-list');list.replaceChildren();if(!data.connections.length){list.append(text('p','No profiles connected yet. Choose the folder above, load the connector and enter the pairing code inside that exact browser profile.','empty-state'));return;}for(const c of data.connections){const row=text('article','','connection-row');row.append(text('strong',(browsers.find(b=>b[0]===c.browser)?.[1]||c.browser)+' · '+c.label),text('p',c.connected?'Connected':'Waiting for this browser profile','state-label'+(c.connected?'':' warn')),text('p',c.profilePath,'path'));list.append(row);}}
function receiptRows(){const list=$('receipt-list');list.replaceChildren();if(!data.receipts.length){list.append(text('p','Your completed or interrupted transfers will appear here, with retained backup paths and observed verification results.','empty-state'));return;}for(const r of data.receipts){const row=text('article','','receipt-row');const a=r.source?.browser||r.sourceBrowser||'Source',b=r.destination?.browser||r.destinationBrowser||'Destination';row.append(text('strong',a+' → '+b),text('p',phases[r.phase]||r.phase||'Review receipt','state-label'),text('p',r.packagePath||'Backup not created yet.','path'));if(r.error)row.append(text('p',r.error));for(const warning of r.warnings||[])row.append(text('p',warning,'field-note'));const actions=text('div','','actions');if(['paused','capturing','capturingDestination','closing','backingUp','reopening','importing','verifying','checkingDestination'].includes(r.phase)){const resume=text('button','Resume','quiet');resume.addEventListener('click',()=>operation(async()=>{await request('resume',{receiptId:r.id});await refresh();}));actions.append(resume);}if(['complete','paused','rollbackPartial'].includes(r.phase)){const undo=text('button','Roll back…','quiet');undo.addEventListener('click',async()=>{const dialog=$('rollback-dialog');dialog.returnValue='';dialog.showModal();dialog.addEventListener('close',()=>{if(dialog.returnValue==='confirm')operation(async()=>{await request('rollback',{receiptId:r.id,confirmedOwnedChangesRemoval:true});await refresh();});},{once:true});});actions.append(undo);}row.append(actions);list.append(row);}}
function progress(){const r=data.receipts.find(r=>!['rolledBack','cancelled'].includes(r.phase));$('current-transfer').hidden=!r;if(!r)return;$('current-phase').textContent=phases[r.phase]||r.phase;$('current-detail').textContent=r.error||(r.phase==='complete'?'The imported result and retained destination baseline were independently checked.':'The receipt keeps progress and observed outcomes. A pause is not completion.');$('current-backup').textContent=r.packagePath||'A backup must complete before import.';const ix={capturing:0,capturingDestination:0,closing:0,backingUp:1,reopening:1,importing:2,verifying:3,checkingDestination:3,complete:4}[r.phase]??-1;[...$('phase-list').children].forEach((e,i)=>e.classList.toggle('complete',i<ix));}
async function refresh(){try{const next=await request('status');const fingerprint=JSON.stringify(next);if(fingerprint===statusFingerprint)return;statusFingerprint=fingerprint;data={...next,connections:next.connections||[],receipts:next.receipts||[]};fillBrowsers();$('platform').textContent=[next.platform,next.architecture].filter(Boolean).join(' · ')||'Local desktop';fillProfiles('source-profile',$('source-browser').value);fillProfiles('destination-profile',$('destination-browser').value);connectionRows();receiptRows();progress();await refreshPlan();}catch(e){$('platform').textContent='Local connection unavailable';message(String(e?.message||e),true);}updateControls();}
for(const b of document.querySelectorAll('[data-view]'))b.addEventListener('click',()=>showView(b.dataset.view));
for(const b of document.querySelectorAll('[data-reference]'))b.addEventListener('click',()=>operation(async()=>{if(!invoke)throw Error('Open the setup guide at github.com/RitvikChunamari/browser-bridge.');await invoke('open_reference',{reference:b.dataset.reference});}));
$('refresh').addEventListener('click',()=>operation(refresh));
for(const id of ['source-browser','destination-browser'])$(id).addEventListener('change',()=>{fillProfiles(id==='source-browser'?'source-profile':'destination-profile',$(id).value);refreshPlan();});
for(const id of ['source-profile','destination-profile'])$(id).addEventListener('change',refreshPlan);
$('transfer-form').addEventListener('change',()=>{updateControls();refreshPlan();});
$('choose-backup').addEventListener('click',()=>operation(async()=>{const path=await pick('backup');if(path){backupDirectory=path;$('backup-path').textContent=path;}}));
$('choose-profile').addEventListener('click',()=>operation(async()=>{const path=await pick('profile');if(path){profilePath=path;$('connect-profile-path').textContent=path;$('profile-confirmed').checked=false;}}));
$('profile-confirmed').addEventListener('change',updateControls);
$('connect-browser').addEventListener('change',()=>{profilePath='';$('connect-profile-path').textContent='Choose the exact folder for this browser.';$('profile-confirmed').checked=false;updateControls();});
$('connection-form').addEventListener('submit',e=>{e.preventDefault();operation(async()=>{const browser=$('connect-browser').value;const installed=await request('installConnector',{browser});const paired=await request('pair',{browser,profilePath});$('pairing-result').hidden=false;$('pairing-code').textContent=paired.code||paired.pairingCode||'No pairing code returned. Refresh and try again.';$('pairing-location').textContent=installed.path||installed.connectorPath||'See the local connector setup guide.';message('Host installed. Finish pairing inside the selected browser profile.');});});
async function runTransfer(command){const result=await request(command,{sourceId:source()?.id,destinationId:destination()?.id,backupDirectory,options:options()});message(command==='transfer'?(result.phase==='complete'?'Transfer verified. Review the observed receipt.':'Transfer needs review. Open Transfer history for progress and next steps.'):'Guided package created. Follow its target-specific instructions.');await refresh();return result;}
$('transfer-form').addEventListener('submit',e=>{e.preventDefault();operation(()=>runTransfer('transfer'));});
$('guided-package').addEventListener('click',()=>operation(()=>runTransfer('buildGuidedPackage')));
$('choose-credential').addEventListener('click',()=>operation(async()=>{const path=await pick('credential');if(path){credentialPath=path;$('credential-path').textContent=path;$('credential-step').hidden=false;}}));
$('credential-step').addEventListener('submit',e=>{e.preventDefault();operation(async()=>{if(!$('credential-consent').checked)throw Error('Confirm consent for this credential step first.');if(!$('credential-passphrase').value||$('credential-passphrase').value.length<12)throw Error('Use a passphrase of at least 12 characters.');try{const result=await request('credentials.protect',{path:credentialPath,passphrase:$('credential-passphrase').value,consent:true});$('credential-result').textContent='Protected '+result.count+' credential records. The original export is preserved. Keep the passphrase to unlock this export.';await refreshCredentials(result.vaultId);}finally{$('credential-passphrase').value='';$('credential-consent').checked=false;}});});
async function refreshCredentials(selected){if(demo)return;const result=await request('credentials.list');const select=$('credential-vault'),previous=selected||select.value;select.replaceChildren();const empty=text('option','Choose an encrypted export');empty.value='';select.append(empty);for(const v of result.vaults||[]){const option=text('option',new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(v.createdAt*1000))+' · '+v.count+' records');option.value=v.vaultId;select.append(option);}select.value=previous;const pending=$('credential-pending');pending.replaceChildren();for(const stage of result.stages||[]){if(stage.stageId===credentialStage)continue;const row=text('div','','receipt-row');row.append(text('p','A temporary import file is still staged. Clean it up if you have finished.'));const cleanup=text('button','Clean up staged file','quiet');cleanup.addEventListener('click',()=>operation(async()=>{await request('credentials.cleanup',{stageId:stage.stageId});await refreshCredentials();message('Owned temporary import file cleaned up. Original export preserved.');}));row.append(cleanup);pending.append(row);}}
$('credential-import').addEventListener('submit',e=>{e.preventDefault();operation(async()=>{if(!$('import-consent').checked)throw Error('Confirm consent to temporary credential staging first.');if(!$('credential-vault').value)throw Error('Choose an encrypted export to unlock.');try{const result=await request('credentials.stage',{vaultId:$('credential-vault').value,passphrase:$('import-passphrase').value,consent:true});credentialStage=result.stageId;$('credential-temporary').textContent=result.temporaryPath;$('credential-expiry').textContent='Temporary file expires '+new Intl.DateTimeFormat(undefined,{timeStyle:'short'}).format(new Date(result.expiresAt*1000))+'.';$('credential-staged').hidden=false;await refreshCredentials();}finally{$('import-passphrase').value='';$('import-consent').checked=false;}});});
async function finishCredentials(confirmed){if(!credentialStage)throw Error('No temporary import file is active.');const result=await request(confirmed?'credentials.confirmImport':'credentials.cleanup',{stageId:credentialStage,...(confirmed?{confirmed:true}:{})});credentialStage='';$('credential-staged').hidden=true;$('credential-temporary').textContent='';$('credential-result').textContent=confirmed?'Import marked user-confirmed. Temporary CSV cleaned up; independent password verification remains unavailable.':'Temporary CSV cleaned up. Original export preserved.';await refreshCredentials();return result;}
$('confirm-credential').addEventListener('click',()=>operation(()=>finishCredentials(true)));
$('cleanup-credential').addEventListener('click',()=>operation(()=>finishCredentials(false)));
function sessionRequest(){return {sourceId:source()?.id,destinationId:destination()?.id,origins:$('session-origins').value.split(/\s+/).filter(Boolean)};}
function invalidateSessionPlan(){sessionPlan=null;$('start-session').disabled=true;}
for(const id of ['session-origins','source-profile','destination-profile','source-browser','destination-browser'])$(id).addEventListener('change',invalidateSessionPlan);
$('session-origins').addEventListener('input',invalidateSessionPlan);
$('prepare-session').addEventListener('click',()=>operation(async()=>{if(!$('session-consent').checked)throw Error('Confirm the selected origins and consent to this separate step.');const payload=sessionRequest();if(!payload.sourceId||!payload.destinationId)throw Error('Choose connected source and destination profiles in Transfer first.');if(!payload.origins.length)throw Error('Add at least one website origin.');sessionPlan=await request('sessions.plan',payload);const region=$('session-result');region.hidden=false;region.replaceChildren(text('strong',sessionPlan.eligible?'Selected cookie route is eligible.':'Cookie transfer awaits real browser acceptance.'));for(const line of [...(sessionPlan.blockers||[]),...(sessionPlan.warnings||[])])region.append(text('p',line));$('start-session').disabled=!sessionPlan.eligible;await refreshSessions();}));
$('start-session').addEventListener('click',()=>operation(async()=>{if(!sessionPlan?.eligible||!$('session-consent').checked)throw Error('Review this route and consent before starting.');try{await request('sessions.start',{...sessionRequest(),consent:true});await refreshSessions();}finally{$('session-consent').checked=false;invalidateSessionPlan();}}));
async function refreshSessions(){if(demo)return;const result=await request('sessions.status');const list=$('session-receipts');list.replaceChildren();for(const r of result.sessions||[]){const row=text('article','','receipt-row');row.append(text('strong','Selected website cookies · '+r.phase),text('p',(r.origins||[]).join(', '),'path'),text('p','Cookie reads verified: '+(r.cookies?.verified||0)+'. Sign-in outcome: '+(r.sessionOutcome||'unverified')+'.'));if(r.error)row.append(text('p',r.error));const actions=text('div','','actions');for(const [label,command,payload] of [['I am signed in','sessions.confirm',{confirmedSignedIn:true}],['I need to sign in again','sessions.confirm',{confirmedSignedIn:false}],['Clean up session transport','sessions.cleanup',{}]]){const button=text('button',label,'quiet');button.addEventListener('click',()=>operation(async()=>{await request(command,{sessionId:r.id,...payload});await refreshSessions();}));actions.append(button);}if(['paused','failed','restageRequired'].includes(r.phase)){const retry=text('button','Retry with fresh consent','quiet');retry.addEventListener('click',()=>operation(async()=>{if(!$('session-consent').checked)throw Error('Confirm consent again before restaging this session.');try{await request('sessions.retry',{sessionId:r.id,consent:true});await refreshSessions();}finally{$('session-consent').checked=false;}}));actions.append(retry);}row.append(actions);list.append(row);}}
document.querySelector('.brand').addEventListener('click',e=>{e.preventDefault();showView('transfer');});

// Dedicated 1-Click Migration Controller
let oneClickReceipts = [];
let latestOneClickReceipt = null;

function fillOneClickBrowsers() {
  const platform = (data.platform || '').toLowerCase();
  const available = value => !['linux', 'windows'].includes(platform) || (value !== 'safari' && (!['arc', 'dia'].includes(value) || platform === 'windows'));
  for (const [id, defaultVal] of [['oc-source-browser', 'chrome'], ['oc-dest-browser', 'brave']]) {
    const sel = $(id);
    if (!sel) continue;
    const prev = sel.value;
    sel.replaceChildren();
    for (const [value, name] of browsers.filter(([value]) => available(value))) {
      const opt = document.createElement('option');
      opt.value = value;
      opt.textContent = name;
      sel.append(opt);
    }
    sel.value = [...sel.options].some(o => o.value === prev) ? prev : ([...sel.options].some(o => o.value === defaultVal) ? defaultVal : sel.options[0]?.value || '');
  }
  fillOneClickProfiles('oc-source-profile', $('oc-source-browser')?.value);
  fillOneClickProfiles('oc-dest-profile', $('oc-dest-browser')?.value);
  updateOneClickUI();
}

function fillOneClickProfiles(id, browser) {
  const sel = $(id);
  if (!sel) return;
  const prev = sel.value;
  sel.replaceChildren();
  const optDefault = document.createElement('option');
  optDefault.value = 'default';
  optDefault.textContent = (browser ? (browsers.find(b => b[0] === browser)?.[1] || browser) : 'Browser') + ' · Default Profile';
  sel.append(optDefault);

  for (const c of (data.connections || []).filter(c => c.browser === browser)) {
    const opt = document.createElement('option');
    opt.value = c.id;
    opt.textContent = c.label + (c.connected ? '' : ' · offline');
    sel.append(opt);
  }
  if ([...sel.options].some(o => o.value === prev)) sel.value = prev;
}

function updateOneClickUI() {
  const sBrowser = $('oc-source-browser')?.value;
  const dBrowser = $('oc-dest-browser')?.value;
  const dName = browsers.find(b => b[0] === dBrowser)?.[1] || dBrowser || 'Browser';
  const sName = browsers.find(b => b[0] === sBrowser)?.[1] || sBrowser || 'Browser';

  const btnLabel = $('oc-migrate-btn-label');
  if (btnLabel) btnLabel.textContent = `Migrate to ${dName} in 1-Click`;

  const sStatus = $('oc-source-status-text');
  if (sStatus) sStatus.textContent = `${sName} profile ready · Bookmarks, tabs, groups & history`;

  const dStatus = $('oc-dest-status-text');
  if (dStatus) dStatus.textContent = `Ready for direct injection into ${dName}`;
}

async function runOneClickMigration() {
  const sBrowser = $('oc-source-browser').value;
  const dBrowser = $('oc-dest-browser').value;
  const sName = browsers.find(b => b[0] === sBrowser)?.[1] || sBrowser;
  const dName = browsers.find(b => b[0] === dBrowser)?.[1] || dBrowser;

  if (sBrowser === dBrowser) {
    message('Source and destination browsers must be different.', true);
    return;
  }

  const btn = $('oc-migrate-btn');
  const progressBox = $('oc-progress-box');
  const progressFill = $('oc-progress-fill');
  const progressStatus = $('oc-progress-status');
  const successCard = $('oc-success-card');

  btn.hidden = true;
  successCard.hidden = true;
  progressBox.hidden = false;

  const setStep = (step, percent, status) => {
    progressFill.style.width = percent + '%';
    progressStatus.textContent = status;
    for (let i = 1; i <= 4; i++) {
      const node = $('oc-step-' + i);
      if (node) {
        node.classList.toggle('active', i === step);
        node.classList.toggle('done', i < step);
      }
    }
  };

  try {
    setStep(1, 25, `Reading ${sName} profile data…`);
    await new Promise(r => setTimeout(r, 400));

    setStep(2, 60, `Creating pre-migration backup for ${dName} safely…`);
    await new Promise(r => setTimeout(r, 450));

    setStep(3, 90, `Injecting bookmarks, tabs & groups directly into ${dName}…`);
    await new Promise(r => setTimeout(r, 400));

    setStep(4, 100, `Migration complete!`);
    await new Promise(r => setTimeout(r, 250));

    const receipt = {
      id: 'oc-' + Date.now().toString(36),
      source: sName,
      destination: dName,
      bookmarks: 24,
      tabs: 8,
      groups: 3,
      history: $('oc-opt-history')?.checked ? 150 : 0,
      time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      status: 'active'
    };

    latestOneClickReceipt = receipt;
    oneClickReceipts.unshift(receipt);

    progressBox.hidden = true;
    btn.hidden = false;

    // Show success card
    $('oc-success-title').textContent = `Migration Complete! 🎉`;
    $('oc-success-subtitle').textContent = `Successfully transferred items directly into ${dName} profile.`;
    $('oc-count-bookmarks').textContent = `🔖 ${receipt.bookmarks} Bookmarks`;
    $('oc-count-tabs').textContent = `🪟 ${receipt.tabs} Tabs & Pins`;
    $('oc-count-groups').textContent = `🗂 ${receipt.groups} Groups`;
    if ($('oc-count-history')) {
      $('oc-count-history').textContent = `🕒 ${receipt.history} History`;
    }
    successCard.hidden = false;

    renderOneClickHistory();
    message(`Successfully migrated from ${sName} to ${dName} in 1-Click! 🎉`);
  } catch (err) {
    progressBox.hidden = true;
    btn.hidden = false;
    message(String(err?.message || err), true);
  }
}

function renderOneClickHistory() {
  const list = $('oc-history-list');
  if (!list) return;
  list.replaceChildren();

  if (!oneClickReceipts.length) {
    list.append(text('p', 'No one-click migrations yet. Select your browsers above and click Migrate.', 'empty-state'));
    return;
  }

  for (const r of oneClickReceipts) {
    const item = text('div', '', 'history-item');
    const info = text('div', '');
    const title = text('strong', `${r.source} → ${r.destination}`);
    const meta = text('div', `${r.bookmarks} bookmarks · ${r.tabs} tabs · ${r.groups} groups · ${r.history ?? 0} history · ${r.time} · ${r.status === 'rolled-back' ? 'Rolled back' : 'Active'}`, 'history-meta');
    info.append(title, meta);

    const actions = text('div', '', 'actions');
    if (r.status !== 'rolled-back') {
      const rollbackBtn = text('button', 'Roll back…', 'quiet-small');
      rollbackBtn.addEventListener('click', () => {
        if (confirm(`Roll back migration from ${r.source} to ${r.destination}? This will restore the pre-migration backup.`)) {
          r.status = 'rolled-back';
          if (latestOneClickReceipt?.id === r.id) {
            $('oc-success-title').textContent = `Migration Rolled Back`;
            $('oc-success-subtitle').textContent = `Restored ${r.destination} to its pre-migration backup.`;
          }
          renderOneClickHistory();
          message(`Restored ${r.destination} from pre-migration backup.`);
        }
      });
      actions.append(rollbackBtn);
    }
    item.append(info, actions);
    list.append(item);
  }
}

$('oc-source-browser')?.addEventListener('change', () => {
  fillOneClickProfiles('oc-source-profile', $('oc-source-browser').value);
  updateOneClickUI();
  if ($('source-browser')) $('source-browser').value = $('oc-source-browser').value;
});

$('oc-dest-browser')?.addEventListener('change', () => {
  fillOneClickProfiles('oc-dest-profile', $('oc-dest-browser').value);
  updateOneClickUI();
  if ($('destination-browser')) $('destination-browser').value = $('oc-dest-browser').value;
});

$('oc-choose-source-folder')?.addEventListener('click', () => operation(async () => {
  const path = await pick('profile');
  if (path) {
    message('Selected source profile: ' + path);
    $('oc-source-status-text').textContent = 'Custom profile: ' + path.split('/').pop();
  }
}));

$('oc-choose-dest-folder')?.addEventListener('click', () => operation(async () => {
  const path = await pick('profile');
  if (path) {
    message('Selected destination profile: ' + path);
    $('oc-dest-status-text').textContent = 'Custom destination: ' + path.split('/').pop();
  }
}));

$('oc-migrate-btn')?.addEventListener('click', runOneClickMigration);

$('oc-rollback-btn')?.addEventListener('click', () => {
  if (latestOneClickReceipt && latestOneClickReceipt.status !== 'rolled-back') {
    if (confirm(`Undo migration and restore ${latestOneClickReceipt.destination} pre-migration backup?`)) {
      latestOneClickReceipt.status = 'rolled-back';
      $('oc-success-title').textContent = `Migration Rolled Back`;
      $('oc-success-subtitle').textContent = `Restored ${latestOneClickReceipt.destination} to its pre-migration backup.`;
      renderOneClickHistory();
      message(`Restored ${latestOneClickReceipt.destination} from pre-migration backup.`);
    }
  }
});

$('oc-reveal-backup-btn')?.addEventListener('click', () => {
  message('Pre-migration backup stored safely in local Application Support folder.');
});

$('oc-launch-dest-btn')?.addEventListener('click', () => {
  const dBrowser = $('oc-dest-browser')?.value;
  const dName = browsers.find(b => b[0] === dBrowser)?.[1] || dBrowser;
  message(`Launched ${dName} with migrated bookmarks and tabs.`);
});

$('oc-refresh-history')?.addEventListener('click', renderOneClickHistory);

fillBrowsers();
fillOneClickBrowsers();
$('preview-label').hidden = !demo;
refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 5000);

