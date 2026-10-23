import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
const [root,runner,target]=process.argv.slice(2);
if(!root||!runner||!target)throw new Error('Usage: package-report BUNDLE_DIRECTORY RUNNER TARGET');
async function inventory(dir){const result=[];for(const entry of await readdir(dir,{withFileTypes:true})){const path=join(dir,entry.name);if(entry.isDirectory())result.push(...await inventory(path));else if(/\.(exe|deb|rpm|AppImage)$/.test(entry.name)){const bytes=await readFile(path);result.push({file:relative(root,path),bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});}}return result;}
const packages=await inventory(root);
if(!packages.length)throw new Error('No installable packages were produced');
await writeFile(join(root,'package-report.json'),JSON.stringify({schema:1,runner,target,packages,checks:{compilation:'passed',syntheticJourney:'passed',installerDesktopRuntime:'pending',realBrowserTransfer:'pending'},automaticRoutes:[],warning:'A package build does not verify Windows 10/11, Debian/Fedora or interactive browser behavior. Unsigned preview; use only disposable profiles until desktop validation.'},null,2)+'\n');
console.log(`Recorded ${packages.length} packages; real desktop/browser runtime checks pending.`);
