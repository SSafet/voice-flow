// Space-budget check for Concept C (storyboard "Space budget — Concepts C and D").
// Renders the key frame of every scene, measures each VoiceFlow surface with getBoundingClientRect(),
// asserts the budgets, and checks that no VoiceFlow text is larger than 16 px. Exits 1 on failure.
//   node concept-c-island/check-budget.mjs        (run from design/concept-videos/)
import { chromium } from 'playwright';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const url = pathToFileURL(path.resolve(new URL('.', import.meta.url).pathname, 'film.html')).href;
const AREA = 1920 * 1080, SHEET_MAX = 0.30 * AREA;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto(url);
await page.evaluate(async () => { await document.fonts.ready; });
const T = await page.evaluate(() => JSON.parse(JSON.stringify(window.FILM.T)));

// [label, time, budget]  budget: island [w,h] | 'sheet' (≤ 30% of the screen) ; extras: dropdown, record
const FRAMES = [
  ['dictation · streaming',        T.s2.u1.words[10].at + 0.3,               { island: [460, 100] }],
  ['dictation · edit 1 inserted',  T.s2.e1Swap + 0.35,                       { island: [460, 100] }],
  ['dictation · alternatives',     T.s2.ptr3 + 0.3,                          { island: [460, 100], dropdown: 90 }],
  ['dictation · edit 2 at start',  T.s2.e2Swap + 0.4,                        { island: [460, 100] }],
  ['receipt · sent to Notion',     T.s2.receipt[0] + 0.8,                    { island: [360, 32] }],
  ['FLORA · ask streaming',        T.s3.ask.words[10].at,                    { island: [460, 100] }],
  ['FLORA · thinking',             T.s3.thinkLine + 0.6,                     { island: [460, 100] }],
  ['reader · FLORA reply',         T.s3.read.sentences[1].words[3].at,       { island: [540, 128] }],
  ['reader · article',             T.s3.read2.sentences[0].words[3].at,      { island: [540, 128] }],
  ['control center · by project',  T.s4.open + 2.5,                          { island: 'sheet' }],
  ['control center · regrouped',   T.s4.regroupAnim + 1.5,                   { island: 'sheet' }],
  ['control center · resolved',    T.s4.resolveAnim + 1.5,                   { island: 'sheet' }],
  ['control center · resolved tab',T.s4.clickRes + 1.0,                      { island: 'sheet' }],
  ['control center · priority 1',  T.s4.clickP1 + 1.0,                       { island: 'sheet' }],
  ['automations · draft',          T.s5.fAccess + 0.8,                       { island: 'sheet' }],
  ['automations · active',         T.s5.list + 1.0,                          { island: 'sheet' }],
  ['automations · all streams',    T.s5.clickGl + 1.0,                       { island: 'sheet' }],
  ['talk + mark · recording',      T.s6.a2.start + 0.5,                      { island: [360, 64], record: true }],
  ['talk + mark · thumbnail drop', T.s6.shot1 + 1.0,                         { island: [360, 64], record: true, thumb: [260, 320] }],
  ['talk + mark · 4 marks',        T.s6.cap2 + 0.5,                          { island: [360, 64], record: true }],
  ['payload',                      T.s7.sheet + 2.0,                         { island: 'sheet' }],
  ['receipt · copied',             T.s7.receipt[0] + 0.8,                    { island: [360, 32] }],
];

const maxima = {}; let failures = 0;
const note = (k, w, h) => { const m = maxima[k] || { w: 0, h: 0 }; m.w = Math.max(m.w, w); m.h = Math.max(m.h, h); maxima[k] = m; };
const fail = msg => { failures++; console.log('  FAIL  ' + msg); };

for (const [label, t, b] of FRAMES) {
  const m = await page.evaluate(async (t) => {
    await window.renderAt(t);
    for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
    const r = el => { const b = el.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height }; };
    const vis = el => { if (!el) return false; const cs = getComputedStyle(el); if (cs.display === 'none' || cs.visibility === 'hidden') return false; if (+cs.opacity < 0.02) return false; return el.getClientRects().length > 0; };
    const out = { island: r(document.getElementById('isl-in')), footprint: null, drop: null, thumb: null, bigText: [] };
    const bb = document.getElementById('isl-black').getBBox(); const sb = document.getElementById('isl-sheet').getBBox();
    const x0 = Math.min(bb.x, sb.width ? sb.x : bb.x), x1 = Math.max(bb.x + bb.width, sb.width ? sb.x + sb.width : 0), y1 = Math.max(bb.y + bb.height, sb.height ? sb.y + sb.height : 0);
    out.footprint = { x: x0, y: 0, w: x1 - x0, h: y1 };
    const drop = document.getElementById('drop'); if (vis(drop)) out.drop = r(drop);
    for (const th of document.querySelectorAll('#tdrop .th-drop')) if (vis(th)) out.thumb = r(th);
    // text sizes inside VoiceFlow surfaces (thumbnails are images of the page, excluded)
    const roots = ['#island', '#drop', '#mk-html', '#tdrop'];
    for (const sel of roots) for (const el of document.querySelector(sel).querySelectorAll('*')) {
      if (el.closest('.thumb-inner')) continue;
      const hasText = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
      if (!hasText || !vis(el)) continue;
      // hidden by an ancestor's opacity?
      let a = el, o = 1; while (a && a !== document.body) { o *= +getComputedStyle(a).opacity; a = a.parentElement; } if (o < 0.02) continue;
      const fs = parseFloat(getComputedStyle(el).fontSize);
      if (fs > 16.01) out.bigText.push({ text: el.textContent.trim().slice(0, 40), fs });
    }
    return out;
  }, t);
  const I = m.island, F = m.footprint;
  let line = `${label.padEnd(32)} t=${t.toFixed(1).padStart(6)}  island ${I.w.toFixed(0)}×${I.h.toFixed(0)} (footprint ${F.w.toFixed(0)}×${F.h.toFixed(0)})`;
  if (b.island === 'sheet') {
    const area = F.w * F.h; line += `  area ${(100 * area / AREA).toFixed(1)}%`;
    note('sheet (control center / automations / payload)', F.w, F.h);
    if (area > SHEET_MAX) fail(`${label}: sheet area ${(100 * area / AREA).toFixed(1)}% > 30%`);
  } else {
    const key = b.record ? 'capture record (island while marking)' : b.island[1] <= 32 ? 'receipt' : b.island[0] >= 540 ? 'reader' : 'dictation / FLORA ask';
    note(key, F.w, F.h);
    if (F.w > b.island[0] + 0.5 || F.h > b.island[1] + 0.5) fail(`${label}: footprint ${F.w.toFixed(0)}×${F.h.toFixed(0)} exceeds ${b.island[0]}×${b.island[1]}`);
  }
  if (b.dropdown) {
    if (!m.drop) fail(`${label}: alternatives drop-down not visible`);
    else { const visibleH = m.drop.y + m.drop.h - I.h; line += `  dropdown +${visibleH.toFixed(0)}px`; note('alternatives (added height)', m.drop.w, visibleH); if (visibleH > b.dropdown) fail(`${label}: drop-down adds ${visibleH.toFixed(0)} px > ${b.dropdown}`); }
  }
  if (b.thumb) {
    if (!m.thumb) fail(`${label}: thumbnail drop not visible`);
    else { line += `  thumb ${m.thumb.w.toFixed(0)}×${m.thumb.h.toFixed(0)}`; note('thumbnail drop', m.thumb.w, m.thumb.h); if (m.thumb.w > b.thumb[0] || m.thumb.h > b.thumb[1]) fail(`${label}: thumbnail ${m.thumb.w}×${m.thumb.h} exceeds ${b.thumb}`); }
  }
  console.log(line);
  for (const bt of m.bigText) fail(`${label}: text ${bt.fs}px > 16px — "${bt.text}"`);
}
console.log('\nMeasured maxima (footprint incl. the 6 px shoulders):');
for (const k in maxima) console.log(`  ${k.padEnd(48)} ${maxima[k].w.toFixed(0)} × ${maxima[k].h.toFixed(0)}`);
console.log(failures ? `\n${failures} failure(s)` : '\nAll budgets pass.');
await browser.close();
process.exit(failures ? 1 : 0);
