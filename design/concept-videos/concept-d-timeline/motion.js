// Motion helpers: keyframed 2-D paths for the pointer, speech amplitude, small utilities.
(function () {
  const K = window.K;
  function curve(a, b, e, bend, side) {
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const cx = (a[0] + b[0]) / 2 - dy * bend * side, cy = (a[1] + b[1]) / 2 + dx * bend * side;
    const u = 1 - e;
    return [u * u * a[0] + 2 * u * e * cx + e * e * b[0], u * u * a[1] + 2 * u * e * cy + e * e * b[1]];
  }
  // segments sorted by t: {t, x, y, dur, ease, bend, side} | {t, dur, fn(p, tt)} | {t, dur, follow(tt)}
  class Path {
    constructor(segs) { this.segs = segs.slice().sort((a, b) => a.t - b.t); }
    startPos(i) {
      if (i === 0) { const s = this.segs[0]; return s.fn ? s.fn(0, s.t) : s.follow ? s.follow(s.t) : [s.x, s.y]; }
      const p = this.segs[i - 1], tAt = this.segs[i].t;
      return p.fn ? p.fn(1, tAt) : p.follow ? p.follow(tAt) : [p.x, p.y];
    }
    at(tt) {
      const S = this.segs; let i = 0;
      while (i + 1 < S.length && S[i + 1].t <= tt) i++;
      const s = S[i];
      if (tt < s.t) return this.startPos(0);
      const p = s.dur > 0 ? K.clamp((tt - s.t) / s.dur) : 1;
      if (s.fn) return s.fn(p, tt);
      const tgt = s.follow ? s.follow(tt) : [s.x, s.y];
      if (p >= 1) return tgt;
      const e = K.ease[s.ease || 'inOut'](p);
      return curve(this.startPos(i), tgt, e, s.bend == null ? 0.1 : s.bend, s.side || (i % 2 ? 1 : -1));
    }
  }
  // voice amplitude 0..1 from every user utterance (window.SPEECH)
  function amp(t) {
    let a = 0;
    for (const u of window.SPEECH) {
      if (t < u.start - 0.05 || t > u.end + 0.5) continue;
      for (const w of u.words) { const d = t - w.at; if (d >= 0 && d < 0.6) a = Math.max(a, Math.exp(-d / 0.16)); }
    }
    return K.clamp(a * (0.72 + 0.28 * K.noise(t, 3, 9)) + 0.05 * K.noise(t, 5, 2));
  }
  // piecewise mode timeline: [[t, mode]] → {mode, since, prev}
  function modeAt(list, t) { let i = 0; while (i + 1 < list.length && list[i + 1][0] <= t) i++; return { mode: list[i][1], since: list[i][0], prev: i > 0 ? list[i - 1][1] : list[0][1] }; }
  // streamed words → html spans fading in at their onset
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  function stream(u, t, cls = '', firstColor = null) {
    return u.words.filter(w => t >= w.at).map((w, i) => `<span class="${cls}" style="opacity:${K.p(t, w.at, w.at + 0.18).toFixed(2)}${i === 0 && firstColor ? `;color:${firstColor}` : ''}">${esc(w.w)}</span>`).join(' ');
  }
  window.Motion = { Path, curve, amp, modeAt, stream, esc };
})();
