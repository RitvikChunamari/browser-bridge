export const browserNames = {helium:'Helium',arc:'Arc',zen:'Zen',dia:'Dia',chrome:'Chrome',firefox:'Firefox',brave:'Brave',safari:'Safari',edge:'Edge',opera:'Opera',vivaldi:'Vivaldi'};
export const historyLimit = 10000;
export async function captureBrowser(api, {browser, history = false} = {}) {
  if (!Object.hasOwn(browserNames, browser)) throw Error('Choose the browser you are capturing.');
  if (browser === 'safari') throw Error('Safari uses bookmark HTML export; this helper does not support Safari.');
  const snapshot = {spaces:[],folders:[],tabs:[],bookmarks:[],history:[],passwordCount:0,cookieCount:0,sourceFile:'live capture',warnings:[
    'Browser windows approximate spaces. Public APIs cannot expose native spaces, Essentials, Arc Favorites or nested browser sidebar folders; use the original profile backup to preserve these.',
    'Passwords, passkeys, cookies, signed-in sessions, closed tabs, extensions and settings are not captured. Container identity is informational only; container isolation is not transferable.',
    'Live page titles and URLs are captured; browser-specific saved pinned destinations may not be exposed.'
  ]};
  const windows = await api.windows.getAll({populate:true,windowTypes:['normal']});
  let groups=[];
  if(api.tabGroups?.query) {try{groups=await api.tabGroups.query({});}catch{snapshot.warnings.push('Tab groups could not be read; tab order and pins are retained.');}}
  else snapshot.warnings.push('This browser does not expose tab groups; tab order and pins are retained.');
  const knownGroups=new Set(groups.map(g=>g.id));
  for(const g of groups) snapshot.folders.push({id:`group:${g.id}`,name:g.title||'Untitled group',parentID:null,spaceID:`window:${g.windowId}`});
  windows.forEach((window,index)=>{
    const spaceID=`window:${window.id}`;snapshot.spaces.push({id:spaceID,name:`Window ${index+1}`});
    for(const t of [...(window.tabs||[])].sort((a,b)=>a.index-b.index)) snapshot.tabs.push({id:`tab:${t.id}`,url:t.url||t.pendingUrl||'',title:t.title||t.url||'Untitled tab',pinned:Boolean(t.pinned),essential:false,spaceID,folderID:knownGroups.has(t.groupId)?`group:${t.groupId}`:null,order:t.index??0,originalURL:null,container:Number(t.cookieStoreId?.match(/^firefox-container-(\d+)$/)?.[1]||0)});
  });
  let next=1;
  const visit=(nodes,parent=0)=>{for(const node of nodes){const id=next++;snapshot.bookmarks.push({id,parent,title:node.title||'Bookmarks',url:node.url||null,type:node.url?1:2});if(node.children)visit(node.children,id);}};
  visit(await api.bookmarks.getTree());
  if(history){
    const entries=await api.history.search({text:'',startTime:0,maxResults:historyLimit});
    snapshot.history=entries.map(h=>({url:h.url||'',title:h.title||'',time:h.lastVisitTime||0}));
    snapshot.warnings.push(`History contains at most ${historyLimit.toLocaleString('en-US')} most recent URLs, not every visit. Original last-visit times are retained in this capture; importing may use import-time timestamps.`);
  }
  return {schema:1,format:'browser-bridge-capture',browser,capturedAt:new Date().toISOString(),snapshot};
}
