import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const out = '../website-card/public/funding-card';
fs.mkdirSync(out, {recursive:true});
const three = gunzipSync(Buffer.from(fs.readFileSync('media/vendor/three-r162.txt','utf8'),'base64'));
assert.equal(createHash('sha256').update(three).digest('hex'),'ecd9f6b9bc1a12efdf14d13e4c610c012903c141a77d967d3f500bc727f0896c');
fs.writeFileSync(`${out}/three.module.js`,three);
const built = gunzipSync(Buffer.from(fs.readFileSync('media/dist/runtime.txt','utf8'),'base64')).toString();
const logo = built.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/)[0];
const font = built.match(/data:font\/woff2;base64,[A-Za-z0-9+/=]+/)[0];
let source = fs.readFileSync('media/card.mjs','utf8').replace('__LOGO__',logo).replace('__FONT__',font);
// Website variant: retain the framebuffer for transparent iframe composition.
source = source.replace('preserveDrawingBuffer: true','// Retain the last frame while this transparent iframe is composited or paused.\n    preserveDrawingBuffer: true')
 .replace('location.reload();','lost = false; resize(); restart();')
 .replace('const w = innerWidth,\n      h = innerHeight;','const w = Math.max(1, innerWidth),\n      h = Math.max(1, innerHeight);')
 .replace('raf = requestAnimationFrame(tick);\n  }','if (!paused && !motion.matches || idle > 0) raf = requestAnimationFrame(tick);\n  }')
 .replace('pointer.y = e.clientY;','pointer.y = e.clientY;\n    draw();')
 .replace('idle = 4;\n  };','idle = 4;\n    restart();\n  };')
 .replace('if (e.key === "ArrowDown") pitch = Math.min(Math.PI / 6, pitch + 0.08);','if (e.key === "ArrowDown") pitch = Math.min(Math.PI / 6, pitch + 0.08);\n    restart();')
 .replace('addEventListener("resize", resize);','addEventListener("resize", () => { resize(); if (!lost) draw(); });\n  motion.addEventListener("change", restart);');
source = source
 .replace('  function resize() {', '  let viewportWidth = 0, viewportHeight = 0, viewportDpr = 0;\n  function resize() {')
 .replace('    renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5));\n    renderer.setSize(w, h);', `    const dpr = Math.min(devicePixelRatio, 1.5);
    if (w === viewportWidth && h === viewportHeight && dpr === viewportDpr) return;
    viewportWidth = w; viewportHeight = h; viewportDpr = dpr;
    renderer.setPixelRatio(dpr);
    renderer.setSize(w, h, false);`)
 .replace('    draw();\n    if (!paused && !motion.matches || idle > 0)', `    draw();
    // Reveal only after drawing inside a presentation frame, including restoration.
    if (document.body.dataset.state !== "ready") {
      canvas.hidden = false;
      document.body.dataset.state = "ready";
    }
    if (!paused && !motion.matches || idle > 0)`)
 .replace('  resize();\n  draw();\n  document.body.dataset.state = "ready";\n  restart();', `  resize();
  // Keep the transparent poster visible while GPU programs compile. Compilation
  // can be much slower on a cold browser/mobile GPU than in a warm local preview.
  await renderer.compileAsync(scene, cam);
  restart();`);
fs.writeFileSync(`${out}/card.js`,source);
for (const file of ['Three-MIT.txt','IBM-OFL.txt','Plex-OFL.txt']) fs.copyFileSync(`media/vendor/${file}`,`${out}/${file}`);
console.log('Website runtime generated without modifying NFT assets.');
