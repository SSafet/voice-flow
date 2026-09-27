// Space-budget + shadow check for Concept E (storyboard "Space budget"; brief "Shadows — hard rule").
// Renders the key frame of every scene, measures each VoiceFlow surface with getBoundingClientRect(),
// asserts the budgets (control center / automations exempt — full screen by Safet's choice), checks that no
// VoiceFlow text is larger than 16 px, and — outside the two exempt scenes — that no VoiceFlow surface has a
// box-shadow / drop-shadow beyond the brief's allowance (1 px hairline, or ≤ 0 2px 6px rgba(0,0,0,.25)),
// no backdrop-filter, and no translucent dark scrim. Exits 1 on failure.
//   node concept-e-orbit-island/check-budget.mjs        (run from design/concept-videos/)
import { chromium } from 'playwright';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const url = pathToFileURL(path.resolve(new URL('.', import.meta.url).pathname, 'film.html')).href;
const AREA = 1920 * 1080, SHEET_MAX = 0.30 * AREA;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
page.on('pageerror', e => { console.log('  PAGEERROR ' + e.message); });
await page.goto(url);
await page.evaluate(async () => { await document.fonts.ready; });
const T = await page.evaluate(() => JSON.parse(JSON.stringify(window.FILM.T)));

// [label, time, budget]  budget: island [w,h] | 'sheet' (≤ 900 × 340 and ≤ 30% of the screen) | 'cc' (exempt) ; extras: dropdown, record, thumb
const FRAMES = [
  ['at rest (notch + shoulders)',  T.rest.a + 2.0,                           { island: [202, 32] }],
  ['dictation · triad departs',    T.s2.mic + 0.35,                          { island: [460, 100] }],
  ['dictation · streaming',        T.s2.u1.words[10].at + 0.3,               { island: [460, 100] }],
  ['dictation · edit 1 command',   T.s2.e1.words[3].at + 0.2,                { island: [460, 100] }],
  ['dictation · edit 1 inserted',  T.s2.e1Swap + 0.35,                       { island: [460, 100] }],
  ['dictation · alternatives',     T.s2.ptr3 + 0.3,                          { island: [460, 100], dropdown: 90 }],
  ['dictation · edit 2 at start',  T.s2.e2Swap + 0.4,                        { island: [460, 100] }],
  ['dictation · text lands',       T.s2.land[0] + 0.6,                       { island: [202, 32] }],
  ['receipt · sent to Notion',     T.s2.receipt[0] + 0.8,                    { island: [360, 32] }],
  ['FLORA · ask streaming',        T.s3.ask.words[10].at,                    { island: [460, 100] }],
  ['FLORA · thinking',             T.s3.thinkLine + 0.6,                     { island: [460, 100] }],
  ['reader · FLORA reply',         T.s3.read.sentences[1].words[3].at,       { island: [540, 128] }],
  ['reader · article',             T.s3.read2.sentences[0].words[3].at,      { island: [540, 128] }],
  ['barge · Show me',              T.s3.show.words[1].at + 0.2,              { island: [460, 100] }],
  ['control center · by project',  T.s4.open + 2.5,                          { island: 'cc' }],
  ['control center · regroup cmd', T.s4.regroup.words[4].at,                 { island: 'cc' }],
  ['control center · priority 1',  T.s4.clickP1 + 1.0,                       { island: 'cc' }],
  ['automations · draft',          T.s5.fAccess + 0.8,                       { island: 'cc' }],
  ['automations · active',         T.s5.list + 1.0,                          { island: 'cc' }],
  ['talk + mark · recording',      T.s6.a2.start + 0.5,                      { island: [360, 64], record: true }],
  ['talk + mark · thumbnail drop', T.s6.shot1 + 1.0,                         { island: [360, 64], record: true, thumb: [260, 320] }],
  ['talk + mark · 4 marks',        T.s6.cap2 + 0.5,                          { island: [360, 64], record: true }],
  ['summary line',                 T.s7.summary + 0.8,                       { island: [360, 32] }],
  ['payload',                      T.s7.sheet + 2.0,                         { island: 'sheet' }],
  ['receipt · copied',             T.s7.receipt[0] + 0.8,                    { island: [360, 32] }],
];

const maxima = {}; let failures = 0; let shadowMax = { blur: 0, alpha: 0, where: '' };
const note = (k, w, h) => { const m = maxima[k] || { w: 0, h: 0 }; m.w = Math.max(m.w, w); m.h = Math.max(m.h, h); maxima[k] = m; };
const fail = msg => { failures++; console.log('  FAIL  ' + msg); };

for (const [label, t, b] of FRAMES) {
  const m = await page.evaluate(async ({ t, exempt }) => {
    await window.renderAt(t);
    for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
    const r = el => { const b = el.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height }; };
    const effOpacity = el => { let a = el, o = 1; while (a && a !== document.body) { o *= +getComputedStyle(a).opacity; a = a.parentElement; } return o; };
    const vis = el => { if (!el) return false; const cs = getComputedStyle(el); if (cs.display === 'none' || cs.visibility === 'hidden') return false; if (effOpacity(el) < 0.02) return false; return el.getClientRects().length > 0; };
    const out = { island: r(document.getElementById('isl-in')), footprint: null, sheet: null, drop: null, thumb: null, bigText: [], shadows: [], ccOpen: false };
    const bb = document.getElementById('isl-black').getBBox(); const sb = document.getElementById('isl-sheet').getBBox();
    const x0 = Math.min(bb.x, sb.width ? sb.x : bb.x), x1 = Math.max(bb.x + bb.width, sb.width ? sb.x + sb.width : 0), y1 = Math.max(bb.y + bb.height, sb.height ? sb.y + sb.height : 0);
    out.footprint = { x: x0, y: 0, w: x1 - x0, h: y1 }; if (sb.width) out.sheet = { w: sb.width, h: sb.y + sb.height };
    const drop = document.getElementById('drop'); if (vis(drop)) out.drop = r(drop);
    for (const th of document.querySelectorAll('#tdrop .th-drop')) if (vis(th)) out.thumb = r(th);
    out.ccOpen = getComputedStyle(document.getElementById('cc')).display !== 'none';
    // text sizes inside VoiceFlow surfaces (thumbnails are images of the page, excluded)
    const roots = ['#island', '#drop', '#mk-html', '#tdrop'];
    for (const sel of roots) for (const el of document.querySelector(sel).querySelectorAll('*')) {
      if (el.closest('.thumb-inner')) continue;
      const hasText = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
      if (!hasText || !vis(el)) continue;
      const fs = parseFloat(getComputedStyle(el).fontSize);
      if (fs > 16.01) out.bigText.push({ text: el.textContent.trim().slice(0, 40), fs });
    }
    // shadows / filters / scrims on every visible VoiceFlow element outside the control center
    if (!exempt) {
      const sroots = ['#island', '#drop', '#mk-html', '#tdrop', '#hud'];
      const parseShadows = s => { const out = []; const re = /(rgba?\([^)]*\)|#[0-9a-fA-F]+|[a-z]+)\s+(-?[\d.]+)px\s+(-?[\d.]+)px(?:\s+(-?[\d.]+)px)?(?:\s+(-?[\d.]+)px)?/g; let mm; while ((mm = re.exec(s))) { const c = mm[1]; let alpha = 1; const ca = c.match(/rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/); if (ca) alpha = +ca[1]; else if (c === 'transparent') alpha = 0; out.push({ color: c, alpha, ox: +mm[2], oy: +mm[3], blur: +(mm[4] || 0), spread: +(mm[5] || 0) }); } return out; };
      for (const sel of sroots) {
        const root = document.querySelector(sel); if (!root) continue;
        for (const el of [root, ...root.querySelectorAll('*')]) {
          if (!vis(el)) continue;
          const cs = getComputedStyle(el); const box = r(el); const tag = `${sel} ${el.tagName.toLowerCase()}${el.id ? '#' + el.id : ''}${el.className && typeof el.className === 'string' ? '.' + el.className.split(' ').join('.') : ''}`;
          if (cs.backdropFilter && cs.backdropFilter !== 'none') out.shadows.push({ tag, kind: 'backdrop-filter', value: cs.backdropFilter, bad: true });
          if (cs.boxShadow && cs.boxShadow !== 'none') for (const sh of parseShadows(cs.boxShadow)) {
            const hairline = sh.blur === 0 && Math.abs(sh.ox) === 0 && Math.abs(sh.oy) === 0 && sh.spread <= 1.01;
            const light = sh.color.startsWith('rgba(255') || sh.color.startsWith('rgba(210') || sh.color.startsWith('rgba(92');   // pale rings / accents, not dark halos
            const tight = Math.abs(sh.ox) <= 2.01 && Math.abs(sh.oy) <= 2.01 && sh.blur <= 6.01 && sh.spread <= 0.01 && sh.alpha <= 0.2501;
            const bad = !(hairline || tight || (light && sh.blur <= 6.01));
            out.shadows.push({ tag, kind: 'box-shadow', value: cs.boxShadow, blur: sh.blur, alpha: sh.alpha, bad, w: box.w, h: box.h });
          }
          if (cs.filter && cs.filter !== 'none') { const ds = cs.filter.match(/drop-shadow\((.*)\)/); if (ds) for (const sh of parseShadows(ds[1])) { const bad = !(Math.abs(sh.ox) <= 2.01 && Math.abs(sh.oy) <= 2.01 && sh.blur <= 6.01 && sh.alpha <= 0.2501); out.shadows.push({ tag, kind: 'filter', value: cs.filter, blur: sh.blur, alpha: sh.alpha, bad }); } else if (!/^blur\(/.test(cs.filter)) out.shadows.push({ tag, kind: 'filter', value: cs.filter, bad: true }); }
          // translucent dark scrim: a large box with a semi-transparent dark background
          const bg = cs.backgroundColor.match(/rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/);
          if (bg && +bg[4] > 0.05 && +bg[4] < 0.9 && (+bg[1] + +bg[2] + +bg[3]) < 200 && box.w * box.h > 200 * 60) out.shadows.push({ tag, kind: 'scrim', value: cs.backgroundColor, bad: true, w: box.w, h: box.h });
        }
      }
    }
    return out;
  }, { t, exempt: b.island === 'cc' });
  const I = m.island, F = m.footprint;
  let line = `${label.padEnd(32)} t=${t.toFixed(1).padStart(6)}  island ${I.w.toFixed(0)}×${I.h.toFixed(0)} (footprint ${F.w.toFixed(0)}×${F.h.toFixed(0)})`;
  if (b.island === 'cc') {
    line += `  control center / automations — exempt (full screen)`;
    if (!m.ccOpen) fail(`${label}: control center not open`);
  } else if (b.island === 'sheet') {
    const S = m.sheet || F; const area = F.w * F.h; line += `  sheet ${S.w.toFixed(0)}×${S.h.toFixed(0)}  area ${(100 * area / AREA).toFixed(1)}%`;
    note('payload sheet (notch band + sheet)', S.w, S.h);
    if (area > SHEET_MAX) fail(`${label}: sheet area ${(100 * area / AREA).toFixed(1)}% > 30%`);
    if (S.w > 900.5 || S.h > 340.5) fail(`${label}: payload ${S.w.toFixed(0)}×${S.h.toFixed(0)} exceeds 900×340`);
    if (m.ccOpen) fail(`${label}: control center visible outside its scene`);
  } else {
    const key = b.record ? 'capture record (island while marking)' : b.island[1] <= 32 ? 'receipt / notch' : b.island[0] >= 540 ? 'reader' : 'dictation / FLORA ask / command';
    note(key, F.w, F.h);
    if (F.w > b.island[0] + 0.5 || F.h > b.island[1] + 0.5) fail(`${label}: footprint ${F.w.toFixed(0)}×${F.h.toFixed(0)} exceeds ${b.island[0]}×${b.island[1]}`);
    if (m.ccOpen) fail(`${label}: control center visible outside its scene`);
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
  for (const sh of m.shadows) {
    if (sh.kind !== 'scrim' && sh.blur != null && sh.alpha != null && !sh.tag.includes('.pip') && (sh.blur > shadowMax.blur || (sh.blur === shadowMax.blur && sh.alpha > shadowMax.alpha))) shadowMax = { blur: sh.blur, alpha: sh.alpha, where: `${label} · ${sh.tag}` };
    if (sh.bad) fail(`${label}: ${sh.kind} on ${sh.tag} = ${sh.value}`);
  }
}
console.log('\nMeasured maxima (footprint incl. the 6 px shoulders):');
for (const k in maxima) console.log(`  ${k.padEnd(48)} ${maxima[k].w.toFixed(0)} × ${maxima[k].h.toFixed(0)}`);
console.log(`  largest shadow outside control center / automations: blur ${shadowMax.blur}px, alpha ${shadowMax.alpha} (${shadowMax.where || 'none'})`);
console.log(failures ? `\n${failures} failure(s)` : '\nAll budgets pass. No shadows beyond the brief outside the control center.');
await browser.close();
process.exit(failures ? 1 : 0);
