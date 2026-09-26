// Timeline kit for renderAt(t) films. Everything is a pure function of t (seconds).
// Load with <script src="../shared/kit.js"></script>; exposes window.K.
(function () {
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const lerp = (a, b, p) => a + (b - a) * p;
  const ease = {
    linear: p => p,
    in: p => p * p * p,
    out: p => 1 - Math.pow(1 - p, 3),
    inOut: p => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
    outBack: p => { const c1 = 1.4, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); },
    // critically-damped-ish spring settle, good for UI morphs
    spring: p => 1 - Math.exp(-6 * p) * Math.cos(9 * p * (1 - p * 0.6)),
    outQuint: p => 1 - Math.pow(1 - p, 5),
  };
  // progress of t through [a, b], eased
  const p = (t, a, b, e = 'inOut') => ease[e](clamp((t - a) / (b - a)));
  // 0→1 at [a, a+inDur], hold, 1→0 at [b-outDur, b]
  const window_ = (t, a, b, inDur = 0.3, outDur = 0.3, e = 'inOut') =>
    Math.min(p(t, a, a + inDur, e), 1 - p(t, b - outDur, b, e));
  const between = (t, a, b) => t >= a && t < b;

  // deterministic noise for waveforms / jitter
  const hash = n => { const s = Math.sin(n * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
  const noise1 = x => { const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return lerp(hash(i), hash(i + 1), u); };
  const noise = (t, seed = 0, freq = 3) => noise1(t * freq + seed * 17.3);

  // Speech timing: split text into words and give each a start time at `wps` words/s,
  // with small natural jitter and longer gaps after punctuation.
  function speechTimeline(text, start, wps = 2.7, seed = 1) {
    const words = text.split(/\s+/).filter(Boolean);
    let at = start;
    return words.map((w, i) => {
      const item = { w, at, i };
      const base = 1 / wps;
      const jitter = (hash(i + seed * 31) - 0.5) * base * 0.5;
      const punct = /[,—–]$/.test(w) ? base * 0.9 : /[.?!:]$/.test(w) ? base * 1.6 : 0;
      at += base + jitter + punct + Math.max(0, w.length - 7) * 0.02;
      return item;
    });
  }
  const spokenCount = (tl, t) => tl.filter(x => x.at <= t).length;
  const endOf = tl => (tl.length ? tl[tl.length - 1].at + 0.35 : 0);

  // colour mix of two hex colours
  const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const mix = (a, b, q) => { const A = hex(a), B = hex(b); return `rgb(${A.map((v, i) => Math.round(lerp(v, B[i], q))).join(',')})`; };

  // set many style props at once; skips unchanged values for speed
  function css(el, props) {
    for (const k in props) {
      const v = props[k];
      if (el.__last && el.__last[k] === v) continue;
      (el.__last ||= {})[k] = v;
      if (k.startsWith('--')) el.style.setProperty(k, v); else el.style[k] = v;
    }
  }
  function text(el, s) { if (el.__text !== s) { el.__text = s; el.textContent = s; } }
  function html(el, s) { if (el.__html !== s) { el.__html = s; el.innerHTML = s; } }
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  // piecewise keyframes: kf(t, [[t0, v0], [t1, v1, 'out'], ...]) → interpolated number
  function kf(t, frames) {
    if (t <= frames[0][0]) return frames[0][1];
    for (let i = 1; i < frames.length; i++) {
      const [t1, v1, e = 'inOut'] = frames[i], [t0, v0] = frames[i - 1];
      if (t <= t1) return lerp(v0, v1, ease[e](clamp((t - t0) / (t1 - t0))));
    }
    return frames[frames.length - 1][1];
  }
  // same, for 2-D points [x, y]
  const kf2 = (t, frames) => [kf(t, frames.map(f => [f[0], f[1][0], f[2]])), kf(t, frames.map(f => [f[0], f[1][1], f[2]]))];

  window.K = { clamp, lerp, ease, p, win: window_, between, noise, hash, speechTimeline, spokenCount, endOf, mix, css, text, html, $, $$, kf, kf2 };
})();
