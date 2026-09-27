// Probe: load film.html, report errors/DURATION; `node probe.mjs t1,t2` renders those times (errors only).
// `node probe.mjs zoom t x y w h out.png` saves a 2× crop of the frame at t.
import { chromium } from 'playwright';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const zoom = process.argv[2] === 'zoom';
const browser = await chromium.launch({ args: ['--font-render-hinting=none', '--disable-lcd-text'] });
const page = await (await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: zoom ? 2 : 1 })).newPage();
const errs = [];
page.on('pageerror', e => errs.push('pageerror: ' + e.message + '\n' + (e.stack || '').split('\n').slice(0, 4).join('\n')));
page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') errs.push(m.type() + ': ' + m.text()); });
await page.goto(pathToFileURL(path.resolve(new URL('.', import.meta.url).pathname, 'film.html')).href);
await page.evaluate(async () => { await document.fonts.ready; });
if (zoom) {
  const [t, x, y, w, h] = process.argv.slice(3, 8).map(Number); const out = process.argv[8];
  await page.evaluate(async t => { await window.renderAt(t); for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; } }, t);
  await page.screenshot({ path: out, clip: { x, y, width: w, height: h } });
  console.log(out);
} else {
  const dur = await page.evaluate(() => window.DURATION);
  console.log('DURATION', dur.toFixed(2));
  const times = (process.argv[2] || '0').split(',').map(Number);
  for (const t of times) { try { await page.evaluate(t => window.renderAt(t), t); } catch (e) { errs.push('renderAt(' + t + '): ' + e.message); } }
  console.log(errs.length ? errs.join('\n') : 'no errors');
}
await browser.close();
