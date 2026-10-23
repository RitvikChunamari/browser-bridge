// Public helper APIs exercised over a synthetic browser's documented APIs; no browser profiles/accounts.
import readline from 'node:readline';
import {pathToFileURL} from 'node:url';
const root=process.argv[2], role=process.argv[3];
const {captureBrowser}=await import(pathToFileURL(`${root}/Resources/Connector/capture.mjs`));
const {importPackage,rollbackPackage}=await import(pathToFileURL(`${root}/Resources/Connector/import.mjs`));
const {verifyImport}=await import(pathToFileURL(`${root}/Resources/Connector/verify.mjs`));
let next=100;const saved={},nodes=new Map([['0',{id:'0',title:'Root'}],['1',{id:'1',parentId:'0',title:'Other bookmarks'}],['2',{id:'2',parentId:'1',title:'Nested folder'}],['3',{id:'3',parentId:'2',title:role,url:`https://${role}.test/`}]]),tabs=new Map([[1,{id:1,windowId:1,index:0,url:`https://${role}.test/`,title:role,pinned:role==='source',groupId:role==='destination'?5:-1}]]),visits=new Map(),groups=new Map(role==='destination'?[[5,{id:5,windowId:1,title:'Existing group'}]]:[]);
const subtree=id=>({...nodes.get(id),children:[...nodes.values()].filter(n=>n.parentId===id).map(n=>subtree(n.id))});
const api={
 storage:{local:{async get(k){return {[k]:structuredClone(saved[k])}},async set(v){Object.assign(saved,structuredClone(v))}}},
 windows:{async getAll(){return [{id:1,tabs:[...tabs.values()]}]}},
 bookmarks:{async getTree(){return [subtree('0')]},async getChildren(id){return [...nodes.values()].filter(n=>n.parentId===id)},async getSubTree(id){if(!nodes.has(id))throw Error('missing');return [subtree(id)]},async create(v){const n={...v,id:String(next++)};nodes.set(n.id,n);return n},async get(id){if(!nodes.has(id))throw Error('gone');return [nodes.get(id)]},async removeTree(id){const remove=parent=>{for(const [key,n]of nodes)if(n.parentId===parent)remove(key);nodes.delete(parent)};remove(id)}},
 tabs:{async query(){return [...tabs.values()]},async create(v){const t={...v,id:next++,windowId:1,index:tabs.size,groupId:-1};tabs.set(t.id,t);return t},async get(id){if(!tabs.has(id))throw Error('gone');return tabs.get(id)},async remove(id){tabs.delete(id)},async group({tabIds,groupId}){const id=groupId??next++;if(!groups.has(id))groups.set(id,{id,windowId:1});for(const t of tabIds)tabs.get(t).groupId=id;return id}},
 tabGroups:{async query(){return [...groups.values()]},async update(id,v){Object.assign(groups.get(id),v)},async get(id){if(!groups.has(id))throw Error('gone');return groups.get(id)}},
 history:{async search(){return [...visits].map(([url])=>({url,title:url,lastVisitTime:1}))},async getVisits({url}){return visits.get(url)||[]},async addUrl({url}){visits.set(url,[{id:String(next++),visitTime:1}])}}
};
for await(const line of readline.createInterface({input:process.stdin})){try{const {operation,payload}=JSON.parse(line);let result;if(operation==='capture')result={capture:await captureBrowser(api,{browser:'chrome',history:payload.history})};if(operation==='import')result={journal:await importPackage(api,payload.package,{...payload.options,sessionID:'fixture'})};if(operation==='verify')result=await verifyImport(api,{...payload,options:{...payload.options,sessionID:'fixture'}});if(operation==='rollback')result={journal:await rollbackPackage(api,payload.packageID,'fixture')};process.stdout.write(JSON.stringify({ok:true,...result})+'\n');}catch(error){process.stdout.write(JSON.stringify({ok:false,error:error.message})+'\n')}}
