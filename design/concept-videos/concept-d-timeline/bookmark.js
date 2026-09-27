// The signature object: a paper bookmark tab flush against the right screen edge. Every
// VoiceFlow surface is the same sheet pulled further out of the edge. Also the three dots
// (fixed on screen) and the red ink trace along the bottom edge while listening.
(function () {
  const K = window.K, css = K.css;
  const EDGE = 1920, CY = 670;                 // the bookmark's vertical centre (62% of 1080)
  const INK = '#1C1A17', RED = '#D6442C', BLUE = '#2E56C9', AMBER = '#B26A00';
  const Paper = {};
  // fixed rects per state; strip/receipt heights are dynamic (h passed in)
  Paper.rect = function (state, h) {
    switch (state) {
      case 'tab': return { x: EDGE - 26, y: CY - 39, w: 26, h: 78, r: 6 };
      case 'slip': return { x: EDGE - 440, y: CY - 42, w: 440, h: 84, r: 8 };
      case 'reader': return { x: EDGE - 520, y: CY - 36, w: 520, h: 72, r: 8 };
      case 'sheet': { const hh = h || 520; return { x: EDGE - 1100, y: 880 - hh, w: 1100, h: hh, r: 10 }; }
      case 'strip': return { x: EDGE - 240, y: Math.round(CY - h / 2), w: 240, h, r: 8 };
      case 'receipt': return { x: EDGE - 640, y: Math.round(CY - h / 2), w: 640, h, r: 8 };
      case 'stub': return { x: EDGE - 640, y: Math.round(CY - h / 2) + h - 30, w: 640, h: 30, r: 0 };
      case 'chip': return { x: EDGE - 320, y: CY - 15, w: 320, h: 30, r: 6 };
    }
  };
  // colour mix that accepts hex or rgb() strings (K.mix only parses hex)
  const rgbOf = c => c.startsWith('#') ? [1, 3, 5].map(i => parseInt(c.slice(i, i + 2), 16)) : c.match(/\d+/g).slice(0, 3).map(Number);
  const mix = (a, b, q) => { const A = rgbOf(a), B = rgbOf(b); return `rgb(${A.map((v, i) => Math.round(K.lerp(v, B[i], q))).join(',')})`; };
  const lerpRect = (a, b, p) => ({ x: K.lerp(a.x, b.x, p), y: K.lerp(a.y, b.y, p), w: K.lerp(a.w, b.w, p), h: K.lerp(a.h, b.h, p), r: K.lerp(a.r, b.r, p) });
  let E = null;
  Paper.build = function () {
    E = { root: document.getElementById('paper'), trace: document.getElementById('trace'), dots: [...document.querySelectorAll('#dots i')] };
    E.tracePath = document.createElementNS('http://www.w3.org/2000/svg', 'path'); E.trace.appendChild(E.tracePath);
    E.views = {}; for (const id of ['slip', 'reader', 'sheet', 'strip', 'receipt', 'chip']) { E.views[id] = document.getElementById('v-' + id); E.views[id].style.display = 'block'; }   // shown while the modules build and measure; Paper.render manages display afterwards
  };
  // states: [[t, state, dur]]; heights: {strip: h(t), receipt: h(t)}
  Paper.stateAt = function (states, t, heights) {
    let i = 0; while (i + 1 < states.length && states[i + 1][0] <= t) i++;
    const [since, state, dur = 0.4] = states[i], prev = i > 0 ? states[i - 1][1] : 'tab';
    const hOf = s => s === 'strip' ? heights.strip(t) : (s === 'receipt' || s === 'stub') ? heights.receipt(t) : s === 'sheet' ? heights.sheet(t) : 0;
    const A = Paper.rect(prev, hOf(prev)), B = Paper.rect(state, hOf(state));
    const p = dur > 0 ? K.p(t, since, since + dur, 'inOut') : 1;
    const rect = p >= 1 ? B : lerpRect(A, B, p);
    const view = s => s === 'stub' ? 'receipt' : s === 'tab' ? null : s;
    const inA = K.p(t, since + dur * 0.35, since + dur, 'out'), outA = 1 - K.p(t, since, since + dur * 0.6, 'in');
    const alphas = {};
    if (view(state)) alphas[view(state)] = view(prev) === view(state) ? 1 : inA;
    if (view(prev) && view(prev) !== view(state)) alphas[view(prev)] = outA;
    return { state, prev, since, p, rect, alphas, rectOf: s => Paper.rect(s, hOf(s)) };
  };
  // render the container; `viewRects` gives each view its own screen rect so it stays anchored while the paper morphs
  Paper.render = function (st, viewRects, hidden) {
    const r = st.rect;
    css(E.root, { visibility: hidden ? 'hidden' : 'visible', left: r.x.toFixed(1) + 'px', top: r.y.toFixed(1) + 'px', width: r.w.toFixed(1) + 'px', height: r.h.toFixed(1) + 'px', borderRadius: `${r.r.toFixed(1)}px 0 0 ${r.r.toFixed(1)}px` });
    for (const id in E.views) {
      const a = st.alphas[id] || 0, el = E.views[id];
      if (a <= 0.001) { css(el, { display: 'none' }); continue; }
      const vr = viewRects[id];
      css(el, { display: 'block', opacity: a.toFixed(3), left: (vr.x - r.x).toFixed(1) + 'px', top: (vr.y - r.y).toFixed(1) + 'px' });
    }
  };
  // red ink trace along the bottom edge: a seismograph of the voice, drawn right→left
  Paper.renderTrace = function (t, width, alpha) {
    if (alpha <= 0.001) { css(E.trace, { visibility: 'hidden' }); return; }
    const a = Motion.amp(t); let d = '';
    const n = Math.floor(width / 5);
    for (let i = 0; i <= n; i++) {
      const x = width - i * 5, age = i * 0.045;                     // older samples to the left
      const env = Math.max(0, a - age * 0.9) * (0.5 + 0.5 * K.noise(t - age, 7, 14));
      const y = 10 - env * 7 * (0.6 + 0.4 * Math.abs(K.noise(t * 1.3 - age * 2, 11, 30) * 2 - 1));
      d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(2);
    }
    E.tracePath.setAttribute('d', d);
    css(E.trace, { visibility: 'visible', opacity: alpha.toFixed(3), width: width.toFixed(1) + 'px' });
  };
  // dots: fixed on screen. mode: rest | listen | think | speak | record. ticks: [0..1]×3 word pulses.
  Paper.renderDots = function (t, m, unread, ticks, hidden) {
    const q = K.p(t, m.since, m.since + 0.35, 'inOut');
    const LIGHT = '#C9C2B6';
    const colorOf = (mode, i) => mode === 'listen' || mode === 'record' ? RED : mode === 'think' ? LIGHT : (unread && i === 1 && mode === 'rest') ? AMBER : INK;
    for (let i = 0; i < 3; i++) {
      const el = E.dots[i];
      let cPrev = colorOf(m.prev, i), cCur = colorOf(m.mode, i);
      // thinking: a blue highlight walks down the three positions
      // thinking: one blue dot walks down the three positions (light grey elsewhere)
      const walk = mode => { if (mode !== 'think') return 0; const pos = ((t - m.since) * 3.0) % 3; let dd = Math.abs(pos - i); dd = Math.min(dd, 3 - dd); return Math.pow(Math.max(0, 1 - dd / 0.75), 0.6); };
      const wPrev = walk(m.prev), wCur = walk(m.mode);
      const base = mix(cPrev || INK, cCur || INK, q);
      const w = K.lerp(wPrev, wCur, q);
      let color = w > 0 ? mix(base, BLUE, w) : base;
      const tick = ticks ? ticks[i] : 0;
      if (tick > 0) color = mix(color, BLUE, tick);          // speaking: the dot ticks blue and grows per word
      const scale = 1 + 0.8 * tick;
      const ring = unread && i === 1 && (m.mode === 'rest' || (m.prev === 'rest' && q < 1)) ? (m.mode === 'rest' ? 1 : 1 - q) : 0;
      css(el, { background: color, transform: `scale(${scale.toFixed(3)})`, boxShadow: ring > 0.01 ? `0 0 0 1.5px ${'#FBF8F1'}, 0 0 0 2.5px rgba(178,106,0,${(0.9 * ring).toFixed(2)})` : 'none', visibility: hidden ? 'hidden' : 'visible' });
    }
  };
  // speaking ticks per word from reader programmes
  Paper.ticks = function (t) {
    const out = [0, 0, 0];
    for (const prog of window.READS) {
      if (t < prog.start - 0.2 || t > prog.end + 0.5) continue;
      let idx = 0;
      for (const s of prog.sentences) for (const w of s.words) { const d = t - w.at; if (d >= 0 && d < 0.4) out[idx % 3] += Math.exp(-d / 0.13); idx++; }
    }
    return out.map(v => Math.min(1, v));
  };
  window.Paper = Paper;
})();
