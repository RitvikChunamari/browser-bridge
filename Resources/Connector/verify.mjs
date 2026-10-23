import {getJournal} from './import.mjs';
const safe=url=>{try{return ['https:','http:'].includes(new URL(url).protocol);}catch{return false;}};
const key=(path,title,url)=>JSON.stringify([path,title,url]);
export async function verifyImport(api,input){
  const payload=input.package||input, options=input.options||{},s=payload.snapshot;
  const journal=await getJournal(api,payload.packageID);
  if(!journal)throw Error('No import journal exists for this transfer.');
  const mismatches=[],expected=[],actual=[];
  const note=text=>{if(mismatches.length<100)mismatches.push(text);};
  if(options.bookmarks){
    const space=new Map(s.spaces.map(w=>[w.id,[w.name]]));
    const folderPath=(id,seen=new Set())=>{const f=s.folders.find(f=>f.id===id);if(!f||seen.has(id))return ['Unassigned tabs'];seen.add(id);return [...(f.parentID?folderPath(f.parentID,seen):space.get(f.spaceID)||['Unassigned tabs']),f.name||'Untitled folder'];};
    for(const t of s.tabs){const url=t.originalURL||t.url;if(safe(url))expected.push(key(t.essential?['Essentials']:t.folderID?folderPath(t.folderID):space.get(t.spaceID)||['Unassigned tabs'],t.title||url,url));}
    const bookmarkPath=(id,seen=new Set())=>{const b=s.bookmarks.find(b=>b.id===id);if(!b||b.type!==2||seen.has(id))return ['Saved bookmarks'];seen.add(id);return [...bookmarkPath(b.parent,seen),b.title||'Bookmarks'];};
    for(const b of s.bookmarks)if(b.url&&safe(b.url))expected.push(key(bookmarkPath(b.parent),b.title||b.url,b.url));
    if(!journal.bookmarkRoot)note('Imported bookmark root is missing.');
    else{try{const roots=await api.bookmarks.getSubTree(journal.bookmarkRoot);const walk=(nodes,path)=>{for(const n of nodes){if(n.url)actual.push(key(path,n.title,n.url));else walk(n.children||[],[...path,n.title]);}};walk(roots[0]?.children||[],[]);}catch{note('Imported bookmark tree cannot be read.');}}
    const counts=new Map();for(const item of actual)counts.set(item,(counts.get(item)||0)+1);
    for(const item of expected){const count=counts.get(item)||0;if(!count)note('A bookmark URL, title, or folder path differs from the intended transfer.');else counts.set(item,count-1);}
    if(actual.length!==expected.length)note(`Bookmark link count differs: expected ${expected.length}, observed ${actual.length}.`);
  }
  let tabs=0,groups=0,history=0;
  if(options.tabs)for(const t of s.tabs){
    const url=t.originalURL||t.url;if(!safe(url))continue;
    const recorded=(journal.tabs||[]).find(item=>item.sourceID===t.id);
    if(!recorded){note(`Source tab ${t.id} was not imported.`);continue;}
    if(options.sessionID && recorded.sessionID!==options.sessionID){note(`Imported tab ${t.id} belongs to an earlier browser session; its identity needs manual review.`);continue;}
    try{const tab=await api.tabs.get(recorded.id);if((tab.pendingUrl||tab.url)!==url)note(`Imported tab ${t.id} has a different URL.`);else tabs++;
      if(Boolean(tab.pinned)!==Boolean(t.pinned||t.essential))note(`Imported tab ${t.id} has a different pin state.`);
      if(options.groups&&t.folderID&&!t.pinned&&!t.essential){const parts=[],seen=new Set();let id=t.folderID;while(id&&!seen.has(id)){seen.add(id);const f=s.folders.find(f=>f.id===id);if(!f)break;parts.unshift(f.name);id=f.parentID;}const title=[s.spaces.find(w=>w.id===t.spaceID)?.name,...parts].filter(Boolean).join(' / ');try{const group=await api.tabGroups.get(tab.groupId);if(group.title!==title)note(`Imported tab ${t.id} has a different group.`);else groups++;}catch{note(`Imported tab ${t.id} has no readable group.`);}}
    }catch{note(`Imported tab ${t.id} is missing.`);}
  }
  if(options.history)for(const url of new Set(s.history.map(h=>h.url).filter(safe))){try{if((await api.history.getVisits({url})).length)history++;else note('An intended history URL is absent.');}catch{note('History verification permission is unavailable.');}}
  if((journal.remainingTabs||0)>0)note('Some intended tabs remain unimported.');
  return {journal,observed:{bookmarks:actual.length,tabs,groups,history},expected:{bookmarks:expected.length,tabs:options.tabs?s.tabs.filter(t=>safe(t.originalURL||t.url)).length:0},mismatches};
}
