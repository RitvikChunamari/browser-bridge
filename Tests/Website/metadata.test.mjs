import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,readdirSync,existsSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
const root=resolve('website');
const pages=['index.html',...readdirSync(resolve(root,'guides')).filter(p=>p.endsWith('.html')).map(p=>'guides/'+p)];
const sitemap=readFileSync(resolve(root,'sitemap.xml'),'utf8');
test('Search pages have unique canonical metadata and indexable substantive content',()=>{
 assert.ok(pages.length>=4,'home and at least three useful guides');
 const titles=new Set();
 for(const file of pages){const html=readFileSync(resolve(root,file),'utf8');const canonical=html.match(/rel="canonical" href="([^"]+)"/)?.[1];
 assert.equal(canonical,'https://ritvikchunamari.github.io/browser-bridge/'+(file==='index.html'?'':file));
 assert.ok(sitemap.includes(`<loc>${canonical}</loc>`),file+' included in sitemap');
 const title=html.match(/<title>(.*?)<\/title>/)?.[1];assert.ok(title?.length>15);assert.ok(!titles.has(title));titles.add(title);
 assert.equal((html.match(/name="description"/g)||[]).length,1);assert.ok(!/noindex/.test(html));
 assert.ok(html.includes(`property="og:url" content="${canonical}"`));
 assert.ok(html.includes('name="twitter:card" content="summary_large_image"'));
 assert.ok(html.includes('https://ritvikchunamari.github.io/browser-bridge/assets/social-card.png'));
 if(file!=='index.html')assert.ok(html.replace(/<[^>]*>/g,' ').split(/\s+/).length>300,'guide has substantive static content: '+file);
 for(const match of html.matchAll(/(?:href|src)="([^"#?]+)(?:[?#][^"]*)?"/g)){const href=match[1];if(/^(https?:|mailto:)/.test(href))continue;assert.ok(existsSync(resolve(dirname(resolve(root,file)),href)),`${file}: missing ${href}`)}
 }
});
test('SoftwareApplication schema reflects free Mac release without fabricated ratings',()=>{
 const html=readFileSync(resolve(root,'index.html'),'utf8');const data=JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
 assert.equal(data['@type'],'SoftwareApplication');assert.equal(data.operatingSystem,'macOS 14 or later');assert.equal(data.offers.price,'0');assert.equal(data.license,'https://opensource.org/license/mit');assert.ok(!data.aggregateRating);assert.ok(!data.review);
 const image=readFileSync(resolve(root,'assets/social-card.png'));assert.equal(image.readUInt32BE(16),1200);assert.equal(image.readUInt32BE(20),630);
 assert.ok(html.includes('Intel runtime is unverified'));assert.ok(html.includes('Apple silicon only'));
 assert.ok(!existsSync(resolve(root,'robots.txt')),'project site cannot govern host-root robots');
});
