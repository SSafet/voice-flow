// capture.js — scene 6/7: anchored marks inside the Pantrella page (orange ink, dashed anchoring
// cue + tag), the thumbnail "screenshots" (miniature clones of the page with the marks so far),
// pips for the island's right shoulder and the payload strip. Adapted from concept-b-orbit/capture.js.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text;
  const INK = '#FF9F0A', RED = '#FF453A';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const s6 = T.s6, s7 = T.s7, c0 = s6.c0;
  const Cap = {};
  const NS = 'http://www.w3.org/2000/svg';
  const ORIGIN = [G.CHROME.x, G.CHROME.y + G.CHROME_HEAD];   // page (0,0) on screen at scroll 0
  const E = {};

  Cap.build = function () {
    const tue = Desktop.planRect('.card[data-day="Tue"]'), btn = Desktop.planRect('#pn-shop'), kcal = Desktop.planRect('.card[data-day="Wed"] .meta .m1');
    const cx = tue.x + tue.w / 2, cy = tue.y + tue.h / 2;
    Cap.geo = {
      tue, btn, kcal,
      circle: { cx, cy, rx: tue.w / 2 + 16, ry: tue.h / 2 + 16, a0: -1.9 },
      arrow: { a: [cx - 60, cy + tue.h / 2 + 46], b: [btn.x + btn.w * 0.62, btn.y - 10] },
      label: [btn.x + 2, btn.y + btn.h + 8],
      strike: { a: [kcal.x - 4, kcal.y + kcal.h / 2 + 2], b: [kcal.x + kcal.w + 4, kcal.y + kcal.h / 2 - 1] },
    };
    Cap.toScreen = (p, scroll = 0) => [p[0] + ORIGIN[0], p[1] + ORIGIN[1] - scroll];
    const svg = Desktop.$.marks;
    const mk = (tag, attrs) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); svg.appendChild(e); return e; };
    E.circle = mk('path', { fill: 'none', stroke: INK, 'stroke-width': 2.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
    E.arrow = mk('path', { fill: 'none', stroke: INK, 'stroke-width': 2.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
    E.strike = mk('path', { fill: 'none', stroke: RED, 'stroke-width': 2.5, 'stroke-linecap': 'round' });
    E.anchors = [0, 1, 2, 3].map(() => mk('rect', { fill: 'none', stroke: INK, 'stroke-width': 1, 'stroke-dasharray': '4 3', rx: 6, opacity: 0 }));
    E.label = document.createElement('div'); E.label.className = 'mk-label'; css(E.label, { left: Cap.geo.label[0] + 'px', top: Cap.geo.label[1] + 'px' }); Desktop.$.mkHtml.appendChild(E.label);
    E.tags = ['meal-card', 'button', 'button', 'meal-card'].map(n => { const d = document.createElement('div'); d.className = 'mk-tag'; d.textContent = 'anchored · ' + n; Desktop.$.mkHtml.appendChild(d); return d; });
    // thumbnails: the island's drop (120×68), the pips (24×15) and the payload strip (150×84)
    Cap.drops = [1, 2, 3, 4].map(k => { const box = document.createElement('div'); box.className = 'th-drop'; box.appendChild(thumb(k, 120 / G.CHROME.w)); const tt = document.createElement('span'); tt.className = 'tt'; tt.textContent = fmt(D.annotations[k - 1].t); box.appendChild(tt); Island.tdropAdd(box); return box; });
    [1, 2, 3, 4].forEach(k => { const p = document.createElement('div'); p.className = 'pip'; p.appendChild(thumb(k, 24 / G.CHROME.w)); Island.pipsEl().appendChild(p); });
    Sheet.payThumbs([1, 2, 3, 4].map(k => thumb(k, 140 / G.CHROME.w)));
  };
  const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  // a static miniature of the plan page (the Chrome content area) with the first k marks
  function thumb(k, scale) {
    const inner = document.createElement('div'); inner.className = 'thumb-inner';
    const clone = Desktop.$.scrPlan.cloneNode(true);
    clone.removeAttribute('id'); clone.querySelectorAll('[id]').forEach(e => e.removeAttribute('id'));
    clone.querySelector('.marks').remove(); const holder = clone.lastElementChild; if (holder && holder.className === '') holder.remove();
    clone.style.visibility = ''; clone.style.transform = 'none';
    inner.appendChild(clone);
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('class', 'marks'); svg.innerHTML = staticMarks(k, Math.max(2.5, 2.2 / scale)); inner.appendChild(svg);
    if (k >= 3) { const l = document.createElement('div'); l.className = 'mk-label big'; l.textContent = D.annotations[2].text; css(l, { left: Cap.geo.label[0] + 'px', top: (Cap.geo.label[1] - 4) + 'px', fontSize: Math.max(15, 13 / scale) + 'px' }); inner.appendChild(l); }
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
      d += (i ? 'L' : 'M') + P(c.cx + Math.cos(th) * c.rx * w, c.cy + Math.sin(th) * c.ry * w);
    }
    return d;
  }
  Cap.circlePoint = function (u, wobble = 1) { const c = Cap.geo.circle, th = c.a0 + u * Math.PI * 2.06, w = 1 + wobble * 0.05 * (K.noise(u * 6, 2, 1) - 0.5) * 2; return [c.cx + Math.cos(th) * c.rx * w, c.cy + Math.sin(th) * c.ry * w]; };
  function arrowPath(prog, snap) {
    const A = Cap.geo.arrow, b = [K.lerp(A.b[0] + 14, A.b[0], snap), K.lerp(A.b[1] - 10, A.b[1], snap)];
    const ex = A.a[0] + (b[0] - A.a[0]) * prog, ey = A.a[1] + (b[1] - A.a[1]) * prog;
    let d = `M${P(A.a[0], A.a[1])}L${P(ex, ey)}`;
    if (prog >= 0.98) { const ang = Math.atan2(b[1] - A.a[1], b[0] - A.a[0]); for (const s of [-1, 1]) { const a2 = ang + Math.PI + s * 0.48; d += `M${P(ex, ey)}L${P(ex + Math.cos(a2) * 16, ey + Math.sin(a2) * 16)}`; } }
    return d;
  }
  Cap.arrowPoint = u => { const A = Cap.geo.arrow; return [A.a[0] + (A.b[0] + 14 - A.a[0]) * u, A.a[1] + (A.b[1] - 10 - A.a[1]) * u]; };
  function strikePath(prog) { const S = Cap.geo.strike; return `M${P(S.a[0], S.a[1])}L${P(S.a[0] + (S.b[0] - S.a[0]) * prog, S.a[1] + (S.b[1] - S.a[1]) * prog)}`; }
  function staticMarks(k, sw) {
    let s = '';
    if (k >= 1) s += `<path d="${circlePath(1, 0)}" fill="none" stroke="${INK}" stroke-width="${sw}"/>`;
    if (k >= 2) s += `<path d="${arrowPath(1, 1)}" fill="none" stroke="${INK}" stroke-width="${sw}" stroke-linecap="round"/>`;
    if (k >= 4) s += `<path d="${strikePath(1)}" fill="none" stroke="${RED}" stroke-width="${sw}" stroke-linecap="round"/>`;
    return s;
  }
  // anchoring cue: a dashed outline hugs the element for ~0.6 s, with a tag on a dark plate
  function anchorCue(i, at, rect, tagPos) {
    const p = K.p(t_, at, at + 0.2, 'out'), fade = 1 - K.p(t_, at + 0.7, at + 1.0);
    const a = p * fade, m = 4 + 6 * (1 - p);
    const r = E.anchors[i];
    r.setAttribute('x', (rect.x - m).toFixed(1)); r.setAttribute('y', (rect.y - m).toFixed(1)); r.setAttribute('width', (rect.w + 2 * m).toFixed(1)); r.setAttribute('height', (rect.h + 2 * m).toFixed(1)); r.setAttribute('opacity', a.toFixed(3));
    const tagA = p * (1 - K.p(t_, at + 1.1, at + 1.5));
    css(E.tags[i], { left: tagPos[0] + 'px', top: tagPos[1] + 'px', opacity: tagA.toFixed(3), visibility: tagA > 0.01 ? 'visible' : 'hidden' });
  }
  let t_ = 0;
  Cap.renderMarks = function (t) {
    t_ = t;
    const g = Cap.geo, live = t >= c0;
    const endFade = 1 - K.p(t, s7.stop + 0.3, s7.stop + 0.8);
    const cp = K.p(t, s6.circle[0], s6.circle[1], 'linear'), snap1 = K.p(t, s6.snap1, s6.snap1 + 0.3, 'out');
    E.circle.setAttribute('d', live && cp > 0 ? circlePath(cp, 1 - snap1) : ''); E.circle.setAttribute('opacity', endFade.toFixed(3));
    if (cp > 0) anchorCue(0, s6.snap1, g.tue, [g.tue.x, g.tue.y - 46]); else { E.anchors[0].setAttribute('opacity', 0); css(E.tags[0], { visibility: 'hidden' }); }
    const ap = K.p(t, s6.arrow[0], s6.arrow[1], 'inOut'), snap2 = K.p(t, s6.snap2, s6.snap2 + 0.25, 'out');
    E.arrow.setAttribute('d', live && ap > 0 ? arrowPath(ap, snap2) : ''); E.arrow.setAttribute('opacity', endFade.toFixed(3));
    if (ap > 0) anchorCue(1, s6.snap2, g.btn, [g.btn.x + g.btn.w + 16, g.btn.y + 12]); else { E.anchors[1].setAttribute('opacity', 0); css(E.tags[1], { visibility: 'hidden' }); }
    const lp = K.p(t, s6.label[0], s6.label[1], 'linear'), full = D.annotations[2].text;
    text(E.label, live ? full.slice(0, Math.round(full.length * lp)) : '');
    css(E.label, { opacity: endFade.toFixed(3) });
    if (lp > 0) anchorCue(2, s6.snap3, g.btn, [g.btn.x + g.btn.w + 16, g.btn.y + 12]); else { E.anchors[2].setAttribute('opacity', 0); css(E.tags[2], { visibility: 'hidden' }); }
    const sp = K.p(t, s6.strike[0], s6.strike[1], 'inOut');
    E.strike.setAttribute('d', live && sp > 0 ? strikePath(sp) : ''); E.strike.setAttribute('opacity', endFade.toFixed(3));
    if (sp > 0) anchorCue(3, s6.snap4, { x: g.kcal.x - 2, y: g.kcal.y - 2, w: g.kcal.w + 4, h: g.kcal.h + 4 }, [g.kcal.x + g.kcal.w + 20, g.kcal.y - 4]); else { E.anchors[3].setAttribute('opacity', 0); css(E.tags[3], { visibility: 'hidden' }); }
  };
  window.Cap = Cap;
})();
