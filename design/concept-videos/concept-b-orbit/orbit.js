// The signature object ("the triad") and the top-level effects canvas. Pure functions of t.
(function () {
  const K = window.K, T = window.T;
  const TAU = Math.PI * 2;

  // ---- keyframed 2-D path: segments sorted by t. Each segment moves from the previous
  // position to its target over `dur` seconds along a gentle curve. Kinds:
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
    target(i, tt) { const s = this.segs[i]; return s.fn ? s.fn(1, tt) : s.follow ? s.follow(tt) : [s.x, s.y]; }
    startPos(i) { // position at the start of segment i
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

  const Orbit = { Path, curve };
  Orbit.modes = [];      // [[t, mode]] set by film.js — rest | listen | think | speak | record
  Orbit.path = null;     // Path — set by film.js
  Orbit.pulses = [];     // [{words}] — reader timelines that drive the speaking pulse
  Orbit.unreadUntil = 0; Orbit.unreadFrom = 0; // amber dot between these times

  Orbit.modeAt = function (t) {
    const M = Orbit.modes; let i = 0;
    while (i + 1 < M.length && M[i + 1][0] <= t) i++;
    return { mode: M[i][1], since: M[i][0], prev: i > 0 ? M[i - 1][1] : 'rest' };
  };
  // voice amplitude 0..1 from every user utterance
  Orbit.amp = function (t) {
    let a = 0;
    for (const u of window.SPEECH) {
      if (t < u.start - 0.05 || t > u.end + 0.5) continue;
      for (const w of u.words) { const d = t - w.at; if (d >= 0 && d < 0.6) a = Math.max(a, Math.exp(-d / 0.16)); }
    }
    return K.clamp(a * (0.72 + 0.28 * K.noise(t, 3, 9)) + 0.05 * K.noise(t, 5, 2));
  };
  const SPEED = { rest: 0, listen: 2.4, think: 11, speak: 0, record: 2.0 };
  const AMPGAIN = { rest: 0, listen: 5.5, think: 0, speak: 0, record: 4.5 };
  const PARAM = {
    rest:   { R: 9.2, color: [234, 242, 255], alpha: .82, trail: 0, glow: 0 },
    listen: { R: 11.5, color: [92, 225, 230], alpha: 1, trail: 0.8, glow: 1 },
    think:  { R: 7, color: [155, 140, 255], alpha: 1, trail: 1, glow: 1 },
    speak:  { R: 9.2, color: [170, 236, 244], alpha: 1, trail: 0, glow: .8 },
    record: { R: 11.5, color: [92, 225, 230], alpha: 1, trail: .7, glow: 1 },
  };
  function blendParams(t) {
    const m = Orbit.modeAt(t), q = K.p(t, m.since, m.since + 0.35, 'inOut');
    const A = PARAM[m.prev], B = PARAM[m.mode], amp = Orbit.amp(t);
    const lerp = K.lerp;
    const out = { mode: m.mode, amp, q, since: m.since };
    out.R = lerp(A.R, B.R, q) + (m.mode === 'listen' || m.mode === 'record' ? amp * 4 * q : 0);
    out.color = A.color.map((v, i) => Math.round(lerp(v, B.color[i], q)));
    out.alpha = lerp(A.alpha, B.alpha, q); out.trail = lerp(A.trail, B.trail, q); out.glow = lerp(A.glow, B.glow, q);
    return out;
  }
  function speedAt(t) {
    const m = Orbit.modeAt(t), q = K.p(t, m.since, m.since + 0.35, 'inOut'), amp = Orbit.amp(t);
    const sp = mode => SPEED[mode] + AMPGAIN[mode] * amp;
    return K.lerp(sp(m.prev), sp(m.mode), q);
  }
  // integrate the orbit angle once (pure: speed depends only on t)
  let THETA = null; const DT = 1 / 240;
  Orbit.init = function () {
    const n = Math.ceil(T.end / DT) + 2; THETA = new Float32Array(n); let th = -Math.PI / 2;
    for (let i = 0; i < n; i++) { THETA[i] = th; th += speedAt(i * DT) * DT; }
  };
  Orbit.theta = function (t) {
    if (t <= 0) return THETA[0]; const x = t / DT, i = Math.min(THETA.length - 2, Math.floor(x)), f = x - i;
    return THETA[i] + (THETA[i + 1] - THETA[i]) * f;
  };
  Orbit.pos = t => Orbit.path.at(t);

  // speaking pulse per dot (0..1) from reader word onsets
  function pulses(t) {
    const out = [0, 0, 0];
    for (const prog of Orbit.pulses) {
      if (t < prog.start || t > prog.end + 0.5) continue;
      let idx = 0;
      for (const s of prog.sentences) for (const w of s.words) { const d = t - w.at; if (d >= 0 && d < 0.5) out[idx % 3] += Math.exp(-d / 0.16); idx++; }
    }
    return out.map(v => Math.min(1, v));
  }

  // ---- canvas ----
  const cv = document.getElementById('fx'), ctx = cv.getContext('2d');
  Orbit.ctx = ctx;
  function dot(x, y, r, rgb, a, glow) {
    if (glow > 0) { ctx.shadowColor = `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${0.9 * glow})`; ctx.shadowBlur = 10 * glow; } else ctx.shadowBlur = 0;
    ctx.fillStyle = `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;
    ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill(); ctx.shadowBlur = 0;
  }
  Orbit.dot = dot;
  const AMBER = [255, 181, 71];
  Orbit.drawTriad = function (t, scale = 1) {
    const P = blendParams(t), [cx, cy] = Orbit.pos(t), th = Orbit.theta(t);
    const unread = t >= Orbit.unreadFrom && t < Orbit.unreadUntil;
    const pl = P.mode === 'speak' || (P.q < 1 && P.since && Orbit.modeAt(t).prev === 'speak') ? pulses(t) : [0, 0, 0];
    // trails
    if (P.trail > 0.02) {
      for (let k = 8; k >= 1; k--) {
        const tk = t - k * 0.026; if (tk < 0) continue;
        const [ox, oy] = Orbit.pos(tk), thk = Orbit.theta(tk), Rk = P.R;
        const a = P.trail * (1 - k / 9) * 0.5;
        for (let d = 0; d < 3; d++) {
          const ang = thk + d * TAU / 3;
          const rgb = unread && d === 0 ? AMBER : P.color;
          dot(ox + Math.cos(ang) * Rk * scale, oy + Math.sin(ang) * Rk * scale, 3 * (1 - k / 14) * scale, rgb, a, 0);
        }
      }
    }
    for (let d = 0; d < 3; d++) {
      const ang = th + d * TAU / 3;
      let R = P.R;
      if (unread && d === 0 && P.mode === 'rest') R += 4 + 1.5 * Math.sin(t * 1.3);
      const rgb = unread && d === 0 ? AMBER : P.color;
      const r = 3 * (1 + 0.6 * pl[d]) * scale;
      const x = cx + Math.cos(ang) * R * scale, y = cy + Math.sin(ang) * R * scale;
      dot(x, y, r + 1.6 * scale, [7, 9, 13], 0.5, 0);   // ink halo: keeps the dots legible over bright pages
      dot(x, y, r, rgb, unread && d === 0 ? 1 : P.alpha, Math.max(P.glow, pl[d]) * (unread && d === 0 ? 0.8 : 1));
    }
  };
  // a small glowing bead
  Orbit.bead = function (x, y, r, a, rgb = [200, 245, 250]) { dot(x, y, r, rgb, a, 1.2); };
  // comet of particles along a curve from a to b, u = head progress 0..1
  Orbit.comet = function (a, b, u, rgb = [92, 225, 230], n = 26, side = 1) {
    for (let k = 0; k < n; k++) {
      const uk = u - k * 0.022; if (uk <= 0 || uk >= 1) continue;
      const [x, y] = curve(a, b, uk, 0.22, side);
      dot(x, y, 2.6 * (1 - k / n) + 0.6, rgb, (1 - k / n) * 0.9, 0.8);
    }
  };
  Orbit.clear = function () { ctx.clearRect(0, 0, 1920, 1080); };
  window.Orbit = Orbit;
})();
