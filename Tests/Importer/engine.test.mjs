import test from 'node:test';
import assert from 'node:assert/strict';
import {importPackage, rollbackPackage} from '../../Resources/Importer/engine.mjs';
function browser() {
  let next=100; const saved={}; const nodes=new Map([['1',{id:'1',title:'Bookmarks bar'}]]), tabs=new Map(), visits=new Map(), groups=new Map();
  const api={
    storage:{local:{async get(k){return {[k]:structuredClone(saved[k])}},async set(v){Object.assign(saved,structuredClone(v))}}},
    bookmarks:{async getTree(){return [{id:'0',children:[nodes.get('1')]}]},async create(v){const n={...v,id:String(next++)};nodes.set(n.id,n);return n},async get(id){if(!nodes.has(id))throw Error('gone');return [nodes.get(id)]},async removeTree(id){const remove=parent=>{for(const [key,n] of nodes)if(n.parentId===parent)remove(key);nodes.delete(parent)};remove(id)}},
    tabs:{async create(v){const t={...v,id:next++};tabs.set(t.id,t);return t},async get(id){if(!tabs.has(id))throw Error('gone');return tabs.get(id)},async remove(id){tabs.delete(id)},async group({tabIds,groupId}){const id=groupId??next++;if(!groups.has(id))groups.set(id,{id});for(const t of tabIds)tabs.get(t).groupId=id;return id}},
    tabGroups:{async update(id,v){Object.assign(groups.get(id),v)},async get(id){if(!groups.has(id))throw Error('No group');return groups.get(id)}},
    history:{async getVisits({url}){return visits.get(url)||[]},async addUrl(details){assert.deepEqual(Object.keys(details),['url']);visits.set(details.url,[{id:String(next++),visitTime:Date.now()}])},async deleteUrl({url}){visits.delete(url)}}
  };
  return {api,nodes,tabs,visits,groups};
}
const payload={schema:1,packageID:'fixture',snapshot:{spaces:[{id:'w',name:'Work'}],folders:[{id:'a',name:'Parent',spaceID:'w'},{id:'b',name:'Child',parentID:'a',spaceID:'w'}],tabs:[{id:'t',url:'https://example.com',title:'Example',spaceID:'w',folderID:'b',essential:true,pinned:true,order:0}],bookmarks:[],history:[]}};
test('import preserves a nested tree, pins Essentials and is repeatable; rollback removes created items only',async()=>{
 const b=browser();b.tabs.set(4,{id:4,url:'https://existing.example'});
 const options={bookmarks:true,tabs:true,history:false,space:'*',limit:50,sessionID:'test'};
 const first=await importPackage(b.api,payload,options);
 assert.equal(b.tabs.size,2);assert.equal([...b.tabs.values()].find(t=>t.id!==4).pinned,true);
 const child=[...b.nodes.values()].find(n=>n.title==='Child');const parent=[...b.nodes.values()].find(n=>n.title==='Parent');assert.equal(child.parentId,parent.id);
 await importPackage(b.api,payload,options);assert.equal(b.tabs.size,2);
 await rollbackPackage(b.api,payload.packageID,'test');assert.equal(b.tabs.size,1);assert.equal(b.tabs.has(4),true);assert.equal(first.state,'complete');
});

test('history import preserves existing visits and rollback retains later activity and navigated tabs',async()=>{
 const b=browser();const url='https://example.com/history';const existing='https://existing.example/history';
 b.visits.set(existing,[{id:'original',visitTime:1}]);
 const p={...payload,packageID:'history-test',snapshot:{...payload.snapshot,history:[{url,time:1},{url:existing,time:2}]}};
 await importPackage(b.api,p,{bookmarks:false,history:true,tabs:true,space:'*',sessionID:'same'});
 assert.equal(b.visits.get(existing)[0].id,'original');
 b.visits.get(url).push({id:'later',visitTime:Date.now()});
 [...b.tabs.values()][0].url='https://example.com/new-destination';
 const result=await rollbackPackage(b.api,p.packageID,'same');
 assert.equal(result.state,'rollback-partial');assert.equal(b.tabs.size,1);assert.equal(b.visits.get(url).length,2);assert.equal(b.visits.get(existing)[0].id,'original');
});

test('tab import is bounded and resumes without duplicates; restarted IDs are never closed',async()=>{
 const b=browser();const p={...payload,packageID:'resume',snapshot:{...payload.snapshot,tabs:[...payload.snapshot.tabs,{...payload.snapshot.tabs[0],id:'two',url:'https://example.org'}]}};
 const options={bookmarks:false,history:false,tabs:true,space:'*',limit:1,sessionID:'before'};
 const first=await importPackage(b.api,p,options);assert.equal(first.remainingTabs,1);assert.equal(b.tabs.size,1);
 const second=await importPackage(b.api,p,options);assert.equal(second.remainingTabs,0);assert.equal(b.tabs.size,2);
 const undo=await rollbackPackage(b.api,p.packageID,'after');assert.equal(undo.state,'rollback-partial');assert.equal(b.tabs.size,2);
});

test('unsupported schemes stay archived and are not opened',async()=>{
 const b=browser();const p={...payload,packageID:'schemes',snapshot:{...payload.snapshot,tabs:[{...payload.snapshot.tabs[0],url:'javascript:alert(1)',originalURL:null}]}};
 const result=await importPackage(b.api,p,{bookmarks:true,tabs:true,history:false,space:'*',sessionID:'test'});
 assert.equal(b.tabs.size,0);assert.ok(result.skippedURLs>0);assert.equal([...b.nodes.values()].filter(n=>n.url).length,0);
});

test('retry preserves edited incomplete bookmark trees until explicit rollback',async()=>{
 const b=browser();const create=b.api.bookmarks.create;let calls=0;
 b.api.bookmarks.create=async v=>{if(++calls===4)throw Error('Interrupted');return create(v)};
 const options={bookmarks:true,tabs:false,history:false,space:'*',sessionID:'test'};
 await assert.rejects(importPackage(b.api,payload,options),/Interrupted/);
 const j=(await b.api.storage.local.get('zenbridge:fixture'))['zenbridge:fixture'];
 const addition=await create({title:'User addition',parentId:j.bookmarkRoot,url:'https://user.example'});
 await importPackage(b.api,payload,options);assert.ok(b.nodes.has(addition.id));
 await rollbackPackage(b.api,payload.packageID,'test');assert.equal(b.nodes.size,1);
});

test('failed tab removal remains in rollback journal',async()=>{
 const b=browser();await importPackage(b.api,payload,{bookmarks:false,tabs:true,history:false,space:'*',sessionID:'same'});
 b.api.tabs.remove=async()=>{throw Error('Tab busy')};
 const j=await rollbackPackage(b.api,payload.packageID,'same');assert.equal(j.state,'rollback-partial');assert.equal(j.tabs.length,1);assert.match(j.errors[0],/Tab busy/);
});

test('later batches reuse live folder groups in the same browser session',async()=>{
 const b=browser();const base={...payload.snapshot.tabs[0],essential:false,pinned:false};
 const p={...payload,packageID:'groups',snapshot:{...payload.snapshot,tabs:[{...base,id:'a'},{...base,id:'b',url:'https://example.org'}]}};
 const options={bookmarks:false,tabs:true,history:false,space:'*',sessionID:'same',limit:1};
 await importPackage(b.api,p,options);await importPackage(b.api,p,options);
 assert.equal(b.tabs.size,2);assert.equal(b.groups.size,1);
});

test('Firefox without grouping still imports safely with Browser Bridge branding',async()=>{
 const b=browser();delete b.api.tabGroups;delete b.api.tabs.group;
 const p={...payload,targetBrowser:'firefox',sourceBrowser:'zen'};
 await importPackage(b.api,p,{bookmarks:true,tabs:true,space:'*',sessionID:'same'});
 assert.ok([...b.nodes.values()].some(n=>n.title.startsWith('Browser Bridge ·')));
 assert.equal(b.tabs.size,1);
});
