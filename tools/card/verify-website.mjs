import {chromium} from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import assert from 'node:assert/strict';
import sharp from 'sharp';
const root=path.resolve('../website-card');
const headers=JSON.parse(fs.readFileSync(`${root}/vercel.headers.json`)).headers[0].headers;
const server=http.createServer((req,res)=>{
 const pathname=new URL(req.url,'http://localhost').pathname;
 if(pathname==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><html><head><link rel="icon" href="data:,"></head><body style="margin:0;background:#f5f1e9"><iframe title="card" src="/funding-card/index.html" style="display:block;width:100vw;height:100vh;border:0;background:transparent"></iframe></body></html>');return;}
 const file=path.join(root,'public',pathname);
 if(!file.startsWith(root+'/public/')||!fs.existsSync(file)){res.writeHead(404);res.end();return;}
 headers.forEach(h=>res.setHeader(h.key,h.value));
 res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.txt':'text/plain'})[path.extname(file)]||'application/octet-stream');res.end(fs.readFileSync(file));
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',args:['--enable-unsafe-swiftshader','--ignore-gpu-blocklist']});
const errors=[],requests=[];
try{
 const page=await browser.newPage({viewport:{width:900,height:900},deviceScaleFactor:1});
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(!r.url().startsWith(origin)&&!r.url().startsWith('data:'))requests.push(r.url());});
 await page.addInitScript(()=>{window.cspViolations=[];document.addEventListener('securitypolicyviolation',e=>window.cspViolations.push(e.violatedDirective));});
 await page.goto(origin+'/funding-card/index.html');
 await page.waitForFunction(()=>window.fundingCard && document.body.dataset.state === "ready");
 await page.evaluate(()=>window.fundingCard.seek(0));
 const png=await page.screenshot({omitBackground:true});
 await sharp(png).png().toFile(`${root}/public/funding-card/poster.png`);
 const raw=await sharp(png).raw().toBuffer({resolveWithObject:true});
 assert.equal(raw.info.channels,4);assert.equal(raw.data[3],0);
 assert.equal(raw.data[(450*900+450)*4+3],255);
 await page.goto(origin);
 const f=page.frames()[1];await f.waitForFunction(()=>window.fundingCard && document.body.dataset.state === "ready");
 for(const [name,t] of [['front',0],['grazing',5],['edge',7],['back',12]]){
  await f.evaluate(t=>window.fundingCard.seek(t),t);
  await page.screenshot({path:`${root}/evidence/${name}-light.png`});
 }
 await page.evaluate(()=>document.body.style.background='linear-gradient(120deg,#4935a0,#16b8a6)');
 await f.evaluate(()=>window.fundingCard.seek(0));
 await page.screenshot({path:`${root}/evidence/front-color.png`});
 await f.locator('canvas').focus();await page.keyboard.press('ArrowRight');
 assert((await f.evaluate(()=>window.fundingCard.state())).offset>0);
 await page.keyboard.press('Home');
 await f.waitForFunction(()=>window.fundingCard.state().phase>0);
 await page.emulateMedia({reducedMotion:'reduce'});await page.waitForTimeout(100);
 const phase=await f.evaluate(()=>window.fundingCard.state().phase);
 await page.waitForTimeout(250);assert.equal(await f.evaluate(()=>window.fundingCard.state().phase),phase);
 await page.setViewportSize({width:390,height:390});
 await page.screenshot({path:`${root}/evidence/mobile.png`});
 const violations=await f.evaluate(()=>window.cspViolations);
 assert.deepEqual(violations,[]);assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
 await f.evaluate(()=>document.querySelector('canvas').getContext('webgl2').getExtension('WEBGL_lose_context').loseContext());
 await f.waitForFunction(()=>document.body.dataset.state==='fallback');
 assert(await f.locator('img').evaluate(i=>i.complete&&i.naturalWidth===900));
 await page.screenshot({path:`${root}/evidence/fallback.png`});
 const noJS=await browser.newContext({javaScriptEnabled:false});const p=await noJS.newPage();await p.goto(origin+'/funding-card/index.html');assert(await p.locator('img').isVisible());await noJS.close();
 const files=fs.readdirSync(`${root}/public/funding-card`);const sizes=Object.fromEntries(files.map(n=>[n,fs.statSync(`${root}/public/funding-card/${n}`).size]));
 const report={browser:browser.version(),alpha:{corner:0,cardCenter:255},passed:['strict CSP without unsafe-inline/eval/blob','no external requests','front/grazing/edge/back','light and colored backgrounds','keyboard','reduced motion','mobile viewport','context loss transparent fallback','JavaScript disabled fallback'],errors,violations,requests,sizes,totalBytes:Object.values(sizes).reduce((a,b)=>a+b,0),limitations:['Local Chrome only; no physical-device or live Vercel verification','No host Next.js app supplied; production host build not run','Frame/GPU performance not benchmarked']};
 fs.writeFileSync(`${root}/evidence/verification.json`,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{await browser.close();server.close();}
