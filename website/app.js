'use strict';
const browsers = [
  ['helium','Helium','chromium'],['arc','Arc','chromium'],['zen','Zen','firefox'],['dia','Dia','chromium'],['chrome','Chrome','chromium'],['firefox','Firefox','firefox'],['brave','Brave','chromium'],['safari','Safari','safari'],['edge','Edge','chromium'],['opera','Opera','chromium'],['vivaldi','Vivaldi','chromium']
];
const source = document.querySelector('#source');
const destination = document.querySelector('#destination');
const summary = document.querySelector('#route-summary');
const result = document.querySelector('#demo-result');
const simulate = document.querySelector('#simulate');
let timer;
for (const [id,name] of browsers) {
  for (const select of [source,destination]) {
    const option = document.createElement('option'); option.value=id; option.textContent=name; select.append(option);
  }
}
const query = new URLSearchParams(location.search);
const validBrowser = value => browsers.some(browser => browser[0] === value);
source.value=validBrowser(query.get('from'))?query.get('from'):'zen';
destination.value=validBrowser(query.get('to'))?query.get('to'):'dia';
const familySelect=document.querySelector('#family');
if(['all','chromium','firefox','safari'].includes(query.get('family'))) familySelect.value=query.get('family');
function syncURL(){
 const params=new URLSearchParams();
 params.set('from',source.value);params.set('to',destination.value);params.set('family',familySelect.value);
 history.replaceState(null,'',`${location.pathname}?${params}${location.hash}`);
}
function routeChanged() {
  syncURL();
  clearTimeout(timer); simulate.disabled=false; document.querySelector('.demo').classList.remove('is-running');
  const same=source.value===destination.value;
  const safari=source.value==='safari'||destination.value==='safari';
  summary.textContent=same ? 'Choose two different browsers to explore a transfer route.' : safari ? 'Guided route · Safari uses bookmark HTML. Live tabs, pins and native groups are not transferred by this route.' : 'Guided route · Bookmarks and folders; tabs, pins, groups and history depend on capture and target APIs. Native spaces may be approximated.';
  simulate.disabled=same;
  result.replaceChildren();
  const strong=document.createElement('strong'); strong.textContent='A fresh start.';
  const span=document.createElement('span'); span.textContent='Choose a route to explore what comes along.';
  result.append(strong,span);
}
source.addEventListener('change',routeChanged); destination.addEventListener('change',routeChanged);
simulate.addEventListener('click',()=>{
  simulate.disabled=true; document.querySelector('.demo').classList.add('is-running');
  result.querySelector('strong').textContent='Making the move…'; result.querySelector('span').textContent='Simulating backup, import and review.';
  timer=setTimeout(()=>{
    document.querySelector('.demo').classList.remove('is-running');
    result.querySelector('strong').textContent='Your next chapter.';
    result.querySelector('span').textContent=source.value==='safari'||destination.value==='safari'?'Simulation complete: a bookmark HTML handoff. Real transfer requires guided import.':'Simulation complete: a portable browsing setup. Real transfer requires the Mac app and guided helper.';
    simulate.disabled=false;
  },matchMedia('(prefers-reduced-motion: reduce)').matches?0:1100);
});
function filterSupport(){
 syncURL();
 const family=document.querySelector('#family').value;
 const rows=document.querySelector('#support-rows'); rows.replaceChildren();
 const shown=browsers.filter(b=>family==='all'||b[2]===family);
 for(const [id,name,type] of shown){
  const row=document.createElement('tr');
  const details=type==='safari'?'Bookmarks & history source; bookmark HTML destination. Live tabs and groups are archive-only.':type==='firefox'?'Profile capture + Firefox helper. Native Zen Essentials and spaces may be approximated.':'Profile capture + Chromium helper. Arc/Vivaldi native organization is archive-only unless exposed by APIs.';
  for(const text of [name,'Guided · Alpha',details]){const cell=document.createElement('td');cell.textContent=text;row.append(cell)}
  rows.append(row);
 }
 document.querySelector('#support-count').textContent=`${shown.length} browser${shown.length===1?'':'s'}`;
}
document.querySelector('#family').addEventListener('change',filterSupport);
routeChanged();filterSupport();
