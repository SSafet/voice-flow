// Scene 6/7: anchored marks inside the Pantrella page, the capture trail, and the payload packet.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const CYAN = '#5CE1E6', AMBER = '#FFB547';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const s6 = T.s6, s7 = T.s7, c0 = s6.c0;
  const Cap = {};
  const NS = 'http://www.w3.org/2000/svg';
  const ORIGIN = [G.CHROME.x, G.CHROME.y + 84];   // page (0,0) on screen at scroll 0
  const E = {};

  Cap.build = function () {
    // geometry from the laid-out page (page coordinates)
    const tue = Desktop.planRect('.card[data-day="Tue"]'), btn = Desktop.planRect('#pn-shop'), kcal = Desktop.planRect('.card[data-day="Wed"] .meta .m1');
    const cx = tue.x + tue.w / 2, cy = tue.y + tue.h / 2;
    Cap.geo = {
      tue, btn, kcal,
      circle: { cx, cy, rx: tue.w / 2 + 18, ry: tue.h / 2 + 18, a0: -1.9 },
      arrow: { a: [cx - 70, cy + tue.h / 2 + 44], b: [btn.x + btn.w * 0.62, btn.y - 12] },
      label: [btn.x + 2, btn.y + btn.h + 10],
      strike: { a: [kcal.x - 5, kcal.y + kcal.h / 2 + 2], b: [kcal.x + kcal.w + 5, kcal.y + kcal.h / 2 - 1] },
    };
    Cap.toScreen = (p, scroll = 0) => [p[0] + ORIGIN[0], p[1] + ORIGIN[1] - scroll];
    // live marks
    const svg = Desktop.$.marks;
    const mk = (tag, attrs) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); svg.appendChild(e); return e; };
    E.circleGlow = mk('path', { fill: 'none', stroke: CYAN, 'stroke-width': 10, 'stroke-linecap': 'round', opacity: 0 });
    E.circle = mk('path', { fill: 'none', stroke: CYAN, 'stroke-width': 3, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
    E.arrowGlow = mk('path', { fill: 'none', stroke: CYAN, 'stroke-width': 10, 'stroke-linecap': 'round', opacity: 0 });
    E.arrow = mk('path', { fill: 'none', stroke: CYAN, 'stroke-width': 3, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
    E.strikeGlow = mk('path', { fill: 'none', stroke: AMBER, 'stroke-width': 10, 'stroke-linecap': 'round', opacity: 0 });
    E.strike = mk('path', { fill: 'none', stroke: AMBER, 'stroke-width': 3, 'stroke-linecap': 'round' });
    E.tethers = [0, 1, 2, 3].map(() => mk('line', { stroke: CYAN, 'stroke-width': 1, opacity: 0 }));
    E.brackets = [0, 1, 2, 3].map(() => { const g = mk('g', { opacity: 0 }); for (let i = 0; i < 4; i++) { const p = document.createElementNS(NS, 'path'); p.setAttribute('fill', 'none'); p.setAttribute('stroke', CYAN); p.setAttribute('stroke-width', 2); g.appendChild(p); } return g; });
    E.label = document.createElement('div'); E.label.className = 'mk-label'; css(E.label, { left: Cap.geo.label[0] + 'px', top: Cap.geo.label[1] + 'px' }); Desktop.$.mkHtml.appendChild(E.label);
    E.tags = ['meal-card', 'button', 'button', 'meal-card'].map(n => { const d = document.createElement('div'); d.className = 'mk-tag'; d.textContent = 'anchored · ' + n; Desktop.$.mkHtml.appendChild(d); return d; });
    // thumbnails + packet shots
    E.trail = document.getElementById('trail');
    E.trail.innerHTML = `<div class="tr-head"><span class="tr-rec"><i></i><span class="tr-time">REC 0:00</span></span></div><div class="tr-title">${esc(D.capture.title)}</div>` +
      D.annotations.map((a, i) => `<div class="tr-row"><div class="th"></div><div><div class="tt">${fmt(a.t)}</div><div class="tw">${esc(a.said)}</div></div></div>`).join('');
    E.trTime = E.trail.querySelector('.tr-time'); E.trRows = [...E.trail.querySelectorAll('.tr-row')];
    E.trRows.forEach((r, i) => r.querySelector('.th').appendChild(thumb(i + 1, 80 / G.CHROME.w)));
    const pk = document.getElementById('packet');
    pk.innerHTML = `<div class="pk-head"><span class="pk-title">${esc(D.capture.title)}</span><span class="pk-meta">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</span></div>
      <div class="pk-body"><div class="stack">${[3, 2, 1, 0].map(i => `<div class="shot" style="transform:translate3d(${i * 22}px, ${i * 30}px, ${-i * 40}px) rotateY(-12deg)"><span class="lbl">shot-${i + 1}.png</span></div>`).join('')}</div>
      <div class="pk-md">${D.payloadMarkdown.map(md).join('')}</div></div>
      <div class="pk-foot"><span class="a">Copy for any agent <span class="kc">⌘C</span></span><span class="b">Send to…</span></div>`;
    E.packet = pk;
    [...pk.querySelectorAll('.shot')].forEach(sh => { const n = +sh.querySelector('.lbl').textContent.match(/\d/)[0]; sh.insertBefore(thumb(n, 260 / G.CHROME.w), sh.firstChild); });
    E.rowPos = E.trRows.map(r => { const b = r.getBoundingClientRect(); return [b.left + 40, b.top + 25]; });
  };
  const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  function md(line) {
    const m = line.match(/^(.*?)\s*(shot-\d\.png)$/), body = m ? m[1] : line, file = m ? m[2] : '';
    const cls = body.startsWith('## ') ? 'h' : body.startsWith('[') ? 'q' : 'm';
    return `<div class="ln"><span class="${cls}">${esc(body) || ' '}</span>${file ? `<span class="f">${file}</span>` : ''}</div>`;
  }
  // a static miniature of the plan page with the first k marks at their final geometry
  function thumb(k, scale) {
    const inner = document.createElement('div'); inner.className = 'thumb-inner';
    const clone = Desktop.$.scrPlan.cloneNode(true);
    clone.removeAttribute('id'); clone.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
    clone.querySelector('.marks').remove(); clone.querySelector('.mk-html, [class=""]');
    const holder = clone.lastElementChild; if (holder && holder.className === '') holder.remove();
    clone.style.visibility = ''; clone.style.transform = 'none';
    inner.appendChild(clone);
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('class', 'marks'); svg.innerHTML = staticMarks(k); inner.appendChild(svg);
    if (k >= 3) { const l = document.createElement('div'); l.className = 'mk-label'; l.textContent = D.annotations[2].text; css(l, { left: Cap.geo.label[0] + 'px', top: Cap.geo.label[1] + 'px' }); inner.appendChild(l); }
    css(inner, { transform: `scale(${scale})` });
    return inner;
  }
  const P = (x, y) => `${x.toFixed(1)} ${y.toFixed(1)}`;
  function circlePath(prog, wobble) {
    const c = Cap.geo.circle, n = Math.ceil(64 * prog); if (n < 2) return '';
    let d = '';
    for (let i = 0; i <= n; i++) {
      const u = Math.min(prog, i / 64), th = c.a0 + u * Math.PI * 2.06;
      const w = 1 + wobble * 0.05 * (K.noise(u * 6, 2, 1) - 0.5) * 2;
      const x = c.cx + Math.cos(th) * c.rx * w, y = c.cy + Math.sin(th) * c.ry * w;
      d += (i ? 'L' : 'M') + P(x, y);
    }
    return d;
  }
  Cap.circlePoint = function (u, wobble = 1) { const c = Cap.geo.circle, th = c.a0 + u * Math.PI * 2.06, w = 1 + wobble * 0.05 * (K.noise(u * 6, 2, 1) - 0.5) * 2; return [c.cx + Math.cos(th) * c.rx * w, c.cy + Math.sin(th) * c.ry * w]; };
  function arrowPath(prog, snap) {
    const A = Cap.geo.arrow, b = [K.lerp(A.b[0] + 14, A.b[0], snap), K.lerp(A.b[1] - 10, A.b[1], snap)];
    const ex = A.a[0] + (b[0] - A.a[0]) * prog, ey = A.a[1] + (b[1] - A.a[1]) * prog;
    let d = `M${P(A.a[0], A.a[1])}L${P(ex, ey)}`;
    if (prog >= 0.98) { const ang = Math.atan2(b[1] - A.a[1], b[0] - A.a[0]); for (const s of [-1, 1]) { const a2 = ang + Math.PI + s * 0.5; d += `M${P(ex, ey)}L${P(ex + Math.cos(a2) * 18, ey + Math.sin(a2) * 18)}`; } }
    return d;
  }
  Cap.arrowPoint = u => { const A = Cap.geo.arrow; return [A.a[0] + (A.b[0] + 14 - A.a[0]) * u, A.a[1] + (A.b[1] - 10 - A.a[1]) * u]; };
  function strikePath(prog) { const S = Cap.geo.strike; return `M${P(S.a[0], S.a[1])}L${P(S.a[0] + (S.b[0] - S.a[0]) * prog, S.a[1] + (S.b[1] - S.a[1]) * prog)}`; }
  function staticMarks(k) {
    let s = '';
    if (k >= 1) s += `<path d="${circlePath(1, 0)}" fill="none" stroke="${CYAN}" stroke-width="3"/>`;
    if (k >= 2) s += `<path d="${arrowPath(1, 1)}" fill="none" stroke="${CYAN}" stroke-width="3" stroke-linecap="round"/>`;
    if (k >= 4) s += `<path d="${strikePath(1)}" fill="none" stroke="${AMBER}" stroke-width="3" stroke-linecap="round"/>`;
    return s;
  }
  function bracket(g, r, scale, alpha) {
    const cx = r.x + r.w / 2, cy = r.y + r.h / 2, L = 14, m = 6;
    const x0 = cx - (r.w / 2 + m) * scale, x1 = cx + (r.w / 2 + m) * scale, y0 = cy - (r.h / 2 + m) * scale, y1 = cy + (r.h / 2 + m) * scale;
    const ps = g.children;
    ps[0].setAttribute('d', `M${P(x0, y0 + L)}L${P(x0, y0)}L${P(x0 + L, y0)}`);
    ps[1].setAttribute('d', `M${P(x1 - L, y0)}L${P(x1, y0)}L${P(x1, y0 + L)}`);
    ps[2].setAttribute('d', `M${P(x1, y1 - L)}L${P(x1, y1)}L${P(x1 - L, y1)}`);
    ps[3].setAttribute('d', `M${P(x0 + L, y1)}L${P(x0, y1)}L${P(x0, y1 - L)}`);
    g.setAttribute('opacity', alpha.toFixed(3));
  }
  function anchorCue(i, at, rect, tagPos) {
    const p = K.p(t_, at, at + 0.25, 'out'), fade = 1 - K.p(t_, at + 1.1, at + 1.5);
    const a = p * fade;
    bracket(E.brackets[i], rect, 1.1 - 0.1 * p, a);
    const tag = E.tags[i];
    css(tag, { left: tagPos[0] + 'px', top: tagPos[1] + 'px', opacity: a.toFixed(3), visibility: a > 0.01 ? 'visible' : 'hidden' });
    // tether stays while the capture runs
    const te = E.tethers[i]; te.setAttribute('opacity', (0.55 * K.p(t_, at + 0.3, at + 0.8) * (t_ < s7.stop ? 1 : 1 - K.p(t_, s7.stop, s7.stop + 0.5))).toFixed(3));
  }
  let t_ = 0;
  // ---- marks (called every frame; marks persist until the capture ends) ----
  Cap.renderMarks = function (t) {
    t_ = t;
    const g = Cap.geo, live = t >= c0;
    const endFade = 1 - K.p(t, s7.stop + 0.2, s7.stop + 0.7);
    // circle
    const cp = K.p(t, s6.circle[0], s6.circle[1], 'linear'), snap1 = K.p(t, s6.snap1, s6.snap1 + 0.25, 'out');
    E.circle.setAttribute('d', live && cp > 0 ? circlePath(cp, 1 - snap1) : '');
    E.circle.setAttribute('opacity', (endFade).toFixed(3));
    E.circleGlow.setAttribute('d', E.circle.getAttribute('d'));
    E.circleGlow.setAttribute('opacity', (0.35 * K.win(t, s6.circle[0], s6.snap1 + 0.6, 0.1, 0.5)).toFixed(3));
    if (cp > 0) { anchorCue(0, s6.snap1, g.tue, [g.tue.x, g.tue.y - 50]); const p1 = Cap.circlePoint(0.02, 0); E.tethers[0].setAttribute('x1', p1[0]); E.tethers[0].setAttribute('y1', p1[1]); E.tethers[0].setAttribute('x2', g.tue.x + 4); E.tethers[0].setAttribute('y2', g.tue.y + 4); }
    else { E.brackets[0].setAttribute('opacity', 0); css(E.tags[0], { visibility: 'hidden' }); E.tethers[0].setAttribute('opacity', 0); }
    // arrow
    const ap = K.p(t, s6.arrow[0], s6.arrow[1], 'inOut'), snap2 = K.p(t, s6.snap2, s6.snap2 + 0.25, 'out');
    E.arrow.setAttribute('d', live && ap > 0 ? arrowPath(ap, snap2) : ''); E.arrow.setAttribute('opacity', endFade.toFixed(3));
    E.arrowGlow.setAttribute('d', E.arrow.getAttribute('d')); E.arrowGlow.setAttribute('opacity', (0.35 * K.win(t, s6.arrow[0], s6.snap2 + 0.6, 0.1, 0.5)).toFixed(3));
    if (ap > 0) { anchorCue(1, s6.snap2, g.btn, [g.btn.x + g.btn.w + 14, g.btn.y - 32]); E.tethers[1].setAttribute('x1', g.arrow.b[0]); E.tethers[1].setAttribute('y1', g.arrow.b[1]); E.tethers[1].setAttribute('x2', g.btn.x + g.btn.w - 6); E.tethers[1].setAttribute('y2', g.btn.y + 2); }
    else { E.brackets[1].setAttribute('opacity', 0); css(E.tags[1], { visibility: 'hidden' }); E.tethers[1].setAttribute('opacity', 0); }
    // label (voice only): types itself in
    const lp = K.p(t, s6.label[0], s6.label[1], 'linear'), full = D.annotations[2].text;
    const n = Math.round(full.length * lp);
    text(E.label, live ? full.slice(0, n) : '');
    css(E.label, { opacity: endFade.toFixed(3), textShadow: lp > 0 && lp < 1 ? `0 0 2px rgba(7,9,13,.9), 0 0 6px rgba(7,9,13,.9), 0 0 14px rgba(7,9,13,.75), 0 0 10px rgba(92,225,230,.8)` : '' });
    if (lp > 0) { anchorCue(2, s6.snap3, g.btn, [g.btn.x + g.btn.w + 14, g.btn.y - 32]); E.tethers[2].setAttribute('x1', g.label[0] - 6); E.tethers[2].setAttribute('y1', g.label[1] + 14); E.tethers[2].setAttribute('x2', g.btn.x + 2); E.tethers[2].setAttribute('y2', g.btn.y + g.btn.h - 2); }
    else { E.brackets[2].setAttribute('opacity', 0); css(E.tags[2], { visibility: 'hidden' }); E.tethers[2].setAttribute('opacity', 0); }
    // strike (voice only): draws itself
    const sp = K.p(t, s6.strike[0], s6.strike[1], 'inOut');
    E.strike.setAttribute('d', live && sp > 0 ? strikePath(sp) : ''); E.strike.setAttribute('opacity', endFade.toFixed(3));
    E.strikeGlow.setAttribute('d', E.strike.getAttribute('d')); E.strikeGlow.setAttribute('opacity', (0.35 * K.win(t, s6.strike[0], s6.snap4 + 0.6, 0.1, 0.5)).toFixed(3));
    if (sp > 0) { const kr = { x: g.kcal.x - 2, y: g.kcal.y - 2, w: g.kcal.w + 4, h: g.kcal.h + 4 }; anchorCue(3, s6.snap4, kr, [g.kcal.x + g.kcal.w + 22, g.kcal.y - 4]); E.tethers[3].setAttribute('x1', g.strike.b[0]); E.tethers[3].setAttribute('y1', g.strike.b[1]); E.tethers[3].setAttribute('x2', g.kcal.x + g.kcal.w + 2); E.tethers[3].setAttribute('y2', g.kcal.y + g.kcal.h + 2); }
    else { E.brackets[3].setAttribute('opacity', 0); css(E.tags[3], { visibility: 'hidden' }); E.tethers[3].setAttribute('opacity', 0); }
  };
  // ---- trail ----
  Cap.renderTrail = function (t, triad) {
    const open = K.p(t, c0 + 0.1, c0 + 0.6, 'out'), gather = K.p(t, s7.gather, s7.gather + 0.6, 'in');
    if (open <= 0 || gather >= 1) { css(E.trail, { visibility: 'hidden' }); E.trRows.forEach(r => css(r, { display: 'none' })); return; }
    css(E.trail, { visibility: 'visible' });
    const rec = t < s7.stop;
    text(E.trTime, rec ? `REC ${fmt(Math.max(0, t - c0))}` : `${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots`);
    css(E.trail.querySelector('.tr-rec i'), { opacity: rec ? (0.55 + 0.45 * Math.sin(t * 4)).toFixed(2) : '1' });
    [s6.row1, s6.row2, s6.row3, s6.row4].forEach((at, i) => { const p = K.p(t, at, at + 0.35, 'out'); css(E.trRows[i], { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * 10).toFixed(1)}px)`, display: p > 0 ? 'grid' : 'none' }); });
    // unfold from the triad; gather into the packet centre
    const ox = triad[0] - 1606, oy = triad[1] - 150;
    const sc = (0.15 + 0.85 * open) * (1 - 0.9 * gather), a = open * (1 - gather);
    const tx = gather * (960 - 1750), ty = gather * (488 - 320);
    css(E.trail, { transformOrigin: gather > 0 ? '50% 50%' : `${ox}px ${oy}px`, transform: `translate(${tx.toFixed(1)}px, ${ty.toFixed(1)}px) scale(${sc.toFixed(4)})`, opacity: a.toFixed(3) });
  };
  Cap.rowPos = i => E.rowPos[i];
  // ---- packet ----
  Cap.renderPacket = function (t, triad) {
    const open = K.p(t, s7.gather + 0.35, s7.gather + 0.95, 'out'), comp = K.p(t, s7.copy, s7.copy + 0.55, 'in');
    if (open <= 0 || comp >= 1) { css(E.packet, { visibility: 'hidden' }); return; }
    css(E.packet, { visibility: 'visible' });
    const ox = triad[0] - 420, oy = triad[1] - 300;
    const sc = (0.15 + 0.85 * open) * (1 - 0.97 * comp), a = open * (1 - comp * 0.9);
    css(E.packet, { transformOrigin: comp > 0 ? '50% 50%' : `${ox.toFixed(1)}px ${oy.toFixed(1)}px`, transform: `scale(${sc.toFixed(4)})`, opacity: a.toFixed(3) });
  };
  // beads to draw on the fx canvas: [{x,y,a}]
  Cap.beads = function (t, triad, scroll) {
    const out = [];
    const src = [Cap.toScreen(Cap.circlePoint(0.5, 0), scroll), Cap.toScreen(Cap.geo.arrow.b, scroll), Cap.toScreen([Cap.geo.label[0] + 120, Cap.geo.label[1] + 14], scroll), Cap.toScreen(Cap.geo.strike.b, scroll)];
    [s6.bead1, s6.bead2, s6.bead3, s6.bead4].forEach((at, i) => {
      if (t < at || t > at + 1.0) return;
      if (t < at + 0.45) { const u = K.p(t, at, at + 0.45, 'inOut'); const [x, y] = Orbit.curve(src[i], triad, u, 0.2, 1); out.push({ x, y, a: 1, r: 4 }); }
      else { const u = K.p(t, at + 0.45, at + 0.95, 'inOut'); const [x, y] = Orbit.curve(triad, E.rowPos[i], u, 0.2, -1); out.push({ x, y, a: 1 - u * 0.4, r: 4 }); }
    });
    return out;
  };
  window.Cap = Cap;
})();
