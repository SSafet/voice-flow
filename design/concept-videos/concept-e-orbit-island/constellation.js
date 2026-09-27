// Control center ("constellation") and FLORA's orbit (automations + data streams). Scenes 4–5.
(function () {
  const D = window.VF, K = window.K, T = window.T, css = K.css, text = K.text, html = K.html;
  const TEXT = '#EAF2FF', SEC = '#AFBCCE', INACT = '#8E9BAE', CYAN = '#5CE1E6', VIOLET = '#9B8CFF', AMBER = '#FFB547', RED = '#FF6B6B', GREEN = '#7EE0A1';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const s4 = T.s4, s5 = T.s5;
  const CC = {};
  const REG = {
    R_TOP: { title: [560, 118], cols: [590, 890, 1190], row0: 200 },
    R_BOT: { title: [560, 632], cols: [590, 890, 1190], row0: 714 },
    R_MID: { title: [560, 436], cols: [590, 890], row0: 518 },
    L_TOP: { title: [60, 118], cols: [64], row0: 200 },
  };
  CC.TRIAD = [200, 515];          // triad in the constellation
  CC.RING = [96, 980];            // resolved ring
  CC.CENTER = [700, 520];         // FLORA profile centre
  const RING_R = 210, SAT_R = 340;

  const jit = (i, k) => (K.hash(i * 7 + k) - 0.5) * 8;
  const ARC = { 3: [8, -10, 8], 2: [4, -4], 1: [0] };
  // slot (col,row) → point
  const pt = (reg, c, r, i, gap) => [reg.cols[c] + jit(i, 3), reg.row0 + r * gap + ARC[reg.cols.length][c] + jit(i, 11) * 0.75];
  // Priorities take column 0 first (rows 0,1,…) so the light-lines from the left never cross a label;
  // the rest fill row-major. Relaxed = same columns, rows compacted (nodes only move vertically).
  function layout(mode, relaxed) {
    const groups = mode === 'project' ? D.projects : D.components, key = mode;
    const regions = mode === 'project' ? ['R_TOP', 'R_BOT', 'L_TOP', 'R_MID'] : ['R_TOP', 'R_BOT', 'L_TOP'];
    const res = { nodes: {}, titles: [] };
    groups.forEach((g, gi) => {
      const reg = REG[regions[gi]], nc = reg.cols.length;
      const all = D.sessions.filter(s => s[key] === g).sort((a, b) => (a.priority || 99) - (b.priority || 99));
      const pri = all.filter(s => s.priority), rest = all.filter(s => !s.priority);
      const order = []; pri.forEach((s, r) => order.push([s, 0, r]));
      let k = 0; const used = new Set(pri.map((_, r) => '0,' + r));
      rest.forEach(s => { let c, r; do { c = k % nc; r = Math.floor(k / nc); k++; } while (used.has(c + ',' + r)); order.push([s, c, r]); });
      if (!relaxed) { order.forEach(([s, c, r], i) => res.nodes[s.id] = pt(reg, c, r, i, 68)); res.titles.push({ name: g, count: all.length, x: reg.title[0], y: reg.title[1] }); return; }
      const perCol = Array.from({ length: nc }, () => []);
      order.forEach(([s, c, r]) => { if (s.status !== 'done') perCol[c].push(s); });
      perCol.forEach((list, c) => list.forEach((s, r) => res.nodes[s.id] = pt(reg, c, r, idx(s.id), 84)));
      res.titles.push({ name: g, count: all.filter(s => s.status !== 'done').length, x: reg.title[0], y: reg.title[1] });
    });
    return res;
  }
  const ORDER = D.sessions.map(s => s.id);
  const idx = id => ORDER.indexOf(id);
  const LAY = { project: layout('project', false), component: layout('component', false), relaxed: layout('component', true) };
  const isDone = id => D.sessions.find(s => s.id === id).status === 'done';

  // flight progress helpers
  const regroupP = (id, t) => K.p(t, s4.regroupAnim + idx(id) * 0.035, s4.regroupAnim + idx(id) * 0.035 + 1.0, 'inOut');
  const resolveP = (id, t) => K.p(t, s4.resolveAnim + (idx(id) % 10) * 0.09, s4.resolveAnim + (idx(id) % 10) * 0.09 + 0.85, 'in');
  const relaxP = t => K.p(t, s4.resolveAnim + 0.8, s4.resolveAnim + 1.7, 'inOut');
  CC.nodePos = function (id, t) {
    const A = LAY.project.nodes[id], B = LAY.component.nodes[id];
    const q = regroupP(id, t);
    let pos = q >= 1 ? B : q <= 0 ? A : Orbit.curve(A, B, q, 0.18, idx(id) % 2 ? 1 : -1);
    if (isDone(id)) { const r = resolveP(id, t); if (r > 0) pos = Orbit.curve(pos, CC.RING, r, 0.15, idx(id) % 2 ? 1 : -1); return { pos, gone: r }; }
    const C = LAY.relaxed.nodes[id], rp = relaxP(t);
    if (rp > 0) pos = [K.lerp(pos[0], C[0], rp), K.lerp(pos[1], C[1], rp)];
    return { pos, gone: 0 };
  };
  CC.resolvedCount = t => D.sessions.filter(s => s.status === 'done' && resolveP(s.id, t) >= 1).length;

  // ---- build DOM ----
  const E = {};
  CC.build = function () {
    E.cc = document.getElementById('cc'); E.dim = document.getElementById('cc-dim');
    E.nodes = document.getElementById('cc-nodes'); E.titles = document.getElementById('cc-titles'); E.orbit = document.getElementById('cc-orbit');
    E.resolved = document.getElementById('cc-resolved'); E.rail = document.getElementById('cc-rail');
    E.back = document.getElementById('fxBack'); E.bctx = E.back.getContext('2d');
    E.node = {};
    for (const s of D.sessions) {
      const el = document.createElement('div'); el.className = 'cnode' + (s.status === 'done' ? ' dim' : '');
      el.innerHTML = `<div class="ct">${esc(s.title)}</div><div class="cm">${s.runtime} · ${s.age}</div>`;
      E.nodes.appendChild(el); E.node[s.id] = el;
    }
    E.title = {};
    for (const mode of ['project', 'component']) LAY[mode].titles.forEach(tt => {
      const el = document.createElement('div'); el.className = 'ctitle'; el.innerHTML = `${tt.name}<span class="n">${tt.count}</span>`;
      css(el, { left: tt.x + 'px', top: tt.y + 'px' }); E.titles.appendChild(el); E.title[mode + ':' + tt.name] = el;
    });
    E.resolved.innerHTML = `<span style="width:30px;height:30px;display:inline-block"></span>Resolved<b></b>`;
    css(E.resolved, { left: (CC.RING[0] - 15) + 'px', top: (CC.RING[1] - 15) + 'px' });
    E.resCount = E.resolved.querySelector('b');
    // rail
    const pri = D.sessions.filter(s => s.priority).sort((a, b) => a.priority - b.priority);
    E.rail.innerHTML = `<div class="r-head"><span class="wb on">Workbench 20</span><span class="sep">·</span><span class="rs">Resolved</span><span class="sep">·</span><span class="all">All</span></div>
      <div class="r-group">grouped by project</div>
      <div class="r-body">
        <div class="r-view v-pri"><div class="r-lbl">FLORA’s priorities</div>${pri.map(s => `<div class="prow"><div class="num">${s.priority}</div><div><div class="pt">${esc(s.title)}</div><div class="pl">${esc(s.line)}</div><div class="pm">${s.project} · ${s.runtime} · ${s.age}</div></div></div>`).join('')}</div>
        <div class="r-view v-res"><div class="r-lbl c">Resolved today</div>${D.sessions.filter(s => s.status === 'done').map(s => `<div class="lrow"><div class="pt">${esc(s.title)}</div><div class="pl">${esc(s.line)} · ${s.runtime}</div></div>`).join('')}</div>
        <div class="r-view v-ask ask"><div class="meta">Pantrella · Codex · 4 min</div><div class="st">Checkout: cart items table · <span class="state"></span></div><h3>${esc(D.checkoutAsk.title)}</h3><p>${esc(D.checkoutAsk.body)}</p><div class="acts"><span class="a">Approve</span><span class="b">Not now</span></div><div class="done">${esc(D.checkoutAsk.approvedLine)}</div></div>
        <div class="r-view v-draft"><div class="r-lbl">New automation</div>
          ${['name', 'schedule', 'deliver', 'access'].map(k => `<div class="fld f-${k}"><div class="k">${k}</div><div class="v"><span class="ph">—</span><span class="val"></span></div></div>`).join('')}
          <div class="fld f-streams"><div class="k">Data streams</div><div class="v streams"></div></div>
          <div class="status"></div></div>
        <div class="r-view v-auto"><div class="r-lbl">Automations</div>${D.automation.existing.map(a => `<div class="arow"><div><div class="pt">${esc(a.name)}</div><div class="pl">${esc(a.schedule)}</div></div><span class="sw on"></span></div>`).join('')}
          <div class="arow new"><div><div class="pt">${esc(D.automation.draft.name)}</div><div class="pl">${esc(D.automation.draft.schedule)} · next run ${D.automation.draft.nextRun}</div></div><span class="sw on"></span></div></div>
      </div>`;
    E.rHead = { wb: E.rail.querySelector('.wb'), rs: E.rail.querySelector('.rs'), all: E.rail.querySelector('.all') };
    E.rGroup = E.rail.querySelector('.r-group');
    E.views = { pri: E.rail.querySelector('.v-pri'), res: E.rail.querySelector('.v-res'), ask: E.rail.querySelector('.v-ask'), draft: E.rail.querySelector('.v-draft'), auto: E.rail.querySelector('.v-auto') };
    E.askState = E.rail.querySelector('.v-ask .state'); E.askDone = E.rail.querySelector('.v-ask .done'); E.askActs = E.rail.querySelector('.v-ask .acts');
    E.fld = {}; ['name', 'schedule', 'deliver', 'access'].forEach(k => E.fld[k] = { v: E.rail.querySelector(`.f-${k} .val`), ph: E.rail.querySelector(`.f-${k} .ph`) });
    E.streams = E.rail.querySelector('.streams'); E.status = E.rail.querySelector('.v-draft .status');
    // FLORA profile: satellites + ticks
    E.sat = [];
    const sats = SATS();
    sats.forEach(s => {
      const el = document.createElement('div'); el.className = 'sat' + (s.left ? ' l' : '') + (s.on ? '' : ' off');
      el.innerHTML = `<div class="sn">${s.left ? '' : '<span class="sw' + (s.on ? ' on' : '') + '"></span>'}<span class="nm">${esc(s.name)}</span>${s.left ? '<span class="sw' + (s.on ? ' on' : '') + '"></span>' : ''}</div><div class="sd">${esc(s.detail)}</div><div class="sf">${esc(s.fresh)}</div>`;
      css(el, { left: (s.left ? s.x - 16 - 240 : s.x + 16) + 'px', top: (s.y - 30) + 'px' });
      E.orbit.appendChild(el); E.sat.push({ el, sw: el.querySelector('.sw'), sf: el.querySelector('.sf'), ...s });
    });
    E.ticks = [];
    const tick = (cls, txt, ang, dist, left) => {
      const el = document.createElement('div'); el.className = 'tick ' + cls; el.textContent = txt;
      const [x, y] = polar(CC.CENTER, ang, dist);
      css(el, { left: (left ? x - 300 : x) + 'px', top: (y - 8) + 'px', width: left ? '300px' : 'auto', textAlign: left ? 'right' : 'left' });
      E.orbit.appendChild(el); E.ticks.push(el); return el;
    };
    tick('h', '00', 0, RING_R + 22); tick('h', '06', 90, RING_R + 26); tick('h', '12', 180, RING_R + 22); tick('h', '18', 270, RING_R + 26, true);
    E.tNight = tick('', '21:37 · Nightly screen review', 324.25, RING_R + 30, true);
    E.tPush = tick('', 'on push · Release QA', 165, RING_R + 30);
    E.tNew = tick('new', '08:30 · weekdays', 127.5, RING_R + 30);
    E.flora = document.createElement('div'); E.flora.id = 'cc-flora'; E.flora.textContent = 'FLORA';
    css(E.flora, { left: (CC.CENTER[0] - 30) + 'px', top: (CC.CENTER[1] + 26) + 'px', width: '60px', textAlign: 'center' });
    E.orbit.appendChild(E.flora);
    // measurements for pointer targets (rail header words)
    css(E.cc, { display: 'block' }); css(E.rail, { display: 'block' });
    const rr = k => { const r = E.rHead[k].getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
    CC.target = { resolved: rr('rs'), workbench: rr('wb') };
    css(E.cc, { display: 'none' });
  };
  function polar(c, deg, r) { const a = (deg - 90) * Math.PI / 180; return [c[0] + Math.cos(a) * r, c[1] + Math.sin(a) * r]; }
  function SATS() {
    const A = D.automation, C = CC.CENTER;
    const spec = [
      { ...A.otherStreams[2], detail: 'open tickets', ang: 25, on: true },
      { ...A.streams[0], ang: 65, on: true }, { ...A.streams[1], ang: 105, on: true }, { ...A.streams[2], ang: 150, on: true },
      { ...A.otherStreams[1], detail: 'today’s activity', ang: 210, on: true, left: true }, { ...A.otherStreams[0], detail: 'commits & PRs', ang: 250, on: true, left: true },
      { ...A.streams[3], ang: 340, on: false, left: true },
    ];
    return spec.map(s => { const [x, y] = polar(C, s.ang, SAT_R); return { ...s, x, y }; });
  }

  // ---- drawing helpers (fxBack) ----
  function dotState(ctx, x, y, status, t, id, sc, alpha, morph) {
    // morph: 0 = status as given, 1 = running (for the approval)
    const draw = (st, a) => {
      if (a <= 0.01) return;
      ctx.globalAlpha = alpha * a;
      ctx.lineWidth = 1.5;
      if (st === 'needs') {
        const ph = ((t * 0.5 + id * 0.13) % 1);
        ctx.strokeStyle = AMBER; ctx.globalAlpha = alpha * a * (1 - ph) * 0.7; ctx.beginPath(); ctx.arc(x, y, (6 + 14 * ph) * sc, 0, Math.PI * 2); ctx.stroke();
        ctx.globalAlpha = alpha * a; ctx.fillStyle = AMBER; ctx.beginPath(); ctx.arc(x, y, 5 * sc, 0, Math.PI * 2); ctx.fill();
      } else if (st === 'failed') { ctx.fillStyle = RED; ctx.beginPath(); ctx.arc(x, y, 5 * sc, 0, Math.PI * 2); ctx.fill(); }
      else if (st === 'review') { ctx.strokeStyle = AMBER; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(x, y, 5 * sc, 0, Math.PI * 2); ctx.stroke(); }
      else if (st === 'running') {
        ctx.fillStyle = CYAN; ctx.beginPath(); ctx.arc(x, y, 4.5 * sc, 0, Math.PI * 2); ctx.fill();
        const ang = t * 4.2 + id; ctx.fillStyle = '#EAF2FF'; ctx.beginPath(); ctx.arc(x + Math.cos(ang) * 10 * sc, y + Math.sin(ang) * 10 * sc, 1.8 * sc, 0, Math.PI * 2); ctx.fill();
      } else if (st === 'idle') { ctx.strokeStyle = TEXT; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.arc(x, y, 4.5 * sc, 0, Math.PI * 2); ctx.stroke(); }
      else { ctx.strokeStyle = INACT; ctx.lineWidth = 1.2; ctx.beginPath(); ctx.arc(x, y, 3.5 * sc, 0, Math.PI * 2); ctx.stroke(); }
    };
    draw(status, 1 - morph); if (morph > 0) draw('running', morph);
    ctx.globalAlpha = 1;
  }
  // quadratic light-line; left-cluster targets are routed around the node column so no label is crossed
  function lightLine(ctx, a, b, prog, alpha, num) {
    if (prog <= 0) return;
    const c = b[0] < 400 ? [b[0] - 140, a[1] + 20] : [(a[0] + b[0]) / 2 + (b[1] - a[1]) * 0.12, (a[1] + b[1]) / 2 - (b[0] - a[0]) * 0.12];
    const Q = e => { const u = 1 - e; return [u * u * a[0] + 2 * u * e * c[0] + e * e * b[0], u * u * a[1] + 2 * u * e * c[1] + e * e * b[1]]; };
    const n = 40; ctx.strokeStyle = VIOLET; ctx.lineWidth = 1.2; ctx.globalAlpha = alpha * 0.75; ctx.shadowColor = VIOLET; ctx.shadowBlur = 6;
    ctx.beginPath();
    for (let i = 0; i <= n * prog; i++) { const [x, y] = Q(i / n); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
    ctx.stroke(); ctx.shadowBlur = 0;
    if (prog >= 1) { const [x, y] = Q(0.9); ctx.fillStyle = VIOLET; ctx.font = '600 13px Menlo, monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.globalAlpha = alpha; ctx.fillText(num, x - 8, y - 6); }
    ctx.globalAlpha = 1;
  }

  // ---- state ----
  function railView(t) {
    if (t >= s5.list + 0.25) return 'auto';
    if (t >= s5.route + 0.4) return 'draft';
    if (t >= s4.clickP1 + 0.2) return 'ask';
    if (t >= s4.clickWb + 0.2) return 'pri';
    if (t >= s4.clickRes + 0.2) return 'res';
    return 'pri';
  }
  CC.render = function (t, triad) {
    const open = K.p(t, s4.open, s4.open + 0.8, 'out'), close = K.p(t, s5.close, s5.close + 0.7, 'in');
    const vis = open > 0 && close < 1;
    if (!vis) { css(E.cc, { display: 'none' }); return; }
    css(E.cc, { display: 'block' });
    css(E.dim, { opacity: (open * (1 - close)).toFixed(3) });
    const ctx = E.bctx; ctx.clearRect(0, 0, 1920, 1080);
    // global unfold from the triad (scale) and fold back into it
    const sc = 0.2 + 0.8 * open, fsc = 1 - 0.85 * close, alpha = open * (1 - close);
    const org = close > 0 ? triad : [CC.TRIAD[0], CC.TRIAD[1]];
    const wrap = `translate(${org[0]}px, ${org[1]}px) scale(${(sc * fsc).toFixed(4)}) translate(${-org[0]}px, ${-org[1]}px)`;
    for (const el of [E.nodes, E.titles, E.orbit, E.resolved]) css(el, { transform: wrap, opacity: alpha.toFixed(3) });
    ctx.save(); ctx.translate(org[0], org[1]); ctx.scale(sc * fsc, sc * fsc); ctx.translate(-org[0], -org[1]); ctx.globalAlpha = alpha;
    const rq = regroupP(D.sessions[0].id, t), rqAll = K.p(t, s4.regroupAnim, s4.regroupAnim + 1.5);
    const recede = K.p(t, s5.route, s5.route + 1.0, 'inOut');       // profile opens
    const focus = K.p(t, s4.clickP1, s4.clickP1 + 0.4, 'inOut') * (1 - recede);
    const morph = K.p(t, s4.approved, s4.approved + 0.5, 'inOut');
    const nodeAlpha = 1 - 0.95 * recede;
    // titles
    for (const key in E.title) {
      const [mode, name] = key.split(':');
      const on = mode === 'project' ? 1 - K.p(t, s4.regroupAnim, s4.regroupAnim + 0.5) : K.p(t, s4.regroupAnim + 0.7, s4.regroupAnim + 1.3);
      const el = E.title[key];
      const count = mode === 'component' && relaxP(t) > 0.5 ? LAY.relaxed.titles.find(x => x.name === name).count : LAY[mode].titles.find(x => x.name === name).count;
      html(el, `${name}<span class="n">${count}</span>`);
      css(el, { opacity: (on * nodeAlpha * (1 - 0.6 * focus)).toFixed(3) });
    }
    // nodes
    for (const s of D.sessions) {
      const { pos, gone } = CC.nodePos(s.id, t);
      const el = E.node[s.id];
      const dimF = focus > 0 && s.id !== 1 ? 1 - 0.7 * focus : 1;
      const la = (1 - Math.min(1, gone * 2.5)) * nodeAlpha * dimF;
      css(el, { transform: `translate(${Math.round(pos[0])}px, ${Math.round(pos[1] - 19)}px)`, opacity: la.toFixed(3), visibility: la > 0.01 ? 'visible' : 'hidden' });
      if (la > 0.01 || gone < 1) {
        const dotSc = gone > 0 ? K.lerp(1, 0.6, gone) : 1;
        if (gone > 0 && gone < 1) { Orbit.dot; ctx.shadowColor = CYAN; ctx.shadowBlur = 8; ctx.fillStyle = `rgba(200,245,250,${(0.9 * (1 - gone * 0.3)).toFixed(2)})`; ctx.globalAlpha = alpha; ctx.beginPath(); ctx.arc(pos[0], pos[1], 4, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0; }
        else if (gone < 1) dotState(ctx, pos[0], pos[1], s.status, t, s.id, dotSc, alpha * nodeAlpha * dimF, s.id === 1 ? morph : 0);
      }
    }
    // priority light-lines
    const pri = D.sessions.filter(s => s.priority);
    pri.forEach((s, i) => {
      const prog = K.p(t, s4.lines + i * 0.25, s4.lines + i * 0.25 + 0.8, 'out');
      const { pos } = CC.nodePos(s.id, t);
      const a = (focus > 0 ? (s.id === 1 ? 1 : 1 - 0.8 * focus) : 1) * (1 - recede) * alpha;
      lightLine(ctx, [triad[0], triad[1]], pos, prog, a, String(s.priority));
    });
    // resolved ring
    const count = CC.resolvedCount(t), resAlpha = K.p(t, s4.resolveAnim, s4.resolveAnim + 0.4) * (1 - recede);
    css(E.resolved, { opacity: (resAlpha * alpha).toFixed(3) });
    text(E.resCount, String(count));
    if (resAlpha > 0) {
      const lastArr = D.sessions.filter(s => s.status === 'done').map(s => s4.resolveAnim + (idx(s.id) % 10) * 0.09 + 0.85).filter(x => x <= t);
      const pulse = lastArr.length ? Math.max(0, 1 - (t - Math.max(...lastArr)) / 0.3) : 0;
      ctx.globalAlpha = resAlpha * alpha; ctx.strokeStyle = CYAN; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.arc(CC.RING[0], CC.RING[1], 13 + 4 * pulse, 0, Math.PI * 2); ctx.stroke();
      ctx.fillStyle = CYAN; ctx.globalAlpha = resAlpha * alpha * (0.35 + 0.65 * Math.min(1, count / 10)); ctx.beginPath(); ctx.arc(CC.RING[0], CC.RING[1], 4 + 3 * Math.min(1, count / 10), 0, Math.PI * 2); ctx.fill(); ctx.globalAlpha = alpha;
    }
    // ---- FLORA profile (scene 5) ----
    if (recede > 0) {
      const C = CC.CENTER, ringP = K.p(t, s5.ring, s5.ring + 1.0, 'out');
      ctx.globalAlpha = alpha * recede;
      // 24-hour ring
      ctx.strokeStyle = 'rgba(210,230,255,.22)'; ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(C[0], C[1], RING_R, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ringP); ctx.stroke();
      for (let h = 0; h < 24 * ringP; h++) { const [x1, y1] = polar(C, h * 15, RING_R - (h % 6 ? 4 : 8)), [x2, y2] = polar(C, h * 15, RING_R); ctx.strokeStyle = h % 6 ? 'rgba(210,230,255,.25)' : 'rgba(210,230,255,.5)'; ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); }
      const schedTick = (ang, color, len, a) => { const [x1, y1] = polar(C, ang, RING_R - 2), [x2, y2] = polar(C, ang, RING_R + len); ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.globalAlpha = alpha * recede * a; ctx.shadowColor = color; ctx.shadowBlur = 6; ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke(); ctx.shadowBlur = 0; };
      const tickA = K.p(t, s5.ring + 0.8, s5.ring + 1.2);
      schedTick(324.25, VIOLET, 14, tickA); schedTick(165, VIOLET, 14, tickA);
      const newP = K.p(t, s5.fSchedule, s5.fSchedule + 0.5, 'out'), act = K.p(t, s5.active, s5.active + 0.4);
      if (newP > 0) schedTick(127.5, act > 0 ? K.mix(VIOLET, GREEN, act) : VIOLET, 14 * newP, 1);
      E.ticks.forEach((el, i) => css(el, { opacity: (i < 4 ? ringP : el === E.tNew ? newP : tickA).toFixed(3) }));
      css(E.tNew, { color: act > 0 ? K.mix(VIOLET, GREEN, act) : VIOLET });
      css(E.flora, { opacity: ringP.toFixed(3) });
      // satellites + lines
      E.sat.forEach((s, i) => {
        const ap = K.p(t, s5.sats + i * 0.09, s5.sats + i * 0.09 + 0.5, 'out');
        let on = s.on ? 1 : 0;
        if (s.name === 'Stripe') on = K.p(t, s5.stripeOn, s5.stripeOn + 0.5, 'inOut');
        const glance = K.win(t, s5.glance, s5.glance + 2.2, 0.4, 0.5);
        css(s.el, { opacity: ap.toFixed(3) });
        if (s.name === 'Stripe') { const isOn = on > 0.5; if (s.el.__on !== isOn) { s.el.__on = isOn; s.el.classList.toggle('off', !isOn); s.sw.classList.toggle('on', isOn); } }
        css(s.sf, { color: glance > 0 ? K.mix(SEC, TEXT, glance) : SEC, fontWeight: glance > 0.5 ? '600' : '400' });
        if (s.name === 'Stripe') text(s.sf, on > 0.5 ? 'connected just now' : s.fresh);
        // line from centre
        const a0 = polar(C, s.ang, 28), a1 = polar(C, s.ang, SAT_R - 12);
        ctx.globalAlpha = alpha * recede * ap;
        if (on < 1) { ctx.setLineDash([3, 7]); ctx.strokeStyle = INACT; ctx.lineWidth = 1; ctx.globalAlpha *= (1 - on) * 0.8; ctx.beginPath(); ctx.moveTo(a0[0], a0[1]); ctx.lineTo(a1[0], a1[1]); ctx.stroke(); ctx.setLineDash([]); ctx.globalAlpha = alpha * recede * ap; }
        if (on > 0) { ctx.strokeStyle = CYAN; ctx.lineWidth = 1.2; ctx.globalAlpha *= 0.55 * on; ctx.shadowColor = CYAN; ctx.shadowBlur = 4; ctx.beginPath(); ctx.moveTo(a0[0], a0[1]); ctx.lineTo(a0[0] + (a1[0] - a0[0]) * on, a0[1] + (a1[1] - a0[1]) * on); ctx.stroke(); ctx.shadowBlur = 0; }
        ctx.globalAlpha = alpha * recede * ap;
        ctx.fillStyle = on > 0.5 ? CYAN : INACT; ctx.beginPath(); ctx.arc(s.x, s.y, 4.5, 0, Math.PI * 2); ctx.fill();
        if (on > 0.5) { ctx.strokeStyle = CYAN; ctx.lineWidth = 1; ctx.globalAlpha *= 0.5; ctx.beginPath(); ctx.arc(s.x, s.y, 9, 0, Math.PI * 2); ctx.stroke(); }
      });
      ctx.globalAlpha = 1;
    } else { for (const el of E.ticks) css(el, { opacity: '0' }); css(E.flora, { opacity: '0' }); E.sat.forEach(s => css(s.el, { opacity: '0' })); }
    ctx.restore();
    // ---- rail ----
    const railIn = K.p(t, s4.rail, s4.rail + 0.5, 'out') * (1 - close);
    css(E.rail, { opacity: railIn.toFixed(3), transform: `translateX(${((1 - railIn) * 40).toFixed(1)}px)`, display: railIn > 0 ? 'block' : 'none' });
    const resolved = t >= s4.resolveAnim + 1.7 ? 10 : CC.resolvedCount(t), wbN = 20 - resolved;
    const view = railView(t);
    text(E.rHead.wb, `Workbench ${wbN}`); text(E.rHead.rs, resolved ? `Resolved ${resolved}` : 'Resolved');
    E.rHead.wb.classList.toggle('on', view !== 'res'); E.rHead.rs.classList.toggle('on', view === 'res');
    text(E.rGroup, rqAll > 0.5 ? 'grouped by component' : 'grouped by project');
    for (const k in E.views) {
      const on = k === view; const el = E.views[k];
      const since = { pri: view === 'pri' && t >= s4.clickWb ? s4.clickWb + 0.2 : 0, res: s4.clickRes + 0.2, ask: s4.clickP1 + 0.2, draft: s5.route + 0.4, auto: s5.list + 0.25 }[k];
      const a = on ? K.p(t, since, since + 0.3, 'out') : 0;
      css(el, { opacity: a.toFixed(3), visibility: on ? 'visible' : 'hidden', transform: `translateY(${((1 - a) * 6).toFixed(1)}px)` });
    }
    // ask view content
    const approved = t >= s4.approved;
    text(E.askState, approved ? 'running' : 'needs you'); css(E.askState, { color: approved ? CYAN : AMBER });
    css(E.askDone, { opacity: K.p(t, s4.approved, s4.approved + 0.4).toFixed(3) }); css(E.askActs, { opacity: (1 - K.p(t, s4.approved, s4.approved + 0.4) * 0.6).toFixed(3) });
    // draft view content
    const dr = D.automation.draft;
    const fill = (k, at, val) => { const p = K.p(t, at, at + 0.35, 'out'); text(E.fld[k].v, p > 0 ? val : ''); css(E.fld[k].v, { opacity: p.toFixed(3) }); css(E.fld[k].ph, { visibility: p > 0 ? 'hidden' : 'visible' }); };
    fill('name', s5.fName, dr.name); fill('schedule', s5.fSchedule, dr.schedule); fill('deliver', s5.fDeliver, dr.deliver); fill('access', s5.fAccess, dr.access);
    const sp = K.p(t, s5.fStreams, s5.fStreams + 0.4, 'out'), stp = K.p(t, s5.stripeOn, s5.stripeOn + 0.4, 'out');
    html(E.streams, D.automation.streams.map((s, i) => `<div class="srow" style="opacity:${i < 3 ? sp.toFixed(2) : stp.toFixed(2)}"><div><div class="sn">${esc(s.name)}</div><div class="sfr">${esc(i === 3 ? 'connected just now' : s.fresh)}</div></div><span class="st">on</span></div>`).join(''));
    const stA = K.p(t, s5.active, s5.active + 0.4, 'out');
    text(E.status, stA > 0 ? `Active · next ${dr.nextRun}` : ''); css(E.status, { opacity: stA.toFixed(3) });
  };
  window.CC = CC;
})();
