// Deterministic frame renderer for the concept films.
//
// A film is one HTML page that defines:
//   window.DURATION      total length in seconds
//   window.renderAt(t)   sets every visual to its state at time t (seconds);
//                        may be async. Must be a pure function of t: calling
//                        renderAt(40) then renderAt(3) must look exactly like
//                        calling renderAt(3) on a fresh page.
//   window.READY         optional promise the page resolves once images/fonts load
//
// CSS @keyframes animations are allowed for ambient loops only; after each
// renderAt the harness pauses every animation and pins currentTime to t.
// CSS transitions are NOT allowed (they would run in wall-clock time).
//
// Usage:
//   node render.mjs --html film.html --stills 0,12.5,40 --stills-dir out/stills
//   node render.mjs --html film.html --out film.mp4 [--fps 30] [--workers 6] [--from 0 --to 20]
//   node render.mjs --html film.html --contact out/sheet.png --every 5   (grid of stills)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : true]);
  return acc;
}, []));

const html = path.resolve(args.html);
const url = pathToFileURL(html).href;
const W = +(args.width || 1920), H = +(args.height || 1080);
const fps = +(args.fps || 30);

async function openPage(browser) {
  const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  page.on('pageerror', e => console.error('[pageerror]', e.message));
  page.on('console', m => { if (m.type() === 'error') console.error('[console]', m.text()); });
  await page.goto(url);
  await page.evaluate(async () => {
    await document.fonts.ready;
    if (window.READY) await window.READY;
  });
  return page;
}

async function frameAt(page, t) {
  await page.evaluate(async (t) => {
    await window.renderAt(t);
    for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
  }, t);
}

const browser = await chromium.launch({ args: ['--font-render-hinting=none', '--disable-lcd-text'] });
try {
  const probe = await openPage(browser);
  const duration = await probe.evaluate(() => window.DURATION);
  if (!duration || typeof duration !== 'number') throw new Error('window.DURATION missing');

  if (args.stills) {
    const dir = path.resolve(args['stills-dir'] || 'stills');
    fs.mkdirSync(dir, { recursive: true });
    const times = String(args.stills).split(',').map(Number);
    for (const t of times) {
      await frameAt(probe, t);
      const f = path.join(dir, `still-${t.toFixed(2).padStart(7, '0')}.png`);
      await probe.screenshot({ path: f });
      console.log(f);
    }
  }

  if (args.contact) {
    // Contact sheet: a grid of downscaled stills every N seconds, for fast review.
    const every = +(args.every || 5);
    const times = [];
    for (let t = +(args.from || 0); t < +(args.to || duration); t += every) times.push(t);
    const shots = [];
    for (const t of times) { await frameAt(probe, t); shots.push({ t, b64: (await probe.screenshot({ type: 'jpeg', quality: 80 })).toString('base64') }); }
    const cols = 4, cw = 480, ch = 270;
    const sheet = await (await browser.newContext({ viewport: { width: cols * cw, height: Math.ceil(shots.length / cols) * (ch + 22) } })).newPage();
    await sheet.setContent(`<body style="margin:0;background:#000;display:grid;grid-template-columns:repeat(${cols},${cw}px);font:14px system-ui;color:#fff">${
      shots.map(s => `<div><img src="data:image/jpeg;base64,${s.b64}" style="width:${cw}px;height:${ch}px;display:block"><div style="height:22px;padding-left:6px">${s.t.toFixed(1)}s</div></div>`).join('')}</body>`);
    await sheet.screenshot({ path: path.resolve(args.contact), fullPage: true });
    console.log(path.resolve(args.contact));
  }

  if (args.out) {
    const out = path.resolve(args.out);
    const from = +(args.from || 0), to = +(args.to || duration);
    const total = Math.round((to - from) * fps);
    const workers = Math.max(1, Math.min(+(args.workers || 6), total));
    const per = Math.ceil(total / workers);
    const tmp = fs.mkdtempSync(path.join(path.dirname(out), '.chunks-'));
    let done = 0;
    const started = Date.now();
    await Promise.all(Array.from({ length: workers }, async (_, w) => {
      const a = w * per, b = Math.min(total, a + per);
      if (a >= b) return;
      const page = await openPage(browser);
      const chunk = path.join(tmp, `chunk-${String(w).padStart(3, '0')}.mp4`);
      const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', String(fps), chunk], { stdio: ['pipe', 'inherit', 'inherit'] });
      for (let i = a; i < b; i++) {
        await frameAt(page, from + i / fps);
        const buf = await page.screenshot({ type: 'jpeg', quality: 94 });
        if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
        done++;
        if (done % 150 === 0) {
          const el = (Date.now() - started) / 1000;
          console.log(`${done}/${total} frames · ${el.toFixed(0)}s elapsed · ~${((total - done) * el / done).toFixed(0)}s left`);
        }
      }
      ff.stdin.end();
      await new Promise((res, rej) => ff.on('close', c => c === 0 ? res() : rej(new Error('ffmpeg chunk ' + w + ' exited ' + c))));
      await page.context().close();
    }));
    const list = path.join(tmp, 'list.txt');
    fs.writeFileSync(list, fs.readdirSync(tmp).filter(f => f.endsWith('.mp4')).sort().map(f => `file '${path.join(tmp, f)}'`).join('\n'));
    await new Promise((res, rej) => spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-movflags', '+faststart', out], { stdio: 'inherit' })
      .on('close', c => c === 0 ? res() : rej(new Error('concat failed'))));
    fs.rmSync(tmp, { recursive: true, force: true });
    console.log(`wrote ${out} (${total} frames, ${((Date.now() - started) / 1000).toFixed(0)}s)`);
  }
} finally {
  await browser.close();
}
