// island.js — the notch, extended (from concept-c-island/island.js) in Orbit's palette. Draws the shape
// (flat top welded to the screen edge, concave shoulders, rounded bottom; flat #000, NO shadow), the band
// text and the bodies that live inside it: dictation flow (B's focus-pull words, lift-and-swap edits at
// island scale), thinking line, 3-line lyrics reader (B's spoken-word glow), record line; plus the welded
// alternatives drop-down and the thumbnail drop. The three dots are NOT here — the triad is drawn on the
// fx canvas (orbit.js) and merely rests at the island's left shoulder. Everything is set from renderAt(t).
(function () {
  const K = window.K, css = K.css, text = K.text, html = K.html;
  const CX = 960, SH = 6, BAND = 32;
  // Orbit palette
  const C = { text: '#EAF2FF', sec: '#AFBCCE', ter: '#8E9BAE', live: '#5CE1E6', need: '#FFB547', flora: '#9B8CFF', run: '#5CE1E6', fail: '#FF6B6B', green: '#7EE0A1', sheet: '#0F141B', hair: 'rgba(255,255,255,.10)' };
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const f1 = n => (Math.round(n * 10) / 10).toString();
  const $ = id => document.getElementById(id);
  const I = {};
  const Island = { C, CX, BAND, SH };

  function attr(el, k, v) { if (el.__a && el.__a[k] === v) return; (el.__a ||= {})[k] = v; el.setAttribute(k, v); }

  Island.build = function () {
    I.root = $('island'); I.svg = $('isl-shape'); I.black = $('isl-black'); I.sheetPath = $('isl-sheet'); I.in = $('isl-in');
    I.band = I.in.querySelector('.band');
    I.left = I.band.querySelector('.b-left'); I.right = I.band.querySelector('.b-right'); I.pips = I.band.querySelector('.pips');
    I.dict = $('dict'); I.flow = I.dict.querySelector('.d-flow'); I.think = $('think');
    I.reader = $('reader'); I.rclip = I.reader.querySelector('.r-clip'); I.rcol = I.reader.querySelector('.r-col'); I.rec = $('rec'); I.recFlow = I.rec.querySelector('.rec-flow');
    I.sheet = $('sheet'); I.drop = $('drop'); I.tdrop = $('tdrop');
    I.spans = new Map();
    I.drop.innerHTML = `<div class="r"></div><div class="r"></div><div class="r"></div>`; I.dropRows = [...I.drop.children];
    attr(I.black, 'fill', '#000');
  };
  Island.sheetEl = () => I.sheet;
  // where the triad rests inside the island: the left shoulder, 24 px in, mid-band
  Island.shoulder = w => [CX - w / 2 + 24, 16];

  // ---------- shape ----------
  function pathBlack(w, hb, rb) {
    const x0 = CX - w / 2, x1 = CX + w / 2, r = Math.min(rb, Math.max(0, hb / 2 - 1));
    return `M${f1(x0 - SH)} 0A${SH} ${SH} 0 0 1 ${f1(x0)} ${SH}L${f1(x0)} ${f1(hb - r)}A${f1(r)} ${f1(r)} 0 0 0 ${f1(x0 + r)} ${f1(hb)}L${f1(x1 - r)} ${f1(hb)}A${f1(r)} ${f1(r)} 0 0 0 ${f1(x1)} ${f1(hb - r)}L${f1(x1)} ${SH}A${SH} ${SH} 0 0 1 ${f1(x1 + SH)} 0Z`;
  }
  function pathSheet(w, y0, h, r) {
    const x0 = CX - w / 2, x1 = CX + w / 2; r = Math.min(r, (h - y0) / 2);
    return `M${f1(x0)} ${f1(y0)}L${f1(x1)} ${f1(y0)}L${f1(x1)} ${f1(h - r)}A${f1(r)} ${f1(r)} 0 0 1 ${f1(x1 - r)} ${f1(h)}L${f1(x0 + r)} ${f1(h)}A${f1(r)} ${f1(r)} 0 0 1 ${f1(x0)} ${f1(h - r)}Z`;
  }

  // ---------- the island frame ----------
  // st: { w, h, r, sheet (0..1: how much of the body is the sheet), left, right, pips }
  Island.render = function (st) {
    const { w, h, r } = st, sh = st.sheet || 0;
    const hb = K.lerp(h, BAND, sh), rb = K.lerp(r, 0, sh);
    attr(I.black, 'd', pathBlack(w, hb, rb));
    if (sh > 0.001 && h > hb + 0.5) {
      attr(I.sheetPath, 'd', pathSheet(w, hb - 1, h, r)); attr(I.sheetPath, 'fill', K.mix('#000000', C.sheet, sh));
      attr(I.sheetPath, 'stroke', C.hair); attr(I.sheetPath, 'stroke-width', '1');
      // the one shadow the brief allows, only under a welded sheet: tight 0 2px 6px rgba(0,0,0,.25)
      css(I.svg, { filter: `drop-shadow(0 2px 6px rgba(0,0,0,${(0.25 * sh).toFixed(3)}))` });
    } else { attr(I.sheetPath, 'd', ''); css(I.svg, { filter: 'none' }); }
    css(I.in, { left: (CX - w / 2).toFixed(1) + 'px', width: w.toFixed(1) + 'px', height: h.toFixed(1) + 'px', borderRadius: `0 0 ${r.toFixed(1)}px ${r.toFixed(1)}px` });
    // band text
    const L = st.left || { html: '', alpha: 0 }, R = st.right || { html: '', alpha: 0 };
    html(I.left, L.html || ''); css(I.left, { opacity: (L.alpha == null ? 1 : L.alpha).toFixed(3), left: (L.x == null ? 48 : L.x) + 'px', visibility: (L.alpha == null ? 1 : L.alpha) > 0.005 ? 'visible' : 'hidden', width: L.width ? L.width + 'px' : 'auto' });
    html(I.right, R.html || ''); css(I.right, { opacity: (R.alpha == null ? 1 : R.alpha).toFixed(3), right: (R.right == null ? 18 : R.right) + 'px', visibility: (R.alpha == null ? 1 : R.alpha) > 0.005 ? 'visible' : 'hidden' });
    // pips (mini thumbnails, one per mark) on the right shoulder
    const P = st.pips || { n: 0 };
    const pips = [...I.pips.children];
    css(I.pips, { visibility: P.n > 0 ? 'visible' : 'hidden', right: (P.right == null ? 18 : P.right) + 'px', opacity: (P.alpha == null ? 1 : P.alpha).toFixed(3) });
    pips.forEach((p, i) => { const on = i < P.n; const pop = P.pop && P.pop[i] != null ? P.pop[i] : 1; css(p, { visibility: on ? 'visible' : 'hidden', opacity: on ? pop.toFixed(3) : '0', transform: `scale(${(0.6 + 0.4 * pop).toFixed(3)})` }); });
  };
  Island.pipsEl = () => I.pips;

  // ---------- dictation flow (15/20, two lines) ----------
  const LINE = 20;
  // B's word visuals at island scale: focus-pull arrival (blur 4 → 0), provisional cyan tint until committed,
  // low-confidence cyan underglow, edits lift 4 px with a violet glow, inserted words glow cyan then cool.
  function tokenVisual(tok, t) {
    let opacity = 1, blur = 0, ty = 0, shadow = 'none', color = tok.dim ? C.sec : C.text;
    if (tok.born >= 0) { const p = K.p(t, tok.born, tok.born + 0.22, 'out'); blur += 4 * (1 - p); opacity = 0.45 + 0.55 * p; }
    if (tok.swapAt != null) { const d = Math.abs(t - tok.swapAt); if (d < 0.15) blur += 3.5 * (1 - d / 0.15); }
    if (tok.commit != null && !tok.dim) { const q = 1 - K.p(t, tok.commit, tok.commit + 0.35, 'inOut'); if (q > 0) color = K.mix(C.text, C.live, 0.45 * q); }
    if (tok.lowConf) { color = K.mix(C.text, C.live, 0.4); shadow = '0 2px 6px rgba(92,225,230,.85), 0 0 1px rgba(92,225,230,.5)'; }
    if (tok.lift) { ty = -4 * tok.lift; shadow = `0 0 ${(7 * tok.lift).toFixed(1)}px rgba(155,140,255,${(0.9 * tok.lift).toFixed(2)})`; }
    if (tok.inserted != null) { const g = 1 - K.p(t, tok.inserted + 0.4, tok.inserted + 1.7, 'inOut'); if (g > 0) { color = K.mix(color, C.live, 0.7 * g); shadow = `0 0 ${(8 * g).toFixed(1)}px rgba(92,225,230,${(0.9 * g).toFixed(2)})`; } }
    if (tok.tint) color = tok.tint;
    if (tok.alpha != null) opacity *= tok.alpha;
    return { opacity, blur, color, shadow, ty };
  }
  function renderTokens(tokens, t) {
    const seen = new Set(); let order = 0;
    for (const tok of tokens) {
      let sp = I.spans.get(tok.key);
      if (!sp) { sp = document.createElement('span'); sp.className = 'w'; I.spans.set(tok.key, sp); I.flow.appendChild(sp); }
      if (I.flow.children[order] !== sp) I.flow.insertBefore(sp, I.flow.children[order] || null);
      order++; seen.add(tok.key);
      text(sp, tok.text);
      const v = tokenVisual(tok, t);
      let width = '';
      if (tok.grow != null && tok.grow < 1) { if (sp.__nat == null || sp.__natText !== tok.text) { sp.style.width = ''; sp.__nat = sp.offsetWidth; sp.__natText = tok.text; } width = (sp.__nat * tok.grow).toFixed(1) + 'px'; }
      css(sp, { display: 'inline-block', opacity: v.opacity.toFixed(3), filter: v.blur > 0.05 ? `blur(${v.blur.toFixed(2)}px)` : 'none', color: v.color, textShadow: v.shadow,
        transform: v.ty ? `translateY(${v.ty.toFixed(2)}px)` : 'none', width, marginRight: tok.grow != null && tok.grow < 1 ? (0.3 * tok.grow).toFixed(2) + 'em' : '.3em' });
    }
    for (const [key, sp] of I.spans) if (!seen.has(key)) css(sp, { display: 'none' });
  }
  Island.lineOf = key => { const sp = I.spans.get(key); if (!sp || sp.style.display === 'none') return 0; return Math.round(sp.offsetTop / LINE); };
  Island.lastLine = () => { let m = 0; for (const sp of I.flow.children) if (sp.style.display !== 'none') m = Math.max(m, Math.round(sp.offsetTop / LINE)); return m; };
  Island.tokenRect = key => { const sp = I.spans.get(key); const r = sp.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  // st: { t, tokens, scrollLine (fn or number), alpha }
  Island.dict = function (st) {
    if (!st) { css(I.dict, { display: 'none' }); return; }
    css(I.dict, { display: 'block', opacity: (st.alpha == null ? 1 : st.alpha).toFixed(3) });
    renderTokens(st.tokens || [], st.t);
    const sl = typeof st.scrollLine === 'function' ? st.scrollLine() : (st.scrollLine || 0);
    css(I.flow, { transform: `translateY(${(-sl * LINE).toFixed(2)}px)` });
    css(I.dict, { webkitMaskImage: edgeMask(sl, 0.25) });
  };
  // the viewport rests on whole lines; while the content is between lines a 10 px fade dissolves each edge
  function edgeMask(pos, ramp) {
    const frac = pos - Math.floor(pos), mv = K.clamp(Math.min(frac, 1 - frac) / ramp);
    if (mv < 0.001) return 'none';
    const f = (10 * mv).toFixed(1);
    return `linear-gradient(to bottom, transparent 0, #000 ${f}px, #000 calc(100% - ${f}px), transparent 100%)`;
  }

  // ---------- thinking line ----------
  Island.think = function (st) {
    if (!st) { css(I.think, { display: 'none' }); return; }
    html(I.think, st.html); css(I.think, { display: 'block', opacity: st.alpha.toFixed(3) });
  };

  // ---------- lyrics reader ----------
  // Each sentence carries two layers: `.full` (wrapped, karaoke words, 16/21 when current) and `.line`
  // (one 13/16 line, ellipsis) — neighbours show the line, the current shows the full text, and the
  // reading position crossfades between them while the column scrolls (Apple Music lyrics).
  const RD = { progs: {}, H: {} };
  const FS_CUR = 16, LH_CUR = 21, FS_NB = 13, LH_NB = 16, RGAP = 3, RCENTER = 40;
  Island.readerBuild = function (programs) {
    for (const name in programs) {
      const prog = document.createElement('div'); prog.className = 'prog';
      prog.innerHTML = programs[name].map(s => `<div class="sent"><div class="full">${s.split(/\s+/).map(w => `<span class="w">${esc(w)}</span>`).join(' ')}</div><div class="line">${esc(s)}</div></div>`).join('');
      I.rcol.appendChild(prog); RD.progs[name] = prog;
      RD.H[name] = [...prog.children].map(el => { const f = el.firstElementChild; css(f, { fontSize: FS_CUR + 'px', lineHeight: LH_CUR + 'px' }); return f.offsetHeight; });
      css(prog, { display: 'none' });
    }
  };
  // reading position: sentence index + smooth transition in the 0.5 s before the next sentence starts
  Island.readerPos = function (tl, t, introAt) {
    const S = tl.sentences;
    if (t < S[0].start) return -1 + K.p(t, introAt, introAt + 0.6, 'inOut');
    for (let i = 0; i < S.length; i++) { const next = S[i + 1]; if (!next || t < next.start) { if (!next) return i; return i + K.p(t, next.start - 0.5, next.start, 'inOut'); } }
    return S.length - 1;
  };
  // st: { t, prog, timeline, p, alpha, stopped }
  Island.reader = function (st) {
    if (!st) { css(I.reader, { display: 'none' }); for (const n in RD.progs) css(RD.progs[n], { display: 'none' }); return; }
    css(I.reader, { display: 'block', opacity: (st.alpha == null ? 1 : st.alpha).toFixed(3) });
    for (const n in RD.progs) css(RD.progs[n], { display: n === st.prog ? 'block' : 'none' });
    const prog = RD.progs[st.prog], S = [...prog.children], H = RD.H[st.prog], tl = st.timeline, t = st.t;
    const p = Math.max(-1, st.p), n = S.length;
    let y = 0; const tops = [], hs = [], as = [];
    for (let i = 0; i < n; i++) { const a = p < 0 && i === 0 ? 0 : Math.min(1, Math.abs(i - p)); const h = K.lerp(H[i], LH_NB, a); tops.push(y); hs.push(h); as.push(a); y += h + RGAP; }
    let cen;
    if (p < 0) cen = tops[0] + hs[0] / 2 - 22 * (-p);
    else { const i0 = Math.min(n - 1, Math.floor(p)), i1 = Math.min(n - 1, i0 + 1), fr = p - i0; cen = K.lerp(tops[i0] + hs[i0] / 2, tops[i1] + hs[i1] / 2, fr); }
    css(I.rcol, { transform: `translateY(${(RCENTER - cen).toFixed(2)}px)` });
    css(I.rclip, { webkitMaskImage: edgeMask(p, 0.2) });
    for (let i = 0; i < n; i++) {
      const el = S[i], a = as[i], d = i - p;
      const vis = Math.abs(d) < 1.8 || (p < 0 && i === 0);
      if (!vis) { css(el, { display: 'none' }); continue; }
      const full = el.firstElementChild, line = el.lastElementChild;
      const x = K.clamp((a - 0.85) / 0.15);
      const sz = K.clamp(a / 0.85);
      const mv = K.clamp(Math.min(a, 1 - a) / 0.15);
      css(el, { display: 'block', top: tops[i].toFixed(2) + 'px', height: hs[i].toFixed(2) + 'px', opacity: (p < 0 ? K.clamp(p + 1) : 1).toFixed(3), webkitMaskImage: mv > 0.001 ? `linear-gradient(to bottom, #000 calc(100% - ${(16 * mv).toFixed(1)}px), transparent 100%)` : 'none' });
      const nb = d < 0 ? C.sec : C.ter;                          // previous · next (B's secondary / inactive)
      css(line, { opacity: x.toFixed(3), color: nb, visibility: x > 0.004 ? 'visible' : 'hidden' });
      if (x >= 0.996) { css(full, { visibility: 'hidden' }); continue; }
      css(full, { visibility: 'visible', opacity: (1 - x).toFixed(3), fontSize: K.lerp(FS_CUR, FS_NB, sz).toFixed(2) + 'px', lineHeight: K.lerp(LH_CUR, LH_NB, sz).toFixed(2) + 'px' });
      const words = [...full.children], wt = tl.sentences[i].words;
      words.forEach((w, j) => {
        const at = wt[j] ? wt[j].at : 1e9; let color, shadow = 'none';
        if ((st.stopped != null && at > st.stopped) || t < at) color = C.sec;                       // upcoming: B's secondary
        else {                                                                                         // spoken: cyan-white with a faint glow that cools
          const br = K.p(t, at, at + 0.15, 'out'); color = K.mix(C.sec, C.text, br);
          const g = Math.exp(-(t - at) / 0.35); if (g > 0.03) { color = K.mix(color, C.live, 0.55 * g); shadow = `0 0 ${(7 * g).toFixed(1)}px rgba(92,225,230,${(0.8 * g).toFixed(2)})`; }
        }
        if (a > 0) color = K.mix(color, nb, a);
        css(w, { color, textShadow: shadow });
      });
    }
  };

  // ---------- record line (talk + mark) ----------
  const RC = { words: [], R: [] };
  Island.recBuild = function (utterances) {
    const flow = I.recFlow; flow.innerHTML = '';
    utterances.forEach(u => u.words.forEach(w => { const sp = document.createElement('span'); sp.textContent = w.w; flow.appendChild(sp); RC.words.push({ sp, at: w.at, end: u.end }); }));
    css(I.rec, { display: 'block' }); css(I.in, { width: '360px', left: '780px', height: '64px' });
    RC.R = RC.words.map(x => x.sp.offsetLeft + x.sp.offsetWidth);
    css(I.rec, { display: 'none' });
    RC.words.forEach(x => css(x.sp, { opacity: '0' }));
  };
  // st: { t, alpha, avail }
  Island.rec = function (st) {
    if (!st) { css(I.rec, { display: 'none' }); return; }
    css(I.rec, { display: 'block', opacity: st.alpha.toFixed(3) });
    const t = st.t, avail = st.avail || 312;
    let n = 0; for (let i = 0; i < RC.words.length; i++) if (t >= RC.words[i].at) n = i + 1;
    const target = k => k <= 0 ? 0 : Math.max(0, RC.R[k - 1] - avail);
    let scroll = 0;
    if (n > 0) { const at = RC.words[n - 1].at; scroll = K.lerp(target(n - 1), target(n), K.p(t, at, at + 0.35, 'out')); }
    css(I.recFlow, { transform: `translateX(${(-scroll).toFixed(2)}px)` });
    css(I.rec, { webkitMaskImage: scroll > 0.5 ? 'linear-gradient(to right, transparent 0, transparent 8px, #000 44px)' : 'none' });
    RC.words.forEach(x => {
      const on = t >= x.at; const a = on ? K.p(t, x.at, x.at + 0.2, 'out') : 0;
      let color = C.text;
      if (on) { const q = 1 - K.p(t, x.at + 0.9, x.at + 1.25, 'inOut'); if (q > 0) color = K.mix(C.text, C.live, 0.45 * q); }   // B's provisional tint, then commits
      if (t > x.end + 1.4) color = C.ter;
      css(x.sp, { opacity: a.toFixed(3), color });
    });
  };

  // ---------- alternatives drop-down (welded under the island) ----------
  // st: { x, top, w, rows, cur, hover, alpha }
  Island.drop = function (st) {
    if (!st || st.alpha <= 0.003) { css(I.drop, { visibility: 'hidden' }); return; }
    css(I.drop, { visibility: 'visible', left: st.x.toFixed(1) + 'px', top: (st.top - 14).toFixed(1) + 'px', width: (st.w || 190) + 'px', opacity: st.alpha.toFixed(3), transform: `scaleY(${(0.4 + 0.6 * st.alpha).toFixed(3)})` });
    st.rows.forEach((r, i) => { const el = I.dropRows[i]; text(el, r); el.classList.toggle('cur', i === st.cur); el.classList.toggle('hov', i === st.hover); });
  };
  Island.dropRowRect = i => { const r = I.dropRows[i].getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };

  // ---------- thumbnail drop ----------
  Island.tdropAdd = node => { I.tdrop.appendChild(node); };
  // st: { k (0-based), x, y, scale, alpha, tagAlpha, front }
  Island.tdrop = function (st) {
    const kids = [...I.tdrop.children];
    if (!st) { kids.forEach(k => css(k, { visibility: 'hidden' })); return; }
    kids.forEach((k, i) => {
      if (i !== st.k) { css(k, { visibility: 'hidden' }); return; }
      css(k, { visibility: 'visible', transform: `translate(${st.x.toFixed(1)}px, ${st.y.toFixed(1)}px) scale(${st.scale.toFixed(4)})`, opacity: st.alpha.toFixed(3) });
      css(I.tdrop, { zIndex: st.front ? '61' : '59' });   // drops out from behind the band, flies back in front of it into its pip
      const tag = k.querySelector('.tt'); if (tag) css(tag, { opacity: (st.tagAlpha == null ? 1 : st.tagAlpha).toFixed(3) });
    });
  };

  window.Island = Island;
})();
