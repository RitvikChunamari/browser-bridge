import test from 'node:test';
import assert from 'node:assert/strict';
import {captureBrowser} from '../../Resources/Exporter/engine.mjs';
const fixture = () => ({windows:{async getAll(){return [{id:7,tabs:[{id:42,index:0,url:'https://example.com',title:'Example',pinned:true,groupId:3,cookieStoreId:'firefox-container-2'}]}]}},tabGroups:{async query(){return [{id:3,windowId:7,title:'Research'}]}},bookmarks:{async getTree(){return [{id:'root',title:'',children:[{id:'folder',title:'Saved',children:[{id:'leaf',title:'Example',url:'https://example.com'}]}]}]}},history:{async search(){throw Error('History must be opt-in')}}});
test('live capture preserves portable tabs, pins, groups and bookmark nesting without reading history by default',async()=>{
 const capture=await captureBrowser(fixture(),{browser:'firefox'});
 assert.equal(capture.format,'browser-bridge-capture');assert.equal(capture.schema,1);assert.equal(capture.browser,'firefox');
 const s=capture.snapshot;assert.deepEqual(s.spaces,[{id:'window:7',name:'Window 1'}]);
 assert.equal(s.tabs[0].pinned,true);assert.equal(s.tabs[0].essential,false);assert.equal(s.tabs[0].folderID,'group:3');assert.equal(s.tabs[0].container,2);
 assert.equal(s.folders[0].name,'Research');assert.equal(s.bookmarks.find(b=>b.title==='Example').parent,s.bookmarks.find(b=>b.title==='Saved').id);
 assert.deepEqual(s.history,[]);assert.equal(s.cookieCount,0);assert.equal(s.passwordCount,0);assert.ok(s.warnings.some(w=>w.includes('native spaces')));
});
test('history capture explicitly opts in with a disclosed bound; unavailable groups do not lose tabs',async()=>{
 const api=fixture();delete api.tabGroups;
 api.history.search=async options=>{assert.deepEqual(options,{text:'',startTime:0,maxResults:10000});return [{url:'https://history.example',title:'Old visit',lastVisitTime:1234}]};
 const result=await captureBrowser(api,{browser:'arc',history:true});
 assert.equal(result.snapshot.tabs.length,1);assert.equal(result.snapshot.tabs[0].folderID,null);assert.deepEqual(result.snapshot.history,[{url:'https://history.example',title:'Old visit',time:1234}]);assert.ok(result.snapshot.warnings.some(w=>w.includes('10,000')));
});
test('capture rejects unsupported browsers instead of mislabelling data',async()=>{
 await assert.rejects(captureBrowser(fixture(),{browser:'unknown'}),/Choose/);
 await assert.rejects(captureBrowser(fixture(),{browser:'safari'}),/HTML/);
});
