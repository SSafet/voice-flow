// VoiceFlow surfaces: the transcript lens, the reader drum, the one-line receipt.
(function () {
  const K = window.K, css = K.css, text = K.text, html = K.html;
  const TEXT = '#EAF2FF', SEC = '#AFBCCE', CYAN = '#5CE1E6', VIOLET = '#9B8CFF', GREEN = '#7EE0A1';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  // ================= LENS =================
  const Lens = {};
  const L = {};
  Lens.build = function () {
    const root = document.getElementById('lens');
    root.innerHTML = `<div class="l-head"><span class="l-tag"></span><span class="l-state"></span></div>
      <div class="l-clip"><div class="l-flow"></div></div>
      <div class="l-rail"><i></i></div>
      <div class="l-foot"><span class="fg"></span><span class="ft"></span></div>
      <div class="picker glass"><div></div><div></div><div></div></div>`;
    L.root = root; L.head = root.querySelector('.l-head'); L.tag = root.querySelector('.l-tag'); L.state = root.querySelector('.l-state');
    L.clip = root.querySelector('.l-clip'); L.flow = root.querySelector('.l-flow'); L.rail = root.querySelector('.l-rail'); L.thumb = root.querySelector('.l-rail i');
    L.foot = root.querySelector('.l-foot'); L.fg = root.querySelector('.fg'); L.ft = root.querySelector('.ft');
    L.picker = root.querySelector('.picker'); L.prows = [...L.picker.children];
    L.spans = new Map();
  };
  const LINE = 30;
  function tokenVisual(tok, t) {
    // returns {opacity, blur, color, shadow, ty, scale}
    let opacity = 1, blur = 0, ty = 0, shadow = 'none', color = tok.dim ? SEC : TEXT;
    if (tok.born >= 0) { const p = K.p(t, tok.born, tok.born + 0.22, 'out'); blur += 6 * (1 - p); opacity = 0.45 + 0.55 * p; }
    if (tok.swapAt != null) { const d = Math.abs(t - tok.swapAt); if (d < 0.15) blur += 5 * (1 - d / 0.15); }
    if (tok.commit != null && !tok.dim) { // provisional tint until committed
      const q = 1 - K.p(t, tok.commit, tok.commit + 0.35, 'inOut');
      if (q > 0) color = K.mix(TEXT, CYAN, 0.45 * q);
    }
    if (tok.lowConf) { color = K.mix(TEXT, CYAN, 0.35); shadow = '0 3px 9px rgba(92,225,230,.85), 0 0 2px rgba(92,225,230,.5)'; }
    if (tok.lift) { ty = -10 * tok.lift; shadow = `0 0 ${10 * tok.lift}px rgba(155,140,255,${0.9 * tok.lift})`; }
    if (tok.inserted != null) { // glows cyan then cools over 1.3 s
      const g = 1 - K.p(t, tok.inserted + 0.4, tok.inserted + 1.7, 'inOut');
      if (g > 0) { color = K.mix(color === TEXT ? TEXT : color, CYAN, 0.7 * g); shadow = `0 0 ${12 * g}px rgba(92,225,230,${0.9 * g})`; }
    }
    if (tok.tint) color = tok.tint;
    if (tok.alpha != null) opacity *= tok.alpha;
    return { opacity, blur, color, shadow, ty };
  }
  // reconcile spans by key; returns map key → span
  function renderTokens(tokens, t) {
    const seen = new Set();
    let order = 0;
    for (const tok of tokens) {
      let sp = L.spans.get(tok.key);
      if (!sp) { sp = document.createElement('span'); sp.className = 'w'; L.spans.set(tok.key, sp); L.flow.appendChild(sp); }
      // keep DOM order equal to token order
      if (L.flow.children[order] !== sp) L.flow.insertBefore(sp, L.flow.children[order] || null);
      order++;
      seen.add(tok.key);
      text(sp, tok.text);
      const v = tokenVisual(tok, t);
      css(sp, { display: 'inline-block', opacity: v.opacity.toFixed(3), filter: v.blur > 0.05 ? `blur(${v.blur.toFixed(2)}px)` : 'none', color: v.color, textShadow: v.shadow, transform: v.ty ? `translateY(${v.ty.toFixed(2)}px)` : 'none' });
    }
    for (const [key, sp] of L.spans) if (!seen.has(key)) css(sp, { display: 'none' });
  }
  Lens.lineOf = function (key) { const sp = L.spans.get(key); if (!sp || sp.style.display === 'none') return 0; return Math.round(sp.offsetTop / LINE); };
  Lens.lastLine = function () { let m = 0; for (const sp of L.flow.children) if (sp.style.display !== 'none') m = Math.max(m, Math.round(sp.offsetTop / LINE)); return m; };
  Lens.tokenRect = function (key) { // screen rect (assumes the lens is rendered at scale 1)
    const sp = L.spans.get(key); const r = sp.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height };
  };
  // token box relative to the lens root (for the picker), using the current scroll
  Lens.tokenOffset = function (key) {
    const sp = L.spans.get(key); return { left: L.clip.offsetLeft + sp.offsetLeft, top: L.clip.offsetTop + sp.offsetTop - (L.scrollPx || 0), w: sp.offsetWidth, h: sp.offsetHeight };
  };
  Lens.pickerRowRect = function (i) { const r = L.prows[i].getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  Lens.rect = function () { const r = L.root.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  let lastState = null;
  Lens.render = function (st) {
    if (!st) { css(L.root, { display: 'none' }); lastState = null; return; }
    css(L.root, { display: 'block', width: st.w + 'px' });
    // header
    const headOn = st.head && st.head.on !== false;
    css(L.head, { height: (headOn ? 22 : 0) + 'px', marginBottom: (headOn ? 8 : 0) + 'px' });
    if (st.head) { text(L.tag, st.head.tag || ''); css(L.tag, { color: st.head.tagColor || CYAN }); text(L.state, st.head.state || ''); }
    // clip / flow
    const lines = st.lines || 3;
    css(L.clip, { height: (lines * LINE) + 'px' });
    renderTokens(st.tokens || [], st.t);
    const extra = st.post ? st.post() : {};
    let scroll = 0;
    const sl = extra.scrollLine != null ? extra.scrollLine : st.scrollLine;
    if (sl != null) scroll = sl * LINE;
    css(L.flow, { transform: `translateY(${(-scroll).toFixed(2)}px)` });
    if (extra.picker !== undefined) st.picker = extra.picker;
    L.scrollPx = scroll;
    const total = Lens.lastLine() + 1;
    const railOn = st.rail && total > lines;
    css(L.rail, { visibility: railOn ? 'visible' : 'hidden', height: (lines * LINE) + 'px', top: (headOn ? 44 : 14) + 'px' });
    if (railOn) { const th = lines * LINE * lines / total, ty = (lines * LINE - th) * (scroll / LINE) / (total - lines); css(L.thumb, { height: th.toFixed(1) + 'px', transform: `translateY(${ty.toFixed(1)}px)` }); }
    // footer
    const f = st.foot;
    const fh = f ? (f.lines || 1) * 22 : 0;
    css(L.foot, { height: fh + 'px', marginTop: (fh ? 8 : 0) + 'px', opacity: f ? (f.alpha == null ? 1 : f.alpha).toFixed(3) : '0', color: f && f.color || VIOLET });
    if (f) { html(L.fg, f.glyph || ''); html(L.ft, f.html || ''); css(L.fg, { color: f.glyphColor || f.color || VIOLET }); }
    // picker
    const pk = st.picker;
    if (pk) {
      css(L.picker, { visibility: 'visible', left: pk.x + 'px', top: pk.y + 'px', opacity: pk.alpha.toFixed(3), transform: `scaleY(${(0.35 + 0.65 * pk.alpha).toFixed(3)})` });
      pk.rows.forEach((r, i) => { text(L.prows[i], r); css(L.prows[i], { transform: `translateY(${pk.shift.toFixed(1)}px)` }); L.prows[i].classList.toggle('cur', i === pk.cur); });
    } else css(L.picker, { visibility: 'hidden' });
    // placement + unfold from an origin point
    const s = st.scale == null ? 1 : st.scale, a = st.alpha == null ? 1 : st.alpha;
    const ox = st.origin ? st.origin[0] - st.x : 0, oy = st.origin ? st.origin[1] - st.y : 0;
    css(L.root, { left: st.x.toFixed(1) + 'px', top: st.y.toFixed(1) + 'px', transformOrigin: `${ox.toFixed(1)}px ${oy.toFixed(1)}px`, transform: `scale(${s.toFixed(4)})`, opacity: a.toFixed(3) });
    lastState = st;
  };

  // ================= DRUM (reader) =================
  // Sentences sit on a drum of radius R; the current one faces the viewer, neighbours tip away by TIP°.
  // The surface is sized to its content every frame from measured sentence heights (no empty band).
  const Drum = {}; const Dm = {};
  const R = 165, TIP = 26, FS_CUR = 26, FS_NB = 20, PAD_T = 14, HEAD = 24, GAP = 12, PAD_B = 20;
  Drum.build = function (programs) { // programs: {name: [sentences]}
    const root = document.getElementById('drum');
    root.innerHTML = `<div class="d-head"><span class="d-tag"></span><span class="d-ctl"><span class="spd">1.1×</span><span class="pause"><i></i><i></i></span></span></div><div class="d-stage"></div>`;
    Dm.root = root; Dm.tag = root.querySelector('.d-tag'); Dm.stage = root.querySelector('.d-stage'); Dm.progs = {}; Dm.H = {};
    for (const name in programs) {
      const prog = document.createElement('div'); prog.className = 'prog';
      prog.innerHTML = programs[name].map(s => `<div class="sent">${s.split(/\s+/).map(w => `<span class="w">${esc(w)}</span>`).join('')}</div>`).join('');
      Dm.stage.appendChild(prog); Dm.progs[name] = prog;
      // measure natural heights at the current and the neighbour size (same 712 px column)
      Dm.H[name] = [...prog.children].map(el => { el.style.fontSize = FS_CUR + 'px'; const h1 = el.offsetHeight; el.style.fontSize = FS_NB + 'px'; const h2 = el.offsetHeight; el.style.fontSize = ''; return [h1, h2]; });
      prog.style.display = 'none';
    }
  };
  Drum.render = function (st) {
    if (!st) { css(Dm.root, { visibility: 'hidden' }); for (const name in Dm.progs) css(Dm.progs[name], { display: 'none' }); return; }
    css(Dm.root, { visibility: 'visible' });
    text(Dm.tag, st.tag); css(Dm.tag, { color: st.tagColor || VIOLET });
    for (const name in Dm.progs) css(Dm.progs[name], { display: name === st.prog ? 'block' : 'none' });
    const prog = Dm.progs[st.prog], sents = [...prog.children], H = Dm.H[st.prog], tl = st.timeline, t = st.t, p = st.p;
    // geometry pass
    const items = [];
    sents.forEach((el, i) => {
      const d = i - p, a = Math.abs(d);
      if (a > 1.6) { css(el, { visibility: 'hidden' }); return; }
      const ad = Math.min(1, a), th = d * TIP * Math.PI / 180;
      const h = K.lerp(H[i][0], H[i][1], ad) * Math.cos(th) + 6;
      items.push({ el, i, d, ad, th, y: R * Math.sin(th), z: R * (Math.cos(th) - 1), h, op: a <= 1 ? 1 : 1 - (a - 1) / 0.6, fs: FS_CUR - (FS_CUR - FS_NB) * ad });
    });
    let top = Infinity, bottom = -Infinity;
    for (const it of items) if (it.op >= 0.999) { top = Math.min(top, it.y - it.h / 2); bottom = Math.max(bottom, it.y + it.h / 2); }
    for (const it of items) if (it.op < 0.999) { top = Math.min(top, K.lerp(top, it.y - it.h / 2, it.op)); bottom = Math.max(bottom, K.lerp(bottom, it.y + it.h / 2, it.op)); }
    // the stage clips to the content band: an outgoing sentence rolls under the header edge as it fades
    const contentTop = PAD_T + HEAD + GAP, pivotY = -top, height = contentTop + (bottom - top) + PAD_B;
    css(Dm.stage, { top: contentTop + 'px', height: (bottom - top).toFixed(1) + 'px', perspectiveOrigin: `50% ${pivotY.toFixed(1)}px` });
    css(prog, { top: pivotY.toFixed(1) + 'px' });
    for (const it of items) {
      const { el, d, ad, y, z, op, fs } = it;
      css(el, { visibility: 'visible', fontSize: fs.toFixed(2) + 'px', opacity: op.toFixed(3), transform: `translate3d(0, calc(-50% + ${y.toFixed(2)}px), ${z.toFixed(2)}px) rotateX(${(-d * TIP).toFixed(2)}deg)` });
      const words = [...el.children], wt = tl.sentences[it.i].words;
      const base = K.mix(TEXT, SEC, ad);
      if (ad < 0.5) {
        words.forEach((w, j) => {
          const at = wt[j].at; let color, shadow = 'none';
          if (t < at) color = SEC;
          else {
            const br = K.p(t, at, at + 0.15, 'out'); color = K.mix(SEC, TEXT, br);
            const g = Math.exp(-(t - at) / 0.35); if (g > 0.03) { color = K.mix(color, CYAN, 0.55 * g); shadow = `0 0 ${(12 * g).toFixed(1)}px rgba(92,225,230,${(0.85 * g).toFixed(2)})`; }
          }
          if (ad > 0) color = K.mix(color, base, ad * 2);
          css(w, { color, textShadow: shadow });
        });
      } else words.forEach(w => css(w, { color: base, textShadow: 'none' }));
    }
    const y0 = st.bottom - height;
    const s = st.scale == null ? 1 : st.scale, a = st.alpha == null ? 1 : st.alpha;
    const ox = st.origin ? st.origin[0] - st.x : 0, oy = st.origin ? st.origin[1] - y0 : 0;
    css(Dm.root, { left: st.x.toFixed(1) + 'px', top: y0.toFixed(1) + 'px', height: height.toFixed(1) + 'px', width: (st.w || 760) + 'px', transformOrigin: `${ox.toFixed(1)}px ${oy.toFixed(1)}px`, transform: `scale(${s.toFixed(4)})`, opacity: a.toFixed(3) });
  };
  // reading position: sentence index + smooth transition in the 0.55 s before the next sentence starts
  Drum.position = function (tl, t, introAt) {
    const S = tl.sentences;
    if (t < S[0].start) return -1 + K.p(t, introAt, introAt + 0.65, 'inOut');
    for (let i = 0; i < S.length; i++) {
      const next = S[i + 1];
      if (!next || t < next.start) { if (!next) return i; return i + K.p(t, next.start - 0.55, next.start, 'inOut'); }
    }
    return S.length - 1;
  };

  // ================= RECEIPT =================
  const Receipt = {};
  Receipt.render = function (st) {
    const el = document.getElementById('receipt');
    if (!st) { css(el, { visibility: 'hidden' }); return; }
    html(el, `<span class="ok">✓</span>${esc(st.text)}`);
    if (st.right != null) st.x = st.right - el.getBoundingClientRect().width;
    css(el, { visibility: 'visible', left: st.x.toFixed(1) + 'px', top: st.y.toFixed(1) + 'px', opacity: st.alpha.toFixed(3), transform: `translateX(${((1 - st.alpha) * -8).toFixed(1)}px)`, borderRadius: st.square ? '10px' : '17px' });
  };

  window.Lens = Lens; window.Drum = Drum; window.Receipt = Receipt;
})();
