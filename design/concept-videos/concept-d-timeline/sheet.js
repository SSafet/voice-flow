// The sheet: FLORA's control center as a day timeline (scene 4) and the automations view (scene 5).
(function () {
  const D = window.VF, K = window.K, T = window.T, css = K.css, text = K.text, html = K.html;
  const s4 = T.s4, s5 = T.s5;
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const INK = '#1C1A17', INK2 = '#57524A', INK3 = '#736D63', RED = '#D6442C', GREEN = '#2F7D4F', AMBER = '#B26A00', DONE = '#8A8479';
  const COL = { needs: AMBER, failed: '#C0392B', review: AMBER, running: GREEN, idle: DONE, done: DONE };
  const AREA_W = 1100 - 16 - 42, LABELW = 330, TLW = AREA_W - LABELW;
  // Broken axis: 21:00–06:00 (overnight) compressed into OVER_W px behind a zig-zag break, then 06:00→10:00 linear.
  const H0 = 21, HB = 30, H1 = 34, NOW0 = 33 + 41 / 60;         // 21:00 · break at 06:00 · 10:00; now 09:41
  const OVER_W = 100, DAY_W = TLW - OVER_W;
  const xOfHour = h => LABELW + (h <= HB ? (h - H0) / (HB - H0) * OVER_W : OVER_W + (h - HB) / (H1 - HB) * DAY_W);
  const ageMin = s => { const m = s.match(/(\d+)\s*(min|h)/); return m[2] === 'h' ? +m[1] * 60 : +m[1]; };
  const DUR = { 1: 48, 3: 35, 4: 70, 5: 40, 7: 25, 8: 30, 19: 90, 9: 22, 12: 60, 13: 18, 20: 20, 14: 95, 15: 45, 16: 40, 18: 75 };
  const ROWH = 19, GH = 18, OPEN_EXTRA = 62;
  const Sheet = {}; const E = {};
  const S = D.sessions, byId = {}; S.forEach(s => byId[s.id] = s);
  const nowHour = t => NOW0 + Math.max(0, t - s4.open) / 3600;
  const nowLabel = t => { const h = nowHour(t), hh = Math.floor(h) % 24, mm = Math.floor((h % 1) * 60); return `${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}`; };
  function barOf(s, t) {
    const run = s.status === 'running';
    if (run) return { a: NOW0 - ageMin(s.age) / 60, b: nowHour(t) };
    const b = NOW0 - ageMin(s.age) / 60;
    return { a: b - DUR[s.id] / 60, b };
  }

  // ---------- build ----------
  Sheet.build = function () {
    const root = document.getElementById('v-sheet');
    // 21:00 at the left edge, the compressed overnight band, a zig-zag break on the axis line, then hourly ticks
    const bx = xOfHour(HB);
    const ticks = `<div class="night" style="left:${LABELW}px;width:${OVER_W}px"></div><div class="axl" style="left:${LABELW}px;width:${(bx - 16 - LABELW).toFixed(1)}px"></div><div class="axl" style="left:${(bx - 2).toFixed(1)}px;width:${(TLW - (bx - 2 - LABELW)).toFixed(1)}px"></div>` +
      `<svg class="brk" style="left:${(bx - 16).toFixed(1)}px" width="14" height="10" viewBox="0 0 14 10"><path d="M0 5 L4 5 L6 1 L9 9 L11 5 L14 5" fill="none" stroke="rgba(28,26,23,.45)" stroke-width="1.2"/></svg>` +
      `<div class="ax first" style="left:${xOfHour(H0).toFixed(1)}px">21:00</div>` +
      [30, 31, 32, 33].map(h => `<div class="ax" style="left:${xOfHour(h).toFixed(1)}px">${String(h % 24).padStart(2, '0')}:00</div><div class="gl" style="left:${xOfHour(h).toFixed(1)}px"></div>`).join('');
    root.innerHTML = `<div class="sh-head"><span class="hl"></span><span class="sh-right"></span></div>
      <div class="tl">${ticks}<div class="ax now" id="ax-now"></div><div class="nowl" id="nowl"></div><div class="rows" id="rows"></div></div>
      <div class="au" id="au"></div>
      <div class="sh-foot"><i class="fd"></i><span class="fw"></span></div>`;
    E.root = root; E.hl = root.querySelector('.hl'); E.right = root.querySelector('.sh-right'); E.tl = root.querySelector('.tl'); E.rows = root.querySelector('#rows');
    E.au = root.querySelector('#au'); E.foot = root.querySelector('.sh-foot'); E.fd = E.foot.querySelector('.fd'); E.fw = E.foot.querySelector('.fw');
    E.axNow = root.querySelector('#ax-now'); E.nowl = root.querySelector('#nowl');
    // rows
    E.row = {};
    for (const s of S) {
      const r = document.createElement('div'); r.className = 'row';
      const gcls = s.status === 'failed' ? 'gl2 x' : s.status === 'idle' ? 'gl2 o' : 'gl2';
      r.innerHTML = `<span class="num">${s.priority || ''}</span><i class="${gcls}" style="background:${COL[s.status]}"></i><span class="ti">${esc(s.title)}</span><span class="rt">${s.runtime}</span>
        <i class="bar${s.status === 'idle' ? ' o' : ''}" style="background:${COL[s.status]}"></i>${s.status === 'needs' ? '<i class="flag"></i>' : ''}${s.status === 'failed' ? '<i class="fx"></i>' : ''}
        ${s.priority ? `<span class="ask ${s.status === 'needs' ? 'a' : s.status === 'failed' ? 'f' : ''}">${esc(s.line)}</span>` : ''}
        ${s.id === 1 ? `<div class="det"><div class="dt">${esc(D.checkoutAsk.title)}</div><div class="db">${esc(D.checkoutAsk.body)}</div><div class="da acts"><b>Approve</b>Not now</div><div class="da ok">${esc(D.checkoutAsk.approvedLine)}</div></div>` : ''}`;
      E.rows.appendChild(r);
      E.row[s.id] = { el: r, bar: r.querySelector('.bar'), flag: r.querySelector('.flag'), fx: r.querySelector('.fx'), ask: r.querySelector('.ask'), num: r.querySelector('.num'), gl: r.querySelector('.gl2'), det: r.querySelector('.det') };
    }
    // group headers: 4 projects + 3 components + resolved list
    E.head = {};
    const mkHead = (key, label) => { const h = document.createElement('div'); h.className = 'gh'; h.innerHTML = `${esc(label)}<span class="n"></span>`; E.rows.appendChild(h); E.head[key] = { el: h, n: h.querySelector('.n') }; };
    D.projects.forEach(p => mkHead('p:' + p, p)); D.components.forEach(c => mkHead('c:' + c, c)); mkHead('resolved', 'Resolved today');
    // resolved track
    E.track = document.createElement('div'); E.track.className = 'track';
    E.track.innerHTML = `<span class="tlab">Resolved · <b>10</b></span>` + S.filter(s => s.status === 'done').map(s => `<i class="tk" data-id="${s.id}" style="left:${(xOfHour(barOf(s, 0).b) - 1).toFixed(1)}px"></i>`).join('');
    E.rows.appendChild(E.track); E.tks = [...E.track.querySelectorAll('.tk')];
    // measure ask widths (labels sit left of their bar)
    for (const s of S) if (s.priority) { const R = E.row[s.id]; R.askW = R.ask.getBoundingClientRect().width; }
    buildAutomations();
    E.au.style.display = 'block';
    // layouts
    E.L = {}; for (const k of ['project', 'component', 'component-resolved', 'resolved', 'component-open']) E.L[k] = layout(k);
  };
  function layout(kind) {
    const rows = {}, heads = {}; let y = 0; let track = null;
    const group = (key, items) => { heads[key] = { y, n: items.length }; y += GH; for (const s of items) { rows[s.id] = { y, open: kind === 'component-open' && s.id === 1 ? 1 : 0 }; y += ROWH + (kind === 'component-open' && s.id === 1 ? OPEN_EXTRA : 0); } };
    if (kind === 'project') D.projects.forEach(p => group('p:' + p, S.filter(s => s.project === p)));
    else if (kind === 'resolved') group('resolved', S.filter(s => s.status === 'done').sort((a, b) => ageMin(a.age) - ageMin(b.age)));
    else {
      const keep = kind === 'component' ? S : S.filter(s => s.status !== 'done');
      D.components.forEach(c => group('c:' + c, keep.filter(s => s.component === c)));
      if (kind !== 'component') { y += 6; track = { y }; y += ROWH; }
    }
    return { rows, heads, track, height: y };
  }
  const SEQ = [[s4.open, 'project', 0], [s4.regroupAnim, 'component', s4.regroupDur], [s4.resolveAnim, 'component-resolved', s4.resolveDur], [s4.clickRes + 0.05, 'resolved', 0.5], [s4.clickWb + 0.05, 'component-resolved', 0.5], [s4.clickP1 + 0.05, 'component-open', 0.45]];
  function viewAt(t) { let i = 0; while (i + 1 < SEQ.length && SEQ[i + 1][0] <= t) i++; const [since, kind, dur] = SEQ[i]; const prev = i ? SEQ[i - 1][1] : kind; return { A: E.L[prev], B: E.L[kind], p: dur ? K.p(t, since, since + dur, 'inOut') : 1, kind, prev, since, dur }; }
  // screen position helpers for the pointer
  Sheet.rowScreen = function (id, kind, sheetRect) { const r = E.L[kind].rows[id]; const tlTop = 28 + 14; return { x: sheetRect.x + 16 + 60, y: sheetRect.y + tlTop + r.y + ROWH / 2 }; };

  // ---------- timeline render ----------
  function renderTimeline(t, st) {
    const V = viewAt(t), { A, B, p } = V;
    const rowsIn = K.p(t, s4.rowsIn, s4.rowsIn + 0.5, 'out');
    // header tabs
    const resolvedN = t >= s4.resolveAnim + s4.resolveDur * 0.5 ? 10 : 0;
    const wbN = 20 - resolvedN, onRes = V.kind === 'resolved';
    html(E.hl, `<span class="tab${onRes ? '' : ' on'}" data-k="wb">Workbench ${wbN}</span><span class="sep">·</span><span class="tab${onRes ? ' on' : ''}" data-k="res">Resolved${resolvedN ? ' ' + resolvedN : ''}</span><span class="sep">·</span><span class="tab" data-k="hist">History</span>`);
    const gSwap = s4.regroupAnim + s4.regroupDur * 0.5;
    text(E.right, t < gSwap ? 'Grouped by project' : 'Grouped by component');
    css(E.right, { opacity: (1 - K.win(t, gSwap - 0.2, gSwap + 0.2, 0.2, 0.2) * 0.9).toFixed(3) });
    // now line
    const nx = xOfHour(nowHour(t));
    css(E.nowl, { left: nx.toFixed(1) + 'px' }); css(E.axNow, { left: nx.toFixed(1) + 'px' }); text(E.axNow, nowLabel(t));
    // rows
    for (const s of S) {
      const R = E.row[s.id], a = A.rows[s.id], b = B.rows[s.id];
      let y, alpha, open = 0, fold = 0;
      if (a && b) { y = K.lerp(a.y, b.y, p); alpha = 1; open = K.lerp(a.open || 0, b.open || 0, p); }
      else if (a && !b) { // leaving: done rows fold into the track, others fade
        if (B.track && s.status === 'done') { y = K.lerp(a.y, B.track.y, p); alpha = 1 - K.p(p, 0.35, 1); fold = p; }
        else { y = a.y; alpha = 1 - p; }
      }
      else if (!a && b) { y = b.y + (1 - p) * 6; alpha = p; }
      else { css(R.el, { visibility: 'hidden' }); continue; }
      alpha *= rowsIn;
      if (alpha <= 0.002) { css(R.el, { visibility: 'hidden' }); continue; }
      // bar
      let { a: h0, b: h1 } = barOf(s, t); let color = COL[s.status];
      if (s.id === 1 && t >= s4.approved) { const q = K.p(t, s4.approved, s4.approved + 0.7, 'inOut'); h1 = K.lerp(h1, nowHour(t), q); color = K.mix(AMBER, GREEN, q); }
      const x0 = xOfHour(h0), x1 = xOfHour(h1);
      css(R.bar, { left: x0.toFixed(1) + 'px', width: Math.max(8, x1 - x0).toFixed(1) + 'px', background: s.status === 'idle' ? 'none' : color });
      if (R.flag) css(R.flag, { left: (x1 + 1).toFixed(1) + 'px', opacity: (s.id === 1 && t >= s4.approved ? 1 - K.p(t, s4.approved, s4.approved + 0.4) : 1).toFixed(3) });
      if (R.fx) css(R.fx, { left: (x1 - 2).toFixed(1) + 'px' });
      if (R.gl && s.id === 1) css(R.gl, { background: color });
      if (R.ask) css(R.ask, { left: (x0 - 6 - R.askW).toFixed(1) + 'px', opacity: (s.id === 1 ? 1 - K.p(t, s4.approved, s4.approved + 0.4) : 1).toFixed(3) });
      if (R.num) css(R.num, { opacity: (s.id === 1 && t >= s4.approved ? 1 - K.p(t, s4.approved, s4.approved + 0.5) : 1).toFixed(3) });
      if (R.det) {
        css(R.det, { visibility: open > 0.01 ? 'visible' : 'hidden', opacity: open.toFixed(3), transform: `translateY(${((1 - open) * -4).toFixed(1)}px)` });
        const ap = K.p(t, s4.approved - 0.1, s4.approved + 0.3);
        css(R.det.querySelector('.acts'), { opacity: (1 - ap).toFixed(3) }); css(R.det.querySelector('.ok'), { opacity: ap.toFixed(3) });
      }
      const sc = 1 - 0.5 * fold;
      css(R.el, { visibility: 'visible', opacity: alpha.toFixed(3), transform: `translateY(${y.toFixed(2)}px) scaleY(${sc.toFixed(3)})`, transformOrigin: '0 50%' });
      R.el.classList.toggle('dim', s.status === 'done' || s.status === 'idle');
    }
    // heads
    for (const key in E.head) {
      const H = E.head[key], a = A.heads[key], b = B.heads[key];
      let y, alpha;
      if (a && b) { y = K.lerp(a.y, b.y, p); alpha = 1; text(H.n, String(p < 0.5 ? a.n : b.n)); }
      else if (a) { y = a.y; alpha = 1 - p; text(H.n, String(a.n)); }
      else if (b) { y = b.y + (1 - p) * 6; alpha = p; text(H.n, String(b.n)); }
      else { css(H.el, { visibility: 'hidden' }); continue; }
      alpha *= rowsIn;
      css(H.el, { visibility: alpha > 0.002 ? 'visible' : 'hidden', opacity: alpha.toFixed(3), transform: `translateY(${y.toFixed(2)}px)` });
    }
    // track
    const ta = A.track, tb = B.track;
    let ty = null, talpha = 0;
    if (ta && tb) { ty = K.lerp(ta.y, tb.y, p); talpha = 1; } else if (tb) { ty = tb.y; talpha = K.p(p, 0.3, 1); } else if (ta) { ty = ta.y; talpha = 1 - p; }
    if (ty == null || talpha <= 0.002) css(E.track, { visibility: 'hidden' });
    else { css(E.track, { visibility: 'visible', opacity: talpha.toFixed(3), transform: `translateY(${ty.toFixed(2)}px)` }); }
  }

  // ---------- automations ----------
  const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  function buildAutomations() {
    const A = D.automation;
    const yOf = h => 20 + h / 24 * 48;
    const cols = DAYS.map((d, i) => {
      let marks = `<i class="m dot" style="left:0;top:${(yOf(21 + 37 / 60) - 2).toFixed(1)}px"></i>`;
      if (i === 0) marks += [9.0, 13.0, 17.0].map(h => `<i class="m tri" style="left:0;top:${(yOf(h) - 2).toFixed(1)}px"></i>`).join('');
      if (i < 5) marks += `<i class="m tick" data-i="${i}" style="left:0;top:${(yOf(8.5) - 1).toFixed(1)}px"></i>`;
      return `<div class="col" style="left:${i * 140}px"><span class="d">${d.toUpperCase()}</span><i class="ax"></i><i class="base"></i>${marks}</div>`;
    }).join('');
    const dl = [['name', 'Name'], ['schedule', 'Schedule'], ['deliver', 'Deliver'], ['access', 'Access'], ['status', 'Status']].map(([k, l]) => `<div class="dl"><span class="k">${l}</span><span class="v ph" data-f="${k}">—</span></div>`).join('');
    const ar = A.existing.map(e => `<div class="ar">${esc(e.name)}<span class="sc">${esc(e.schedule)}</span><span class="sw">On</span></div>`).join('') +
      `<div class="ar new" id="ar-new">${esc(A.draft.name)}<span class="sc">${esc(A.draft.schedule)}</span><span class="nr">next ${esc(A.draft.nextRun)}</span><span class="sw">On</span></div>`;
    const sr = A.streams.map((s, i) => `<div class="sr off" data-i="${i}"><span class="nm">${esc(s.name)}</span><span class="dt">${esc(s.detail)}</span><span class="fr">${esc(s.fresh)}</span><span class="sw off">Off</span></div>`).join('');
    const so = A.otherStreams.map(s => `<div class="sr off"><span class="nm">${esc(s.name)}</span><span class="dt"></span><span class="fr">${esc(s.fresh)}</span><span class="sw off">Off</span></div>`).join('');
    E.au.innerHTML = `<div class="wk">${cols}<div class="lg"><span><i class="dot"></i>Nightly screen review · 21:37</span><span><i class="tri"></i>Release QA · on push</span><span class="lnew"><i class="tick"></i>${esc(A.draft.name)} · 08:30 weekdays</span></div></div>
      <div class="lft"><div class="h">New automation</div>${dl}<div class="h sub">Automations</div>${ar}</div>
      <div class="rgt"><div class="h">Data streams</div>${sr}<div class="h sub">Available</div>${so}</div>`;
    E.f = {}; E.au.querySelectorAll('.v[data-f]').forEach(v => E.f[v.dataset.f] = v);
    E.ticks = [...E.au.querySelectorAll('.m.tick')]; E.lnew = E.au.querySelector('.lnew'); E.arNew = E.au.querySelector('#ar-new');
    E.sr = [...E.au.querySelectorAll('.sr[data-i]')];
  }
  function field(el, at, value, t, cls) {
    const p = K.p(t, at, at + 0.35, 'out');
    if (p <= 0) { text(el, '—'); el.className = 'v ph'; css(el, { opacity: '1', transform: 'none' }); return; }
    text(el, value); el.className = 'v' + (cls ? ' ' + cls : '');
    css(el, { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * 4).toFixed(1)}px)` });
  }
  function renderAutomations(t) {
    const A = D.automation;
    field(E.f.schedule, s5.fSchedule, A.draft.schedule, t);
    field(E.f.name, s5.fName, A.draft.name, t);
    field(E.f.deliver, s5.fDeliver, A.draft.deliver, t);
    field(E.f.access, s5.fAccess, A.draft.access, t);
    if (t < s5.active) field(E.f.status, s5.view + 0.3, 'Draft', t); else field(E.f.status, s5.active, `Active · next ${A.draft.nextRun}`, t, 'ok');
    // week ticks draw in, settle to ink when active
    const settle = K.p(t, s5.active, s5.active + 0.6, 'inOut');
    E.ticks.forEach((el, i) => { const p = K.p(t, s5.fSchedule + i * 0.1, s5.fSchedule + i * 0.1 + 0.25, 'out'); css(el, { width: (12 * p).toFixed(1) + 'px', background: K.mix(RED, INK, settle), opacity: p > 0 ? '1' : '0' }); });
    css(E.lnew, { opacity: K.p(t, s5.fSchedule + 0.4, s5.fSchedule + 0.8).toFixed(3) }); css(E.lnew.querySelector('i'), { background: K.mix(RED, INK, settle) });
    // streams
    E.sr.forEach((row, i) => {
      const s = A.streams[i];
      let on = i < 3 ? K.p(t, s5.fStreams + i * 0.12, s5.fStreams + i * 0.12 + 0.3) : K.p(t, s5.stripeOn, s5.stripeOn + 0.3);
      const isOn = on > 0.5;
      if (row.__on !== isOn) { row.__on = isOn; row.classList.toggle('off', !isOn); const sw = row.querySelector('.sw'); sw.classList.toggle('off', !isOn); text(sw, isOn ? 'On' : 'Off'); }
      if (i === 3) { const fr = row.querySelector('.fr'); const conn = t >= s5.stripeOn; text(fr, conn ? 'connected just now' : s.fresh); fr.classList.toggle('ok', conn); css(fr, { opacity: (1 - 0.8 * K.win(t, s5.stripeOn - 0.15, s5.stripeOn + 0.15, 0.15, 0.15)).toFixed(3) }); }
    });
    const na = K.p(t, s5.active + 0.15, s5.active + 0.5, 'out');
    css(E.arNew, { opacity: na.toFixed(3), transform: `translateY(${((1 - na) * 6).toFixed(1)}px)`, visibility: na > 0 ? 'visible' : 'hidden' });
  }

  // ---------- public ----------
  // st: {t, foot: {html, color} | null}
  Sheet.render = function (st) {
    const t = st.t;
    css(E.root, { height: Sheet.height(t) + 'px' });          // the view follows the paper's height so the voice line stays on its bottom edge
    const toAu = K.p(t, s5.view, s5.view + 0.5, 'inOut');
    if (toAu < 1) { css(E.tl, { display: 'block', opacity: (1 - toAu).toFixed(3), transform: `translateY(${(-6 * toAu).toFixed(1)}px)` }); renderTimeline(t, st); }
    else css(E.tl, { display: 'none' });
    if (toAu > 0) { css(E.au, { display: 'block', opacity: toAu.toFixed(3), transform: `translateY(${(6 * (1 - toAu)).toFixed(1)}px)` }); renderAutomations(t); }
    else css(E.au, { display: 'none' });
    if (toAu >= 0.5) { html(E.hl, `<span class="fl">FLORA</span><span class="sep">›</span><span class="tab on">Automations</span>`); text(E.right, t >= s5.active + 0.5 ? '3 automations' : 'Drafting'); css(E.right, { opacity: '1' }); }
    // footer voice line
    if (st.foot) { css(E.foot, { visibility: 'visible', opacity: (st.foot.alpha == null ? 1 : st.foot.alpha).toFixed(3) }); css(E.fd, { background: st.foot.color || RED, opacity: st.foot.dot === false ? '0' : '1' }); html(E.fw, st.foot.html); }
    else css(E.foot, { visibility: 'hidden' });
  };
  // the paper is only as tall as its content: 28 header + content + 24 footer + 2
  const AU_H = 364;
  Sheet.height = function (t) {
    const V = viewAt(t);
    const hTl = 14 + K.lerp(V.A.height, V.B.height, V.p);
    const toAu = K.p(t, s5.view, s5.view + 0.5, 'inOut');
    return Math.round(28 + K.lerp(hTl, AU_H, toAu) + 24 + 2);
  };
  Sheet.headTab = function (which) { const el = E.hl.querySelector(`.tab[data-k="${which}"]`); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
  Sheet.LABELW = LABELW; Sheet.ROWH = ROWH;
  window.Sheet = Sheet;
})();
