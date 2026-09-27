// Space-budget check (storyboard "Space budget — Concepts C and D"). For each scene's key frames it calls
// renderAt(t), measures every visible VoiceFlow surface with getBoundingClientRect() and asserts the budgets;
// it also asserts that no VoiceFlow text renders above 16 px (title card / chapter captions excluded).
// Run from design/concept-videos:  node concept-d-timeline/check-budget.mjs
import { chromium } from 'playwright';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const SCREEN = 1920 * 1080;
const BUDGET = {
  slip:    { w: 460, h: 100, label: 'dictation slip' },
  picker:  { w: 460, h: 90,  label: 'alternatives menu (adds ≤ 90 px)' },
  reader:  { w: 540, h: 110, label: 'reader' },
  chip:    { w: 360, h: 32,  label: 'receipt / one-liner' },
  sheet:   { w: 1100, h: 520, area: 0.30, label: 'control center / automations' },
  strip:   { w: 260, h: 320, label: 'capture record' },
  receipt: { area: 0.30, label: 'payload' },
  stub:    { area: 0.30, label: 'payload (stub)' },
};
// key frames are derived from the film's own timeline (window.T) so they follow any re-timing
const frameList = T => {
  const { s2, s3, s4, s5, s6, s7 } = T;
  return [
    [s2.rev2 + 0.2, 'slip'], [s2.e1Apply + 0.2, 'slip'], [s2.click2 + 0.5, 'slip'], [s2.swap + 0.4, 'slip'], [s2.e2Collapse + 0.2, 'slip'], [s2.e2Return + 0.3, 'slip'], [s3.route + 1, 'slip'], [s3.thinkLine + 0.4, 'slip'], [s3.show.end, 'slip'],
    [s2.receipt[0] + 0.5, 'chip'], [s7.chip[0] + 0.5, 'chip'],
    [s3.read.start + 0.5, 'reader'], [s3.read.sentences[1].start + 1, 'reader'], [s3.read.sentences[3].start + 1, 'reader'], [s3.read2.sentences[1].start, 'reader'],
    [s4.rowsIn + 0.8, 'sheet'], [s4.hold1, 'sheet'], [s4.regroupAnim + s4.regroupDur + 0.5, 'sheet'], [s4.resolveAnim + s4.resolveDur + 0.5, 'sheet'], [s4.clickRes + 0.6, 'sheet'], [s4.clickP1 + 0.8, 'sheet'], [s4.approved + 0.8, 'sheet'], [s5.fName + 0.5, 'sheet'], [s5.stripeOn + 0.5, 'sheet'], [s5.active + 1.5, 'sheet'],
    [s6.c0 + 1, 'strip'], [s6.frame1 + 1, 'strip'], [s6.frame3 + 0.5, 'strip'], [s6.frame4 + 2, 'strip'], [s6.front1 + 1, 'strip'], [s6.hudStop, 'strip'],
    [s7.receipt + 1.5, 'receipt'], [s7.copy - 0.2, 'receipt'], [s7.copy + 0.4, 'stub'],
  ];
};
const browser = await chromium.launch();
const page = await (await browser.newContext({ viewport: { width: 1920, height: 1080 } })).newPage();
page.on('pageerror', e => console.error('[pageerror]', e.message));
await page.goto(pathToFileURL(path.resolve(new URL('.', import.meta.url).pathname, 'film.html')).href);
await page.evaluate(async () => { await document.fonts.ready; });
const FRAMES = frameList(await page.evaluate(() => JSON.parse(JSON.stringify(window.T))));
const maxima = {}; const failures = []; let maxFont = { size: 0 };
for (const [t, expect] of FRAMES) {
  const m = await page.evaluate(async (t) => {
    await window.renderAt(t);
    const st = window.FILM && window.__lastSurf ? window.__lastSurf : null;
    const r = document.getElementById('paper').getBoundingClientRect();
    const state = window.__surfState;
    const out = { state, paper: { w: r.width, h: r.height, x: r.left, y: r.top } };
    const pk = document.getElementById('picker'); const pr = pk.getBoundingClientRect();
    if (pk.style.visibility === 'visible' && pr.width > 0) out.picker = { w: pr.width, h: pr.height };
    const tear = document.getElementById('tear'); if (getComputedStyle(tear).display !== 'none') { const tr = tear.getBoundingClientRect(); out.tear = { w: tr.width, h: tr.height }; }
    // font sizes of visible text inside VoiceFlow surfaces (thumbnails are scaled miniatures of the page, not product text)
    const roots = [document.getElementById('paper'), pk, tear, ...document.querySelectorAll('.mk-label, .mk-tag')];
    let mx = { size: 0 };
    const visible = el => { const cs = getComputedStyle(el); if (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0) return false; const b = el.getBoundingClientRect(); return b.width > 0 && b.height > 0 && b.right > 0 && b.left < 1920; };
    for (const root of roots) {
      if (!root || !visible(root)) continue;
      const els = [root, ...root.querySelectorAll('*')];
      for (const el of els) {
        if (el.closest('.thumb-inner')) continue;
        if (!el.childNodes.length || ![...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim())) continue;
        if (!visible(el)) continue;
        const fs = parseFloat(getComputedStyle(el).fontSize);
        if (fs > mx.size) mx = { size: fs, text: el.textContent.trim().slice(0, 40), cls: el.className };
      }
    }
    out.maxFont = mx;
    return out;
  }, t);
  const state = m.state || expect;
  const key = state === 'stub' ? 'stub' : state;
  const B = BUDGET[key];
  const rec = maxima[key] ||= { w: 0, h: 0, area: 0, at: null };
  if (m.paper.w > rec.w) rec.w = m.paper.w; if (m.paper.h > rec.h) rec.h = m.paper.h;
  const area = m.paper.w * m.paper.h / SCREEN; if (area > rec.area) { rec.area = area; rec.at = t; }
  const fail = (msg) => failures.push(`t=${t}s [${key}] ${msg}`);
  if (state !== expect) fail(`expected state ${expect}, got ${state}`);
  if (B) {
    if (B.w && m.paper.w > B.w + 0.5) fail(`width ${m.paper.w.toFixed(1)} > ${B.w}`);
    if (B.h && m.paper.h > B.h + 0.5) fail(`height ${m.paper.h.toFixed(1)} > ${B.h}`);
    if (B.area && area > B.area) fail(`area ${(area * 100).toFixed(1)}% > ${B.area * 100}%`);
  }
  if (m.picker) { const p = maxima.picker ||= { w: 0, h: 0 }; p.w = Math.max(p.w, m.picker.w); p.h = Math.max(p.h, m.picker.h); if (m.picker.h > 90.5) fail(`picker height ${m.picker.h} > 90`); }
  if (m.tear) { const p = maxima.tear ||= { w: 0, h: 0 }; p.w = Math.max(p.w, m.tear.w); p.h = Math.max(p.h, m.tear.h); }
  if (m.maxFont.size > maxFont.size) maxFont = { ...m.maxFont, t };
  if (m.maxFont.size > 16.01) fail(`text ${m.maxFont.size}px > 16px: "${m.maxFont.text}" (${m.maxFont.cls})`);
}
await browser.close();
console.log('Measured maxima per surface (px, % of 1920×1080):');
for (const k in maxima) { const r = maxima[k]; console.log(`  ${k.padEnd(8)} ${String(Math.round(r.w)).padStart(5)} × ${String(Math.round(r.h)).padStart(4)}${r.area != null ? `   ${(r.area * 100).toFixed(1)}%` : ''}${BUDGET[k] ? `   (budget ${BUDGET[k].w || '—'} × ${BUDGET[k].h || '—'}${BUDGET[k].area ? `, ≤ ${BUDGET[k].area * 100}%` : ''})` : ''}`); }
console.log(`Largest VoiceFlow text: ${maxFont.size}px "${maxFont.text}" at t=${maxFont.t}s (limit 16px)`);
if (failures.length) { console.log('\nFAILURES:'); failures.forEach(f => console.log('  ' + f)); process.exit(1); }
console.log('\nAll budgets pass.');
