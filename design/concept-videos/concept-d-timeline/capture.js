// Scene 6/7: pen-on-paper marks anchored inside the Pantrella page, the film-strip capture
// record, the printed receipt (payload) and its tear-off.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const esc = Motion.esc;
  const s6 = T.s6, s7 = T.s7, c0 = s6.c0;
  const RED = '#D6442C';
  const NS = 'http://www.w3.org/2000/svg';
  const ORIGIN = [G.CHROME.x, G.CHROME.y + G.CHROME_HEAD];
  const Cap = {}; const E = {};
  const P = (x, y) => `${x.toFixed(1)} ${y.toFixed(1)}`;
  const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  const ANN = D.annotations;
  const TAGS = ['article.meal-card', 'button.primary', 'button.primary', 'span.kcal'];
  const FRAME_H = 54, FRAME_GAP = 6, STRIP_TOP = 32, STRIP_BOTTOM = 28;

  Cap.build = function () {
    const tue = Desktop.planRect('.card[data-day="Tue"]'), btn = Desktop.planRect('#pn-shop'), kcal = Desktop.planRect('.card[data-day="Wed"] .meta .m1');
    const cx = tue.x + tue.w / 2, cy = tue.y + tue.h / 2;
    Cap.geo = {
      tue, btn, kcal,
      circle: { cx, cy, rx: tue.w / 2 + 16, ry: tue.h / 2 + 14, a0: -2.0 },
      arrow: { a: [cx - 60, cy + tue.h / 2 + 46], b: [btn.x + btn.w * 0.62, btn.y - 10] },
      label: [btn.x + 4, btn.y + btn.h + 7],
      strike: { a: [kcal.x - 4, kcal.y + kcal.h / 2 + 1.5], b: [kcal.x + kcal.w + 4, kcal.y + kcal.h / 2 - 2] },
    };
    Cap.toScreen = (p, scroll = 0) => [p[0] + ORIGIN[0], p[1] + ORIGIN[1] - scroll];
    const svg = Desktop.$.marks;
    const mk = (tag, attrs, parent = svg) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); parent.appendChild(e); return e; };
    E.circle = mk('path', { fill: RED }); E.arrow = mk('path', { fill: RED }); E.strike = mk('path', { fill: RED });
    E.corners = [0, 1, 2, 3].map(() => mk('path', { fill: 'none', stroke: RED, 'stroke-width': 1.5, 'stroke-linecap': 'round', opacity: 0 }));
    E.label = document.createElement('div'); E.label.className = 'mk-label'; css(E.label, { left: Cap.geo.label[0] + 'px', top: Cap.geo.label[1] + 'px', transform: 'rotate(-1.2deg)' }); Desktop.$.mkHtml.appendChild(E.label);
    E.tags = TAGS.map(n => { const d = document.createElement('div'); d.className = 'mk-tag'; d.textContent = n; css(d, { visibility: 'hidden' }); Desktop.$.mkHtml.appendChild(d); return d; });
    // film strip
    const strip = document.getElementById('v-strip');
    strip.innerHTML = `<div class="st-rec"><i></i><span class="rt">REC 0:00</span><span class="wn">Chrome</span></div>` +
      ANN.map((a, i) => `<div class="fr"><div class="th"></div><div class="ft"><div class="tw"><span class="tm">${fmt(a.t)}</span>${esc(a.said)}</div></div></div>`).join('') +
      `<div class="st-live"><span class="lv"></span></div>`;
    E.strip = strip; E.recI = strip.querySelector('.st-rec i'); E.recT = strip.querySelector('.rt'); E.frames = [...strip.querySelectorAll('.fr')]; E.live = strip.querySelector('.st-live'); E.lv = strip.querySelector('.lv');
    E.frames.forEach((f, i) => f.querySelector('.th').appendChild(thumb(i + 1, 94 / G.CHROME.w)));
    // receipt
    const rc = document.getElementById('v-receipt'); rc.classList.add('rc');
    const lines = D.payloadMarkdown;
    const entries = []; for (let i = 3; i < lines.length; i++) { if (lines[i].startsWith('[')) entries.push([lines[i]]); else entries[entries.length - 1].push(lines[i]); }
    const HEAD_TOP = 14, ENT_TOP = 76, ENT_H = 60;
    const entHtml = entries.map((e, i) => {
      // the filename column always sits on the entry's second line so the four filenames align
      const parts = e.map(l => { const m = l.match(/^(.*?)\s*(shot-\d\.png)$/); return { body: (m ? m[1] : l).replace(/^\s+/, ''), file: m ? m[2] : '' }; });
      const file = parts.map(x => x.file).find(Boolean) || '';
      const l0 = parts[0].body, l1 = parts[1] ? parts[1].body : '';
      const ln = `<div class="ln" style="top:0"><span class="q">${esc(l0)}</span></div><div class="ln" style="top:18px"><span class="m">${esc(l1)}</span><span class="f">${file}</span></div>`;
      return `<div class="rc-e" style="top:${ENT_TOP + i * ENT_H}px"><div class="th"></div>${ln}</div>`;
    }).join('');
    const tearTop = ENT_TOP + entries.length * ENT_H + 6;
    Cap.RECEIPT_H = tearTop + 30;
    rc.innerHTML = `<div class="rc-body"><div class="rc-head" style="top:${HEAD_TOP}px"><div class="rc-t">${esc(lines[0])}</div><div class="rc-s">${esc(lines[1])}</div><div class="rc-s">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</div></div>${entHtml}</div>
      <div class="rc-tear" style="top:${tearTop}px"><span class="a">Copy for any agent<span class="kc">⌘C</span></span><span>·</span><span>Send to…</span></div>`;
    E.rc = rc; css(rc, { height: Cap.RECEIPT_H + 'px' });
    [...rc.querySelectorAll('.rc-e .th')].forEach((th, i) => th.appendChild(thumb(i + 1, 94 / G.CHROME.w)));
    // the torn-off body (a copy) for the ⌘C animation
    E.tear = document.getElementById('tear'); E.tear.classList.add('rc');
    E.tear.innerHTML = rc.querySelector('.rc-body').outerHTML; css(E.tear, { width: '640px', height: (tearTop) + 'px' });
  };
  // a static miniature of the plan page with the first k marks at their final geometry
  function thumb(k, scale) {
    const inner = document.createElement('div'); inner.className = 'thumb-inner';
    const clone = Desktop.$.scrPlan.cloneNode(true);
    clone.removeAttribute('id'); clone.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
    clone.querySelector('.marks').remove(); clone.querySelector('.mk-html').remove();
    clone.style.visibility = ''; clone.style.transform = 'none';
    inner.appendChild(clone);
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('class', 'marks'); svg.innerHTML = staticMarks(k); inner.appendChild(svg);
    if (k >= 3) { const l = document.createElement('div'); l.className = 'mk-label'; l.textContent = ANN[2].text; css(l, { left: Cap.geo.label[0] + 'px', top: Cap.geo.label[1] + 'px', transform: 'rotate(-1.2deg)' }); inner.appendChild(l); }
    css(inner, { transform: `scale(${scale})` });
    return inner;
  }
  // ---- pen ribbons: a centre line becomes a filled polygon with pressure variation ----
  function ribbon(pts, seed, w0 = 1.3) {
    if (pts.length < 2) return '';
    const L = [], R = []; const n = pts.length;
    for (let i = 0; i < n; i++) {
      const p = pts[i], q = pts[Math.min(i + 1, n - 1)], o = pts[Math.max(i - 1, 0)];
      const dx = q[0] - o[0], dy = q[1] - o[1], len = Math.hypot(dx, dy) || 1;
      const nx = -dy / len, ny = dx / len, u = i / (n - 1);
      const press = 0.8 + 0.4 * K.noise(u * 9, seed, 1) + 0.25 * Math.sin(u * Math.PI);
      const h = w0 * press;
      L.push([p[0] + nx * h, p[1] + ny * h]); R.push([p[0] - nx * h, p[1] - ny * h]);
    }
    return 'M' + L.map(p => P(p[0], p[1])).join('L') + 'L' + R.reverse().map(p => P(p[0], p[1])).join('L') + 'Z';
  }
  Cap.circlePoint = function (u, wobble = 1) {
    const c = Cap.geo.circle, th = c.a0 + u * Math.PI * 2.08;
    const w = 1 + wobble * 0.04 * (K.noise(u * 5, 2, 1) - 0.5) * 2, drift = wobble * 6 * (K.noise(u * 3, 4, 1) - 0.5);
    return [c.cx + Math.cos(th) * c.rx * w + drift, c.cy + Math.sin(th) * c.ry * w];
  };
  function circlePts(prog, wobble) { const n = Math.max(2, Math.ceil(72 * prog)); const pts = []; for (let i = 0; i <= n; i++) pts.push(Cap.circlePoint(Math.min(prog, i / 72), wobble)); return pts; }
  Cap.arrowPoint = function (u, snap = 1) {
    const A = Cap.geo.arrow, b = [K.lerp(A.b[0] + 12, A.b[0], snap), K.lerp(A.b[1] - 8, A.b[1], snap)];
    const [x, y] = Motion.curve(A.a, b, u, 0.08, 1); return [x, y];
  };
  function arrowPath(prog, snap) {
    const n = Math.max(2, Math.ceil(30 * prog)); const pts = []; for (let i = 0; i <= n; i++) pts.push(Cap.arrowPoint(Math.min(prog, i / 30), snap));
    let d = ribbon(pts, 3);
    if (prog >= 0.97) {
      const tip = pts[pts.length - 1], prev = pts[pts.length - 4] || pts[0], ang = Math.atan2(tip[1] - prev[1], tip[0] - prev[0]);
      for (const s of [-1, 1]) { const a2 = ang + Math.PI + s * 0.48; d += ribbon([[tip[0], tip[1]], [tip[0] + Math.cos(a2) * 9, tip[1] + Math.sin(a2) * 9], [tip[0] + Math.cos(a2) * 17, tip[1] + Math.sin(a2) * 17]], 5 + s, 1.2); }
    }
    return d;
  }
  function strikePath(prog) {
    const S = Cap.geo.strike, n = Math.max(2, Math.ceil(20 * prog)); const pts = [];
    for (let i = 0; i <= n; i++) { const u = Math.min(prog, i / 20); pts.push([K.lerp(S.a[0], S.b[0], u), K.lerp(S.a[1], S.b[1], u) + 1.2 * Math.sin(u * 7)]); }
    return ribbon(pts, 7, 1.25);
  }
  function staticMarks(k) {
    let s = '';
    if (k >= 1) s += `<path d="${ribbon(circlePts(1, 1), 1)}" fill="${RED}"/>`;
    if (k >= 2) s += `<path d="${arrowPath(1, 1)}" fill="${RED}"/>`;
    if (k >= 4) s += `<path d="${strikePath(1)}" fill="${RED}"/>`;
    return s;
  }
  // corner ticks snapping onto an element's bounds + a paper tag
  function anchorCue(i, at, r, t) {
    const pin = K.p(t, at, at + 0.25, 'out'), fade = 1 - K.p(t, at + 1.1, at + 1.5);
    const a = pin * fade, m = 4 + 6 * (1 - pin), L = 9;
    const x0 = r.x - m, y0 = r.y - m, x1 = r.x + r.w + m, y1 = r.y + r.h + m;
    const g = E.corners[i];
    g.setAttribute('d', `M${P(x0, y0 + L)}L${P(x0, y0)}L${P(x0 + L, y0)} M${P(x1 - L, y0)}L${P(x1, y0)}L${P(x1, y0 + L)} M${P(x1, y1 - L)}L${P(x1, y1)}L${P(x1 - L, y1)} M${P(x0 + L, y1)}L${P(x0, y1)}L${P(x0, y1 - L)}`);
    g.setAttribute('opacity', a.toFixed(3));
    css(E.tags[i], { left: (x0).toFixed(1) + 'px', top: (y0 - 26).toFixed(1) + 'px', opacity: a.toFixed(3), visibility: a > 0.01 ? 'visible' : 'hidden' });
  }
  function noCue(i) { E.corners[i].setAttribute('opacity', 0); css(E.tags[i], { visibility: 'hidden' }); }
  // ---- marks (every frame; marks persist until the capture ends) ----
  Cap.renderMarks = function (t) {
    const g = Cap.geo, live = t >= c0;
    const endFade = 1 - K.p(t, s7.stop + 0.2, s7.stop + 0.7);
    const cp = K.p(t, s6.circle[0], s6.circle[1], 'linear'), snap1 = K.p(t, s6.snap1, s6.snap1 + 0.3, 'out');
    E.circle.setAttribute('d', live && cp > 0 ? ribbon(circlePts(cp, 1), 1) : ''); E.circle.setAttribute('opacity', endFade.toFixed(3));
    if (cp > 0) anchorCue(0, s6.snap1, g.tue, t); else noCue(0);
    const ap = K.p(t, s6.arrow[0], s6.arrow[1], 'inOut'), snap2 = K.p(t, s6.snap2, s6.snap2 + 0.3, 'out');
    E.arrow.setAttribute('d', live && ap > 0 ? arrowPath(ap, snap2) : ''); E.arrow.setAttribute('opacity', endFade.toFixed(3));
    if (ap > 0) anchorCue(1, s6.snap2, g.btn, t); else noCue(1);
    const lp = K.p(t, s6.label[0], s6.label[1], 'linear'), full = ANN[2].text;
    text(E.label, live ? full.slice(0, Math.round(full.length * lp)) : '');
    css(E.label, { opacity: endFade.toFixed(3) });
    if (lp > 0) anchorCue(2, s6.snap3, { x: g.btn.x, y: g.btn.y, w: g.btn.w, h: g.btn.h + 26 }, t); else noCue(2);
    const sp = K.p(t, s6.strike[0], s6.strike[1], 'inOut');
    E.strike.setAttribute('d', live && sp > 0 ? strikePath(sp) : ''); E.strike.setAttribute('opacity', endFade.toFixed(3));
    if (sp > 0) anchorCue(3, s6.snap4, { x: g.kcal.x - 2, y: g.kcal.y - 1, w: g.kcal.w + 4, h: g.kcal.h + 2 }, t); else noCue(3);
  };
  // ---- film strip ----
  const FRAMES_AT = () => [s6.frame1, s6.frame2, s6.frame3, s6.frame4];
  Cap.stripHeight = function (t) { let fb = 0; for (const at of FRAMES_AT()) fb += K.p(t, at, at + 0.4, 'out') * (FRAME_H + FRAME_GAP); return STRIP_TOP + fb + STRIP_BOTTOM; };
  Cap.renderStrip = function (t, utter) {
    const rec = t < s7.stop;
    text(E.recT, `REC ${fmt(Math.max(0, t - c0))}`);
    css(E.recI, { opacity: rec ? (0.55 + 0.45 * Math.sin(t * 5)).toFixed(2) : '1' });
    let y = STRIP_TOP;
    FRAMES_AT().forEach((at, i) => {
      const p = K.p(t, at, at + 0.4, 'out');
      const f = E.frames[i];
      if (p <= 0) { css(f, { visibility: 'hidden' }); return; }
      css(f, { visibility: 'visible', top: y.toFixed(1) + 'px', opacity: K.p(t, at + 0.1, at + 0.45).toFixed(3), transform: `translateY(${((1 - p) * 8).toFixed(1)}px)` });
      y += p * (FRAME_H + FRAME_GAP);
    });
    css(E.live, { top: y.toFixed(1) + 'px' });
    // live words (right-aligned; older words slide left under the mask)
    let cur = null; for (const u of utter) if (t >= u.start - 0.2) cur = u;
    if (cur) {
      const fadeOut = 1 - K.p(t, cur.end + 1.4, cur.end + 1.9);
      html(E.lv, Motion.stream(cur, t)); css(E.lv, { opacity: fadeOut.toFixed(3) });
    } else html(E.lv, '');
    css(E.strip, { height: Cap.stripHeight(t).toFixed(1) + 'px' });
  };
  // ---- tear-off ----
  Cap.renderTear = function (t, fromRect, toPoint) {
    const p = K.p(t, s7.copy, s7.copy + s7.tearDur, 'in');
    if (t < s7.copy || p >= 1) { css(E.tear, { display: 'none' }); return; }
    const e = K.ease.inOut(p);
    const x = K.lerp(fromRect.x, toPoint[0] - 40, e), y = K.lerp(fromRect.y, toPoint[1] - 10, e);
    const sc = K.lerp(1, 0.1, e), rot = -4 * Math.sin(p * Math.PI), a = 1 - K.p(p, 0.65, 1);
    css(E.tear, { display: 'block', left: x.toFixed(1) + 'px', top: y.toFixed(1) + 'px', transform: `rotate(${rot.toFixed(2)}deg) scale(${sc.toFixed(3)})`, transformOrigin: '100% 100%', opacity: a.toFixed(3) });
  };
  window.Cap = Cap;
})();
