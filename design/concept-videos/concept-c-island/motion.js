// Motion helpers for Concept C: keyframed 2-D paths (pointer), speech amplitude, and the
// effects canvas (light trail on delivery). Adapted from concept-b-orbit/orbit.js. Pure in t.
(function () {
  const K = window.K;
  const TAU = Math.PI * 2;

  // a gentle "pop" ease for UI growth: ~1.2% overshoot, settles cleanly
  K.ease.pop = p => { const c1 = 0.6, c3 = c1 + 1; return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2); };

  // ---- keyframed 2-D path: segments sorted by t. Each segment moves from the previous position
  // to its target over `dur` seconds along a gentle curve.
  //   {t, x, y, dur, ease, bend, side}   static target
  //   {t, dur, fn(p, tt) -> [x,y]}       parametric motion (p = progress 0..1)
  //   {t, dur, follow(tt) -> [x,y]}      moving target (glide onto it, then track it)
  function curve(a, b, e, bend, side) {
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const cx = (a[0] + b[0]) / 2 - dy * bend * side, cy = (a[1] + b[1]) / 2 + dx * bend * side;
    const u = 1 - e;
    return [u * u * a[0] + 2 * u * e * cx + e * e * b[0], u * u * a[1] + 2 * u * e * cy + e * e * b[1]];
  }
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
      return curve(this.startPos(i), tgt, e, s.bend == null ? 0.12 : s.bend, s.side || (i % 2 ? 1 : -1));
    }
  }

  // ---- geometry sequence: [{at, dur, ease, ...dims}] → fn(t) → dims. Each entry starts moving
  // at `at` from the previous entry's values to its own over `dur` seconds.
  // Keys a later entry leaves out simply hold. `dur_<key>` overrides `dur` for one key.
  function seq(entries, keys) {
    const frames = {}, lastEnd = {}, prev = {};
    for (const k of keys) { frames[k] = []; lastEnd[k] = -Infinity; }
    let first = true;
    for (const e of entries) {
      for (const k of keys) {
        const has = e[k] != null;
        if (first) { const v = has ? e[k] : 0; frames[k].push([e.at, v]); prev[k] = v; lastEnd[k] = e.at; continue; }
        if (!has) continue;
        const dur = e['dur_' + k] != null ? e['dur_' + k] : (e.dur || 0.0001);
        if (e.at < lastEnd[k] - 1e-6) console.error(`[seq] overlapping transition for ${k} at ${e.at.toFixed(2)} (previous ends ${lastEnd[k].toFixed(2)})`);
        if (e.at > lastEnd[k] + 1e-6) frames[k].push([e.at, prev[k]]);
        frames[k].push([Math.max(e.at, lastEnd[k]) + dur, e[k], e.ease || 'pop']);
        prev[k] = e[k]; lastEnd[k] = Math.max(e.at, lastEnd[k]) + dur;
      }
      first = false;
    }
    return t => { const o = {}; for (const k of keys) o[k] = K.kf(t, frames[k]); return o; };
  }

  // ---- voice amplitude 0..1 from every user utterance (window.SPEECH set by timeline.js)
  function amp(t) {
    let a = 0;
    for (const u of window.SPEECH) {
      if (t < u.start - 0.05 || t > u.end + 0.5) continue;
      for (const w of u.words) { const d = t - w.at; if (d >= 0 && d < 0.6) a = Math.max(a, Math.exp(-d / 0.16)); }
    }
    return K.clamp(a * (0.72 + 0.28 * K.noise(t, 3, 9)) + 0.05 * K.noise(t, 5, 2));
  }

  // ---- effects canvas ----
  const cv = document.getElementById('fx'), ctx = cv.getContext('2d');
  function dot(x, y, r, rgb, a, glow) {
    if (glow > 0) { ctx.shadowColor = `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${0.9 * glow})`; ctx.shadowBlur = 10 * glow; } else ctx.shadowBlur = 0;
    ctx.fillStyle = `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;
    ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill(); ctx.shadowBlur = 0;
  }
  // thin light trail along a curve from a to b, u = head progress 0..1
  function trail(a, b, u, rgb = [255, 210, 140], n = 34, side = 1, bend = 0.18) {
    for (let k = 0; k < n; k++) {
      const uk = u - k * 0.011; if (uk <= 0 || uk >= 1) continue;
      const [x, y] = curve(a, b, uk, bend, side);
      dot(x, y, 2.4 * (1 - k / n) + 0.8, rgb, (1 - k / n) * 0.95, 1.0);
    }
  }
  const clear = () => ctx.clearRect(0, 0, 1920, 1080);

  window.Motion = { Path, curve, seq, amp, dot, trail, clear, ctx };
})();
