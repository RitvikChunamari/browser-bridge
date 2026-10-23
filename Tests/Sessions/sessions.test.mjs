import test from 'node:test';
import assert from 'node:assert/strict';
import {runSession,normalizeOrigins} from '../../Resources/Connector/sessions.mjs';
const base={name:'session',value:'never-cache-this',domain:'example.test',path:'/',hostOnly:true,storeId:'0',secure:true,httpOnly:true,sameSite:'lax',session:true};
const api=cookie=>({permissions:{async contains(){return true}},cookies:{async getAll(){return [structuredClone(cookie)]},async set(){throw Error('Must not write')}}});
test('exact-origin permission is required before reading cookies',async()=>{let read=false;const a=api(base);a.permissions.contains=async()=>false;a.cookies.getAll=async()=>{read=true;return []};await assert.rejects(runSession(a,'cookies.capture',{sessionId:'permission',origins:['https://example.test'],publicKey:'invalid'}),/Grant cookies/);assert.equal(read,false);});
test('partition, container, domain-wide and insecure cookies fail closed',async()=>{for(const change of [{partitionKey:{topLevelSite:'https://other.test'}},{storeId:'firefox-container-2'},{hostOnly:false,domain:'.example.test'},{secure:false}]){await assert.rejects(runSession(api({...base,...change}),'cookies.capture',{sessionId:'blocked',origins:['https://example.test'],publicKey:'invalid'}),/Partitioned|Domain-wide|Non-secure/);}});
test('origin selection excludes paths, credentials and cross-port assumptions',()=>{for(const origin of ['https://example.test/path','https://name:password@example.test','http://example.test','https://example.test:8443'])assert.throws(()=>normalizeOrigins([origin]));assert.deepEqual(normalizeOrigins(['https://example.test/','https://example.test']),['https://example.test']);});
test('lost ephemeral browser keys require restaging instead of replaying cookies',async()=>{await assert.rejects(runSession(api(base),'cookies.apply',{sessionId:'lost',origins:['https://example.test'],sealed:{}}),/Ephemeral keys expired/);});

test('sealed transfer preflights destination conflicts before any cookie write',async()=>{
 const origins=['https://example.test'],sessionId=crypto.randomUUID(),enc=new TextEncoder();
 const app=await crypto.subtle.generateKey({name:'ECDH',namedCurve:'P-256'},false,['deriveBits']);const publicKey=Buffer.from(await crypto.subtle.exportKey('raw',app.publicKey)).toString('base64');
 const source=await runSession(api(base),'cookies.capture',{sessionId,origins,publicKey});assert.equal(JSON.stringify(source).includes('never-cache-this'),false);
 let writes=0;const existing={...base,value:'keep-existing-sign-in'};const destination=api(existing);destination.cookies.set=async()=>{writes++;};
 const prepared=await runSession(destination,'cookies.prepare',{sessionId,origins});
 const aad=role=>enc.encode(`browser-bridge-cookie-v1|${sessionId}|${role}|${origins.join('\n')}`);
 async function derived(publicKey,role){const peer=await crypto.subtle.importKey('raw',Buffer.from(publicKey,'base64'),{name:'ECDH',namedCurve:'P-256'},false,[]);const shared=await crypto.subtle.deriveBits({name:'ECDH',public:peer},app.privateKey,256);const material=await crypto.subtle.importKey('raw',shared,'HKDF',false,['deriveKey']);return crypto.subtle.deriveKey({name:'HKDF',hash:'SHA-256',salt:enc.encode('browser-bridge-cookie-v1'),info:aad(role)},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);}
 const clear=await crypto.subtle.decrypt({name:'AES-GCM',iv:Buffer.from(source.sealed.nonce,'base64'),additionalData:aad('source')},await derived(source.sealed.publicKey,'source'),Buffer.from(source.sealed.ciphertext,'base64'));const nonce=crypto.getRandomValues(new Uint8Array(12));const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:aad('destination')},await derived(prepared.publicKey,'destination'),clear);
 const sealed={publicKey,nonce:Buffer.from(nonce).toString('base64'),ciphertext:Buffer.from(ciphertext).toString('base64')};
 await assert.rejects(runSession(destination,'cookies.apply',{sessionId,origins,sealed}),/Destination cookie conflict/);assert.equal(writes,0);assert.equal(existing.value,'keep-existing-sign-in');await runSession(destination,'cookies.cleanup',{sessionId,origins});
});
