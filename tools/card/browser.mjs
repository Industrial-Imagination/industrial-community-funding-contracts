import { chromium } from "playwright-core";
import { readFileSync, writeFileSync } from "node:fs";
import sharp from "sharp";
import assert from "node:assert/strict";
const preview = process.argv.includes("--preview");
const path = preview ? "media/dist/inspect.html" : "media/dist/token.html";
const executablePath =
  process.env.CHROME_BIN ||
  (process.platform === "darwin"
    ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    : undefined);
const browser = await chromium.launch({
  executablePath,
  args: [
    "--no-sandbox",
    "--enable-unsafe-swiftshader",
    "--ignore-gpu-blocklist",
  ],
});
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  const requests = [],
    errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => {
    if (m.type() === "error") {
      errors.push(m.text());
      console.log(m.text());
    }
  });
  await page.route(/^https?:/, (r) => {
    requests.push(r.request().url());
    return r.abort();
  });
  const html = readFileSync(path);
  await page.setContent(
    '<style>*{margin:0;border:0}iframe{width:100vw;height:100vh;display:block}</style><iframe sandbox="allow-scripts"></iframe>',
  );
  await page
    .locator("iframe")
    .evaluate(
      (el, src) => (el.src = src),
      preview
        ? "data:text/html;base64," + html.toString("base64")
        : readFileSync("media/dist/animation.uri", "utf8"),
    );
  const f = page.frames()[1];
  await f.waitForFunction(
    () => document.body?.dataset.state === "ready",
    null,
    { timeout: 60000 },
  );
  assert.deepEqual(errors, []);
  await f.evaluate(() => window.fundingCard.seek(0));
  if (preview) {
    const png = await page.screenshot();
    await sharp(png).webp({ quality: 78 }).toFile("media/dist/front.webp");
    console.log("preview captured");
  } else {
    for (const [name, time] of [
      ["front", 0],
      ["grazing", 5],
      ["edge", 7],
      ["back", 12],
    ]) {
      await f.evaluate((t) => window.fundingCard.seek(t), time);
      await f.evaluate(
        () =>
          new Promise((r) =>
            requestAnimationFrame(() =>
              requestAnimationFrame(() => requestAnimationFrame(r)),
            ),
          ),
      );
      await page.screenshot({ path: "media/evidence/" + name + ".png" });
    }
    const cdp = await page.context().newCDPSession(f);
    for (const [type, x, y, buttons] of [
      ["mousePressed", 440, 450, 1],
      ["mouseMoved", 710, 850, 1],
      ["mouseReleased", 710, 850, 0],
    ])
      await cdp.send("Input.dispatchMouseEvent", {
        type,
        x,
        y,
        buttons,
        button: "left",
        clickCount: 1,
      });
    let state = await f.evaluate(() => window.fundingCard.state());
    assert(
      state.offset > 1 && state.pitch <= Math.PI / 6 && state.idle > 3,
      JSON.stringify(state),
    );
    async function key(key) {
      for (const type of ["keyDown", "keyUp"])
        await cdp.send("Input.dispatchKeyEvent", {
          type,
          key,
          code: key === " " ? "Space" : key,
        });
    }
    await key("Home");
    await f.waitForFunction(() => window.fundingCard.state().phase > 0);
    await key(" ");
    assert((await f.evaluate(() => window.fundingCard.state())).paused);
    await key(" ");
    assert((await f.evaluate(() => window.fundingCard.state())).phase > 0);
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    await f.waitForFunction(
      () => matchMedia("(prefers-reduced-motion: reduce)").matches,
    );
    const stable = await f.evaluate(() => window.fundingCard.state().phase);
    await page.waitForTimeout(300);
    assert.equal(
      (await f.evaluate(() => window.fundingCard.state())).phase,
      stable,
    );
    await page.setViewportSize({ width: 390, height: 844 });
    await f.evaluate(() => window.fundingCard.seek(12));
    await page.screenshot({ path: "media/evidence/mobile.png" });

    for (const [type, x] of [
      ["touchStart", 100],
      ["touchMove", 230],
      ["touchEnd", 0],
    ])
      await cdp.send("Input.dispatchTouchEvent", {
        type,
        touchPoints: type === "touchEnd" ? [] : [{ x, y: 400 }],
      });
    assert((await f.evaluate(() => window.fundingCard.state())).offset > 0);
    await page.setViewportSize({ width: 900, height: 900 });
    await cdp.send("Emulation.setEmulatedMedia", { features: [] });
    await key("Home");
    await f.waitForFunction(() => window.fundingCard.state().phase > 0);
    const hidden = await f.evaluate(() => {
      Object.defineProperty(document, "hidden", {
        configurable: true,
        value: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));
      return window.fundingCard.state().phase;
    });
    await page.waitForTimeout(200);
    assert.equal(
      (await f.evaluate(() => window.fundingCard.state())).phase,
      hidden,
    );
    await f.evaluate(() => {
      delete document.hidden;
      document.dispatchEvent(new Event("visibilitychange"));
    });
    const frameStats = await f.evaluate(async () => {
      const samples = [];
      let previous = performance.now();
      for (let i = 0; i < 61; i++) {
        await new Promise(requestAnimationFrame);
        const now = performance.now();
        samples.push(now - previous);
        previous = now;
      }
      samples.shift();
      return {
        meanMs: samples.reduce((a, b) => a + b) / samples.length,
        p95Ms: samples.sort((a, b) => a - b)[56],
      };
    });
    if (!process.argv.includes("--skip-video")) {
      // Sample the 24-second scene clock into a 30-fps capture stream.
      const recording = await f.evaluate(async () => {
        const c = document.querySelector("canvas"),
          out = document.createElement("canvas");
        out.width = out.height = 900;
        const context = out.getContext("2d"),
          stream = out.captureStream(30),
          rec = new MediaRecorder(stream, {
            mimeType: "video/webm;codecs=vp9",
            videoBitsPerSecond: 4500000,
          });
        const chunks = [];
        rec.ondataavailable = (e) => chunks.push(e.data);
        const done = new Promise((r) => (rec.onstop = r));
        rec.start();
        const start = performance.now();
        await new Promise((resolve) => {
          function paint() {
            const t = Math.min(24, (performance.now() - start) / 1000);
            window.fundingCard.seek(t);
            context.fillStyle = "#101012";
            context.fillRect(0, 0, 900, 900);
            context.drawImage(c, 0, 0, 900, 900);
            if (t < 24) requestAnimationFrame(paint);
            else resolve();
          }
          paint();
        });
        rec.stop();
        await done;
        stream.getTracks().forEach((t) => t.stop());
        return await new Promise((r) => {
          const reader = new FileReader();
          reader.onload = () => r(reader.result.split(",")[1]);
          reader.readAsDataURL(new Blob(chunks));
        });
      });
      writeFileSync(
        "media/evidence/rotation.webm",
        Buffer.from(recording, "base64"),
      );
    }
    await f.evaluate(() =>
      document
        .querySelector("canvas")
        .getContext("webgl2")
        .getExtension("WEBGL_lose_context")
        .loseContext(),
    );
    await f.waitForFunction(() => document.body.dataset.state === "fallback");
    assert(
      await f
        .locator("img")
        .evaluate((img) => img.complete && img.naturalWidth > 0),
    );
    const videoCheck = {};
    if (!process.argv.includes("--skip-video")) {
      const videoPage = await browser.newPage();
      Object.assign(
        videoCheck,
        await videoPage.evaluate(async (base64) => {
          const video = document.createElement("video");
          const loaded = new Promise((yes, no) => {
            video.onloadedmetadata = yes;
            video.onerror = no;
          });
          video.src = "data:video/webm;base64," + base64;
          await loaded;
          const samples = [];
          for (const t of [1, 7, 13, 19, 23.6]) {
            const seeked = new Promise((yes, no) => {
              video.onseeked = yes;
              video.onerror = no;
            });
            video.currentTime = t;
            await seeked;
            const thumb = document.createElement("canvas");
            thumb.width = thumb.height = 64;
            const ctx = thumb.getContext("2d");
            ctx.drawImage(video, 0, 0, 64, 64);
            const pix = ctx.getImageData(0, 0, 64, 64).data;
            let sum = 0;
            for (let i = 0; i < pix.length; i += 4) sum += pix[i];
            samples.push([t, sum / 4096]);
          }
          return {
            duration: video.duration,
            width: video.videoWidth,
            height: video.videoHeight,
            samples,
          };
        }, readFileSync("media/evidence/rotation.webm").toString("base64")),
      );
      assert(
        videoCheck.duration > 23.5 &&
          videoCheck.duration < 24.5 &&
          videoCheck.width === 900,
      );
      assert(videoCheck.samples[0][1] > videoCheck.samples[1][1] * 2);
      await videoPage.close();
    }
    assert.deepEqual(requests, []);
    assert.deepEqual(errors, []);
    writeFileSync(
      "media/evidence/browser.json",
      JSON.stringify(
        {
          browser: browser.version(),
          viewport: "900x900",
          frameStats,
          videoCheck,
          requests,
          passed: [
            "sandbox tokenHTML",
            "drag",
            "touch",
            "idle resume",
            "reduced motion",
            "resize",
            "hidden pause",
            "keyboard",
            "context loss",
          ],
        },
        null,
        2,
      ),
    );
  }
} finally {
  await browser.close();
}
