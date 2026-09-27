// center.js — content of the drop-down sheet hanging from the island: the control center
// (20 sessions in two columns, regroup FLIP, resolve fold, priority detail), FLORA's automations
// with data streams, and the capture payload. Layouts are computed once; renderAt only moves things.
(function () {
  const D = window.VF, K = window.K, css = K.css, text = K.text, html = K.html;
  const C = Island.C;
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const Sheet = {};
  const SESS = D.sessions;
  const W = 900, PAD = 24, COLW = 410, COLX = [PAD, PAD + COLW + 32], GH = 20, GAP = 10, BODY_Y = 42, ROW = 28, PRI = 44, EXP = 92;
  const E = { rows: {}, heads: {} };

  // ---------- layouts ----------
  function layout(by, filter, expanded) {
    const names = by === 'project' ? D.projects : D.components;
    const groups = names.map(name => ({ name, rows: SESS.filter(s => s[by] === name && filter(s)) })).filter(g => g.rows.length);
    const rowH = s => (s.priority ? PRI : ROW) + (expanded === s.id ? EXP : 0);
    const gH = g => GH + 4 + g.rows.reduce((a, s) => a + rowH(s), 0);
    let best = null;
    for (let k = 1; k <= groups.length; k++) {
      const h0 = groups.slice(0, k).reduce((a, g, i) => a + gH(g) + (i ? GAP : 0), 0);
      const h1 = groups.slice(k).reduce((a, g, i) => a + gH(g) + (i ? GAP : 0), 0);
      const m = Math.max(h0, h1); if (!best || m < best.m) best = { k, m };
    }
    const out = { rows: {}, groups: [], colH: best.m, order: {} };
    let col = 0, y = 0, n = 0;
    groups.forEach((g, gi) => {
      if (gi === best.k) { col = 1; y = 0; }
      if (y > 0) y += GAP;
      out.groups.push({ name: g.name, count: g.rows.length, x: COLX[col], y });
      y += GH + 4;
      for (const s of g.rows) { const h = rowH(s); out.rows[s.id] = { x: COLX[col], y, h }; out.order[s.id] = n++; y += h; }
    });
    out.height = 32 + 32 + 10 + out.colH + 16;   // island height that fits: band + header + pad + body + pad
    return out;
  }
  const notDone = s => s.status !== 'done', isDone = s => s.status === 'done', all = () => true;
  const L = Sheet.L = { A: layout('project', all, null), B: layout('component', all, null), W: layout('component', notDone, null), W1: layout('component', notDone, 1), R: layout('component', isDone, null) };
  Sheet.H = { A: L.A.height, B: L.B.height, W: L.W.height, W1: L.W1.height, R: L.R.height, AUTO: 420, GLANCE: 322, PAY: 302 };
  const lerpPos = (a, b, q) => q <= 0 ? a : q >= 1 ? b : { x: K.lerp(a.x, b.x, q), y: K.lerp(a.y, b.y, q), h: K.lerp(a.h, b.h, q) };

  // ---------- build ----------
  const sw = on => `<span class="tgl${on ? ' on' : ''}"></span>`;
  Sheet.build = function () {
    const root = Island.sheetEl();
    const A = D.automation, ex = A.existing;
    const streamRow = (s, i) => `<div class="srow" data-i="${i}"><span class="sn">${esc(s.name)}</span><span class="sf">${esc(s.detail ? s.detail + ' · ' : '')}<span class="fr">${esc(s.fresh)}</span></span>${sw(s.on)}</div>`;
    const glanceRow = (s, i) => `<div class="srow g" data-i="${i}"><span class="sn">${esc(s.name)}</span><span class="sf"><span class="fr">${esc(s.fresh)}</span></span>${sw(true)}</div>`;
    root.innerHTML = `
      <div id="cc" class="view">
        <div class="sh-head"><span class="tab on" id="tab-wb">Workbench <b>20</b></span><span class="tab" id="tab-res">Resolved<b></b></span><span class="tab" id="tab-his">History</span><span class="grp-by" id="grp-by">Grouped by project ▾</span></div>
        <div class="sh-body" id="cc-body"></div>
      </div>
      <div id="auto" class="view">
        <div class="sh-head"><span class="crumb"><span class="fl">FLORA</span><span class="sep">›</span><span>Automations</span></span></div>
        <div class="sh-body">
          <div class="a-list">
            ${ex.map(e => `<div class="arow"><div><div class="an">${esc(e.name)}</div><div class="as">${esc(e.schedule)}</div></div>${sw(true)}</div>`).join('')}
            <div class="arow new" id="a-new"><div><div class="an">${esc(A.draft.name)}</div><div class="as">${esc(A.draft.schedule)} · next ${esc(A.draft.nextRun)}</div></div>${sw(true)}</div>
          </div>
          <div class="a-draft" id="a-draft">
            <div class="f" data-f="name"><span class="k">Name</span><span class="v">${esc(A.draft.name)}</span></div>
            <div class="f" data-f="schedule"><span class="k">Schedule</span><span class="v">${esc(A.draft.schedule)}</span></div>
            <div class="f" data-f="deliver"><span class="k">Deliver</span><span class="v">${esc(A.draft.deliver)}</span></div>
            <div class="f" data-f="access"><span class="k">Access</span><span class="v">${esc(A.draft.access)}</span></div>
            <div class="k dl-h" data-f="streams">Data streams</div>
            <div class="streams">${A.streams.map(streamRow).join('')}</div>
            <div class="a-link" id="a-link">All data streams ›</div>
            <div class="f st" data-f="status"><span class="k">Status</span><span class="v"><span class="v1">Draft</span><span class="v2">Active · next ${esc(A.draft.nextRun)}</span></span></div>
          </div>
          <div class="a-glance" id="a-glance">
            <div class="k dl-h">Data streams · ${A.streams.length + A.otherStreams.length}</div>
            <div class="streams">${A.streams.map((s, i) => glanceRow({ name: s.name, fresh: s.fresh }, i)).join('')}${A.otherStreams.map((s, i) => glanceRow(s, i + 4)).join('')}</div>
          </div>
        </div>
      </div>
      <div id="pay" class="view">
        <div class="sh-head"><span class="p-title">${esc(D.capture.title)}</span><span class="p-meta">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</span>
          <span class="p-acts"><span class="a">Copy for any agent <kbd>⌘C</kbd></span><span class="sep">·</span><span class="b">Send to…</span></span></div>
        <div class="sh-body">
          <div class="p-strip" id="p-strip"></div>
          <div class="p-md">${D.payloadMarkdown.map(md).join('')}</div>
        </div>
      </div>`;
    E.cc = root.querySelector('#cc'); E.auto = root.querySelector('#auto'); E.pay = root.querySelector('#pay');
    E.tabWb = root.querySelector('#tab-wb'); E.tabRes = root.querySelector('#tab-res'); E.grpBy = root.querySelector('#grp-by');
    E.wbCount = E.tabWb.querySelector('b'); E.resCount = E.tabRes.querySelector('b');
    const body = root.querySelector('#cc-body');
    // group headers, one set per layout
    for (const key of ['A', 'B', 'W', 'R']) {
      E.heads[key] = L[key].groups.map(g => { const h = document.createElement('div'); h.className = 'grp'; h.innerHTML = `${esc(g.name)}<b>${g.count}</b>`; body.appendChild(h); return h; });
    }
    // rows
    SESS.forEach(s => {
      const r = document.createElement('div'); r.className = 'row st-' + s.status; r.dataset.id = s.id;
      r.innerHTML = `<span class="pr">${s.priority || ''}</span><i class="gl"></i><span class="ti">${esc(s.title)}</span><span class="me">${s.runtime} · ${s.age}</span>` +
        (s.priority ? `<span class="ln">${esc(s.line)}</span>` : '') +
        (s.id === 1 ? `<div class="ask"><div class="at">${esc(D.checkoutAsk.title)}</div><div class="ab">${esc(D.checkoutAsk.body)}</div><div class="ac"><span class="a">Approve</span><span class="sep">·</span><span class="b">Not now</span></div><div class="ad">${esc(D.checkoutAsk.approvedLine)}</div></div>` : '');
      body.appendChild(r); E.rows[s.id] = r;
    });
    E.row1 = E.rows[1]; E.ask = E.row1.querySelector('.ask'); E.ln1 = E.row1.querySelector('.ln'); E.gl1 = E.row1.querySelector('.gl'); E.pr1 = E.row1.querySelector('.pr');
    E.ac = E.ask.querySelector('.ac'); E.ad = E.ask.querySelector('.ad');
    E.aNew = root.querySelector('#a-new'); E.aDraft = root.querySelector('#a-draft'); E.aGlance = root.querySelector('#a-glance'); E.aLink = root.querySelector('#a-link');
    E.fields = {}; E.aDraft.querySelectorAll('[data-f]').forEach(el => E.fields[el.dataset.f] = el);
    E.sRows = [...E.aDraft.querySelectorAll('.srow')]; E.stripe = E.sRows[3]; E.stripeSw = E.stripe.querySelector('.tgl'); E.stripeFr = E.stripe.querySelector('.fr');
    E.gRows = [...E.aGlance.querySelectorAll('.srow')]; E.gStripeFr = E.gRows[3].querySelector('.fr');
    E.status1 = E.fields.status.querySelector('.v1'); E.status2 = E.fields.status.querySelector('.v2');
    E.pStrip = root.querySelector('#p-strip');
  };
  function md(line) {
    const m = line.match(/^(.*?)\s*(shot-\d\.png)$/), body = m ? m[1] : line, file = m ? m[2] : '';
    const cls = body.startsWith('## ') ? 'h' : body.startsWith('[') ? 'q' : 'm';
    return `<div class="ln"><span class="${cls}">${esc(body) || ' '}</span>${file ? `<span class="f">${file}</span>` : ''}</div>`;
  }
  Sheet.payThumbs = function (nodes) {
    nodes.forEach((n, i) => { const it = document.createElement('div'); it.className = 'p-it'; const th = document.createElement('div'); th.className = 'p-th'; th.appendChild(n); it.appendChild(th); const tt = document.createElement('div'); tt.className = 'p-tt'; tt.textContent = fmt(D.annotations[i].t) + '  ·  shot-' + (i + 1) + '.png'; it.appendChild(tt); E.pStrip.appendChild(it); });
  };
  const fmt = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
  Sheet.rect = function (sel) { const r = Island.sheetEl().querySelector(sel).getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  Sheet.rowRect = function (id, layoutKey) { const p = L[layoutKey].rows[id]; return { x: 960 - W / 2 + p.x, y: 32 + BODY_Y + p.y, w: COLW, h: p.h }; };

  // ---------- control center ----------
  // cc: { t, appearAt, regroupAt, resolveAt, resOpen, resClose, expandAt, approveAt }
  Sheet.cc = function (cc) {
    const t = cc.t, has = k => cc[k] != null;
    const rgHead = has('regroupAt') ? K.p(t, cc.regroupAt, cc.regroupAt + 1.1) : 0;
    const rs = has('resolveAt') ? K.p(t, cc.resolveAt + 0.25, cc.resolveAt + 0.85, 'inOut') : 0;
    const resP = has('resOpen') ? K.win(t, cc.resOpen, cc.resClose, 0.35, 0.35) : 0;
    const ex = has('expandAt') ? K.p(t, cc.expandAt, cc.expandAt + 0.45, 'pop') : 0;
    const ap = has('approveAt') ? K.p(t, cc.approveAt, cc.approveAt + 0.45) : 0;
    SESS.forEach(s => {
      const el = E.rows[s.id], ob = L.B.order[s.id], oa = L.A.order[s.id];
      let alpha = K.p(t, cc.appearAt + oa * 0.018, cc.appearAt + oa * 0.018 + 0.3, 'out');
      const q = has('regroupAt') ? K.p(t, cc.regroupAt + ob * 0.035, cc.regroupAt + ob * 0.035 + 0.65, 'inOut') : 0;
      let pos = lerpPos(L.A.rows[s.id], L.B.rows[s.id], q), sy = 1;
      const crosses = L.A.rows[s.id].x !== L.B.rows[s.id].x;   // rows dim while in flight; column-crossers dim hardest
      alpha *= 1 - (crosses ? 0.7 : 0.3) * Math.sin(Math.PI * q);
      if (s.status === 'done') {
        if (has('resolveAt')) { const fo = K.p(t, cc.resolveAt + ob * 0.025, cc.resolveAt + ob * 0.025 + 0.4, 'in'); alpha *= 1 - fo; sy = 1 - 0.35 * fo; }
        if (resP > 0) { pos = L.R.rows[s.id]; alpha = resP; sy = 1; }
      } else {
        if (rs > 0) pos = lerpPos(pos, lerpPos(L.W.rows[s.id], L.W1.rows[s.id], ex), rs);
        alpha *= 1 - resP;
      }
      css(el, { transform: `translate(${pos.x.toFixed(1)}px, ${pos.y.toFixed(1)}px) scaleY(${sy.toFixed(3)})`, opacity: alpha.toFixed(3), height: pos.h.toFixed(1) + 'px', visibility: alpha > 0.004 ? 'visible' : 'hidden' });
    });
    // priority 1 detail + approval
    css(E.ask, { opacity: ex.toFixed(3), visibility: ex > 0.01 ? 'visible' : 'hidden' });
    css(E.ac, { opacity: (1 - ap).toFixed(3) }); css(E.ad, { opacity: ap.toFixed(3), visibility: ap > 0.01 ? 'visible' : 'hidden' });
    css(E.ln1, { opacity: (1 - 0.35 * ap).toFixed(3) });   // the ask line stays; the answer lives in the detail
    css(E.gl1, { background: K.mix(C.need, C.run, ap), borderColor: K.mix(C.need, C.run, ap) }); css(E.pr1, { opacity: (1 - ap).toFixed(3) });
    // group headers
    const hA = (1 - (has('regroupAt') ? K.p(t, cc.regroupAt, cc.regroupAt + 0.35) : 0));
    const hB = (has('regroupAt') ? K.p(t, cc.regroupAt + 0.6, cc.regroupAt + 1.0) : 0) * (1 - (has('resolveAt') ? K.p(t, cc.resolveAt, cc.resolveAt + 0.4) : 0));
    const hW = (has('resolveAt') ? K.p(t, cc.resolveAt + 0.45, cc.resolveAt + 0.85) : 0) * (1 - resP);
    const hR = resP;
    const setHeads = (key, alpha, posOf) => E.heads[key].forEach((h, i) => { const g = L[key].groups[i]; const p = posOf ? posOf(g, i) : g; const a = alpha * K.p(t, cc.appearAt, cc.appearAt + 0.3, 'out'); css(h, { transform: `translate(${p.x.toFixed(1)}px, ${p.y.toFixed(1)}px)`, opacity: a.toFixed(3), visibility: a > 0.004 ? 'visible' : 'hidden' }); });
    setHeads('A', hA); setHeads('B', hB); setHeads('R', hR);
    setHeads('W', hW, (g, i) => { const g1 = L.W1.groups[i]; return { x: K.lerp(g.x, g1.x, ex), y: K.lerp(g.y, g1.y, ex) }; });
    // tabs + grouping label
    const tick = has('resolveAt') ? K.p(t, cc.resolveAt + 0.3, cc.resolveAt + 1.0) : 0;
    text(E.wbCount, String(Math.round(K.lerp(20, 10, tick)))); const rc = Math.round(K.lerp(0, 10, tick)); text(E.resCount, rc ? ' ' + rc : '');
    const resActive = resP > 0.5; if (E.__ra !== resActive) { E.__ra = resActive; E.tabWb.classList.toggle('on', !resActive); E.tabRes.classList.toggle('on', resActive); }
    text(E.grpBy, rgHead > 0.5 ? 'Grouped by component ▾' : 'Grouped by project ▾');
    css(E.grpBy, { opacity: (rgHead < 0.5 ? 1 - rgHead * 1.6 : 0.2 + (rgHead - 0.5) * 1.6).toFixed(3) });
  };

  // ---------- automations ----------
  // au: { t, name, schedule, deliver, access, streams, stripeOn, stripeConn, active, listAt, glanceAt }
  Sheet.auto = function (au) {
    const t = au.t, inAt = (at, d = 0.35) => at == null ? 0 : K.p(t, at, at + d, 'out');
    const show = (el, p, dy = 6) => css(el, { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * dy).toFixed(1)}px)`, visibility: p > 0.004 ? 'visible' : 'hidden' });
    show(E.fields.name, inAt(au.name)); show(E.fields.schedule, inAt(au.schedule)); show(E.fields.deliver, inAt(au.deliver)); show(E.fields.access, inAt(au.access));
    show(E.fields.streams, inAt(au.streams));
    E.sRows.forEach((r, i) => show(r, i < 3 ? inAt(au.streams == null ? null : au.streams + 0.12 + i * 0.12) : inAt(au.streams == null ? null : au.streams + 0.5)));
    const so = inAt(au.stripeOn, 0.3); if (E.stripeSw.__on !== (so > 0.5)) { E.stripeSw.__on = so > 0.5; E.stripeSw.classList.toggle('on', so > 0.5); }
    const sc = inAt(au.stripeConn, 0.4); text(E.stripeFr, sc > 0.5 ? 'connected just now' : D.automation.streams[3].fresh); css(E.stripeFr, { opacity: (sc < 0.5 ? 1 - sc * 1.6 : 0.2 + (sc - 0.5) * 1.6).toFixed(3), color: sc > 0.5 ? C.text : C.sec });
    text(E.gStripeFr, 'connected just now');
    show(E.aLink, inAt(au.access == null ? null : au.access + 0.3)); show(E.fields.status, inAt(au.access == null ? null : au.access + 0.4));
    const ac = inAt(au.active, 0.4); css(E.status1, { opacity: (1 - ac).toFixed(3) }); css(E.status2, { opacity: ac.toFixed(3), visibility: ac > 0.01 ? 'visible' : 'hidden' });
    const li = inAt(au.listAt, 0.45); css(E.aNew, { opacity: li.toFixed(3), transform: `translateY(${((1 - li) * 8).toFixed(1)}px)`, visibility: li > 0.004 ? 'visible' : 'hidden' });
    const gl = inAt(au.glanceAt, 0.4);
    css(E.aDraft, { opacity: (1 - gl).toFixed(3), visibility: gl < 0.996 ? 'visible' : 'hidden' });
    css(E.aGlance, { opacity: gl.toFixed(3), visibility: gl > 0.004 ? 'visible' : 'hidden', transform: `translateY(${((1 - gl) * 8).toFixed(1)}px)` });
    E.gRows.forEach((r, i) => { const p = au.glanceAt == null ? 0 : K.p(t, au.glanceAt + 0.1 + i * 0.05, au.glanceAt + 0.4 + i * 0.05, 'out'); css(r, { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * 6).toFixed(1)}px)` }); });
  };

  // ---------- entry ----------
  // st: { view: 'cc'|'auto'|'pay', alpha, fade: {cc, auto, pay} }
  Sheet.render = function (st) {
    if (!st) { css(Island.sheetEl(), { display: 'none' }); return; }
    css(Island.sheetEl(), { display: 'block', opacity: (st.alpha == null ? 1 : st.alpha).toFixed(3) });
    for (const k of ['cc', 'auto', 'pay']) { const a = st.fade[k] || 0; css(E[k], { opacity: a.toFixed(3), display: a > 0.004 ? 'block' : 'none' }); }
    if (st.cc) Sheet.cc(st.cc);
    if (st.auto) Sheet.auto(st.auto);
  };
  window.Sheet = Sheet;
})();
