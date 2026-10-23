// Browser boundary checks. Pass a Playwright Page pointed at a local UI server.
// This synthetic page never grants native browser access or runs a real migration.
export async function verifyPreview(page, base, screenshotDirectory) {
  const assert=(condition,message)=>{if(!condition)throw Error(message);};
  const errors=[];
  page.on('pageerror',error=>errors.push(error.message));
  await page.setViewportSize({width:1180,height:900});
  await page.goto(base+'/?demo');
  await page.getByRole('heading',{name:'Transfer your browser setup'}).waitFor();
  await page.keyboard.press('Tab');
  assert(await page.getByRole('link',{name:'Skip to transfer'}).evaluate(e=>document.activeElement===e),'Keyboard skip link must be first');
  await page.getByRole('link',{name:'Skip to transfer'}).press('Enter');
  await page.locator('#source-profile').selectOption('demo-source');
  await page.locator('#destination-profile').selectOption('demo-destination');
  assert(await page.locator('#start-transfer').isDisabled(),'Synthetic Transfer must stay disabled');
  await page.getByRole('button',{name:'Connections',exact:true}).click();
  assert(await page.locator('.connection-row').count()===2,'Synthetic connections must be visible');
  assert(await page.getByRole('button',{name:'Install connector & create pairing code'}).isDisabled(),'Pairing requires real native access and selected profile');
  await page.getByRole('button',{name:'Credentials & sessions',exact:true}).click();
  await page.getByRole('button',{name:'Review session transfer'}).click();
  assert((await page.locator('#message').innerText()).includes('consent'),'Sensitive action must require consent');
  await page.getByRole('button',{name:'Transfer',exact:true}).first().click();
  assert(!await page.locator('#message').isVisible(),'Old sensitive error must not follow view changes');
  await page.evaluate(()=>window.scrollTo(0,0));
  if(screenshotDirectory)await page.screenshot({path:screenshotDirectory+'/desktop-transfer.png',fullPage:true});
  for(const width of [760,390,320]){
    await page.setViewportSize({width,height:900});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Interface overflows at '+width);
  }
  if(screenshotDirectory)await page.screenshot({path:screenshotDirectory+'/constrained-transfer.png',fullPage:true});
  assert(errors.length===0,'Browser errors: '+errors.join(', '));
  return {checks:8,result:'passed',boundary:'Synthetic browser rendering and interaction; native OS/browser runtime not proven'};
}

export async function verifyCredentialUI(page, base) {
  await page.addInitScript(()=>{
    let protectedExport=false,staged=false;
    window.__TAURI__={core:{invoke:async(name,args)=>{
      if(name==='choose_path')return '/synthetic/passwords.csv';
      if(name!=='engine')throw Error('Unexpected native operation');
      const r=args.request;
      switch(r.command){
        case 'status':return {platform:'Synthetic API fixture',connections:[],receipts:[]};
        case 'sessions.status':return {sessions:[]};
        case 'credentials.list':return {vaults:protectedExport?[{vaultId:'synthetic-vault',count:2,createdAt:1792756800}]:[],stages:[]};
        case 'credentials.protect':if(!r.consent)throw Error('Consent absent');protectedExport=true;return {vaultId:'synthetic-vault',count:2,sourcePreserved:true};
        case 'credentials.stage':if(!r.consent)throw Error('Consent absent');staged=true;return {stageId:'synthetic-stage',temporaryPath:'/synthetic/temporary/import.csv',expiresAt:1792757700};
        case 'credentials.confirmImport':if(!staged||!r.confirmed)throw Error('Confirmation absent');staged=false;return {cleaned:true,outcome:'user-confirmed',verified:false};
        default:throw Error('Unexpected request');
      }
    }}};
  });
  await page.goto(base);
  await page.getByRole('button',{name:'Credentials & sessions',exact:true}).click();
  await page.getByRole('button',{name:'Choose password CSV'}).click();
  await page.locator('#credential-passphrase').fill('synthetic-only-passphrase');
  await page.locator('#credential-consent').check();
  await page.getByRole('button',{name:'Protect credential export',exact:true}).click();
  await page.getByText('Protected 2 credential records.',{exact:false}).waitFor();
  if(await page.locator('#credential-passphrase').inputValue())throw Error('Protect passphrase remained in input');
  if(await page.locator('#credential-consent').isChecked())throw Error('Protect consent was silently reused');
  await page.locator('#import-passphrase').fill('synthetic-only-passphrase');
  await page.locator('#import-consent').check();
  await page.getByRole('button',{name:'Prepare temporary import file'}).click();
  await page.locator('#credential-staged').waitFor({state:'visible'});
  if(await page.locator('#import-passphrase').inputValue())throw Error('Import passphrase remained in input');
  await page.getByRole('button',{name:'I imported it · clean up'}).click();
  await page.getByText('Import marked user-confirmed.',{exact:false}).waitFor();
  if(await page.locator('#credential-staged').isVisible())throw Error('Temporary path remained after cleanup');
  return {checks:4,result:'passed',boundary:'Sensitive UI wiring with a synthetic native API; vault cryptography is tested separately'};
}

export async function verifyPlatformAvailability(page, base) {
  await page.addInitScript(()=>{
    window.__TAURI__={core:{invoke:async(name,args)=>{
      if(name!=='engine'||args.request.command!=='status')throw Error('Unexpected fixture operation');
      const platform=new URLSearchParams(location.search).get('platform');
      return {platform,architecture:'synthetic',connections:[],receipts:[],browsers:['helium','arc','zen','dia','chrome','firefox','brave','safari','edge','opera','vivaldi'].map(browser=>({browser,connectorSupported:['chrome','firefox','brave','edge','opera','vivaldi'].includes(browser)}))};
    }}};
  });
  for(const platform of ['linux','windows']){
    await page.goto(base+'/?platform='+platform);
    await page.waitForFunction(()=>document.querySelector('#platform').textContent.includes(new URLSearchParams(location.search).get('platform')));
    for(const id of ['source-browser','destination-browser','connect-browser']){
      const values=await page.locator('#'+id+' option').evaluateAll(options=>options.map(o=>o.value));
      if(values.includes('safari'))throw Error('Safari exposed outside macOS');
      if(platform==='linux'&&(values.includes('arc')||values.includes('dia')))throw Error('Unavailable Linux browser exposed');
      if(platform==='windows'&&(!values.includes('arc')||!values.includes('dia')))throw Error('Available Windows browser hidden');
    }
    if(platform==='windows'&&!await page.locator('#connect-browser option[value="dia"]').isDisabled())throw Error('Unimplemented Dia connector advertised');
  }
  return {checks:7,result:'passed',boundary:'Synthetic platform availability and connector capability UI'};
}
