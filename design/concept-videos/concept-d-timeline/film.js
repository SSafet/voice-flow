// Concept D — Timeline: the film. Builds the DOM once; renderAt(t) is a pure function of t.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const s2 = T.s2, s3 = T.s3, s4 = T.s4, s5 = T.s5, s6 = T.s6, s7 = T.s7, s8 = T.s8;
  const INK2 = '#57524A', INK3 = '#736D63', RED = '#D6442C', BLUE = '#2E56C9';
  const esc = Motion.esc;
  window.DURATION = T.end;

  // ================= build =================
  Desktop.build(); Paper.build(); Slip.build();
  Reader.build({ reply: s3.read, article: s3.read2 });
  Sheet.build(); Cap.build();
  const $ = id => document.getElementById(id);
  const E = { cursor: $('cursor'), ripple: $('ripple'), hud: $('hud'), cap: $('caption'), capL: $('caption').querySelector('.cap-l'), capS: $('caption').querySelector('.cap-s'), title: $('title'), end: $('endcard'), chip: $('v-chip'), dots: $('dots') };
  E.title.innerHTML = `<div class="t-name">VoiceFlow</div><div class="t-concept">Concept D — Timeline</div><div class="t-thesis">Your day, and every agent in it.</div>
    <div class="t-line"><i class="l" style="right:auto;width:7.2%"></i><i class="l" style="left:9.4%"></i><svg class="brk" style="left:7.2%" width="14" height="10" viewBox="0 0 14 10"><path d="M0 5 L4 5 L6 1 L9 9 L11 5 L14 5" fill="none" stroke="rgba(28,26,23,.45)" stroke-width="1.2"/></svg>${[[0, '21:00', 'first'], [14.0, '06:00'], [35.5, '07:00'], [57.0, '08:00'], [78.5, '09:00']].map(([u, l, c]) => `<i class="tk" style="left:${u}%"></i><span class="tl${c ? ' ' + c : ''}" style="left:${u}%">${l}</span>`).join('')}<i class="tk" style="left:100%"></i><i class="nw" style="left:93.2%"></i><span class="nl" style="left:93.2%">09:41</span></div>`;
  E.tParts = [...E.title.children];
  E.end.innerHTML = D.endCard.map(l => `<div class="e-line">${esc(l)}</div>`).join('') + `<div class="e-foot">VoiceFlow · Concept D — Timeline</div>`;
  E.eLines = [...E.end.querySelectorAll('.e-line')]; E.eFoot = E.end.querySelector('.e-foot');

  // ================= measurements =================
  const M = {};
  { const r = Desktop.screenRect(Desktop.$.nCaret); M.caret = { x: r.x, cy: r.y + r.h / 2 }; }
  { Desktop.setTab('article'); const spans = Desktop.$.artSel.querySelectorAll('span');
    const r0 = spans[0].getClientRects()[0], rr = spans[2].getClientRects(); const r2 = rr[rr.length - 1];
    M.selStart = [r0.left + 1 - G.CHROME.x, r0.top + r0.height / 2 - G.CHROME.y]; M.selEnd = [r2.right + 1 - G.CHROME.x, r2.top + r2.height / 2 - G.CHROME.y];
    M.selStart = [M.selStart[0] + G.CHROME.x, M.selStart[1] + G.CHROME.y]; M.selEnd = [M.selEnd[0] + G.CHROME.x, M.selEnd[1] + G.CHROME.y]; Desktop.setTab('plan'); }
  { const r = Desktop.screenRect(Desktop.$.tabPlan); M.tabPlan = [r.x + r.w / 2, r.y + r.h / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tCaret); M.termCaret = [r.x + 4, r.y + r.h / 2]; }
  M.sheet = Paper.rect('sheet', Sheet.height(s4.clickWb + 1)); M.row1 = Sheet.rowScreen(1, 'component-resolved', M.sheet);

  // ================= surface states =================
  const SURF = [
    [0, 'tab', 0], [s2.open, 'slip', 0.4], [s2.deliver + 0.35, 'chip', 0.35], [s2.receipt[1], 'tab', 0.35],
    [s3.hold, 'slip', 0.4], [s3.morph, 'reader', 0.45], [s3.fold, 'tab', 0.4], [s3.read2At, 'reader', 0.4], [s3.barge, 'slip', 0.35],
    [s4.open, 'sheet', 0.55], [s5.close, 'tab', 0.45],
    [s6.c0, 'strip', 0.4], [s7.receipt, 'receipt', 0.5], [s7.copy, 'stub', 0.01], [s7.chip[0], 'chip', 0.35], [s7.chip[1], 'tab', 0.35],
  ];
  const HEIGHTS = { strip: t => Cap.stripHeight(t), receipt: () => Cap.RECEIPT_H, sheet: t => Sheet.height(t) };
  const DOTMODES = [[0, 'rest'], [s2.hold, 'listen'], [s2.release, 'rest'], [s3.hold, 'listen'], [s3.think, 'think'], [s3.morph + 0.4, 'speak'], [s3.read.end + 0.3, 'rest'],
    [s3.read2At, 'speak'], [s3.barge, 'listen'], [s3.release3, 'think'], [s4.rowsIn + 0.5, 'rest'],
    [s4.hold1, 'listen'], [s4.release1, 'think'], [s4.regroupAnim + s4.regroupDur, 'rest'], [s4.hold2, 'listen'], [s4.release2, 'think'], [s4.resolveAnim + s4.resolveDur, 'rest'],
    [s4.hold3, 'listen'], [s4.release3, 'think'], [s4.approved + 0.4, 'rest'],
    [s5.hold, 'listen'], [s5.release, 'think'], [s5.fAccess + 0.4, 'rest'], [s5.hold2, 'listen'], [s5.release2, 'think'], [s5.stripeOn + 0.4, 'rest'], [s5.hold3, 'listen'], [s5.release3, 'think'], [s5.active + 0.4, 'rest'],
    [s6.c0, 'record'], [s7.stop, 'rest']];
  const unreadAt = t => t >= T.title.b && t < s4.approved;

  // ================= scene 2: dictation tokens =================
  function tokensS2(t) {
    const out = [], W = s2.u1.words;
    for (let i = 0; i < W.length; i++) {
      const w = W[i]; if (t < w.at) break;
      const tok = { key: 'a' + i, text: w.w, born: w.at, commit: w.at + 0.9 };
      if (i === 0 && t >= s2.e2Insert) out.push(tok), out.push({ key: 'ins2', text: 'first-run', inserted: s2.e2Insert });
      if (i === 1) {
        if (t < s2.rev1) { out.push({ key: 'a1', text: 'on', born: w.at, commit: 99 }); if (t >= w.at + 0.24) out.push({ key: 'a1b', text: 'boarding', born: w.at + 0.24, commit: 99 }); continue; }
        tok.text = 'onboarding'; tok.swap = { at: s2.rev1, from: 'on boarding' }; tok.commit = s2.rev1 + 0.45;
        if (t >= s2.e2Strike) tok.struck = { at: s2.e2Strike, collapse: s2.e2Collapse };
      }
      if (i === 8) { if (t < s2.rev2) tok.text = 'desk'; else { tok.swap = { at: s2.rev2, from: 'desk' }; tok.commit = s2.rev2 + 0.45; } }
      if (i === 0 && t >= s2.e2Insert) continue;
      out.push(tok);
      if (i === 9 && t >= s2.e1Apply) out.push({ key: 'ins1', text: 'ask', inserted: s2.e1Apply });
    }
    const U = s2.u3.words;
    for (let i = 0; i < U.length; i++) {
      const w = U[i]; if (t < w.at) break;
      const tok = { key: 'c' + i, text: w.w, born: w.at, commit: w.at + 0.9 };
      if (i === 3) { if (t >= s2.swap) { tok.text = 'Pantrella'; tok.swap = { at: s2.swap, from: 'pantry la' }; } else tok.lowConf = true; }
      if (i === 4) { if (t >= s2.swap) continue; tok.lowConf = true; }
      out.push(tok);
    }
    return out;
  }
  function newestS2(t) {
    const list = [];
    for (const w of s2.u1.words) if (t >= w.at) list.push(['a' + s2.u1.words.indexOf(w), w.at]);
    for (let i = 0; i < s2.u3.words.length; i++) if (t >= s2.u3.words[i].at) list.push([i === 4 && t >= s2.swap ? 'c3' : 'c' + i, s2.u3.words[i].at]);
    return list;
  }
  const DEST = `<span style="color:${INK3}">Notion · PT-141 · Description</span>`;
  function cmdS2(t) {
    const edit = (u, hide) => ({ pre: `<span class="k">EDIT ›</span>`, html: Motion.stream(u, t, 'w'), alpha: K.win(t, u.start - 0.25, hide + 0.3, 0.25, 0.3) });
    if (t >= s2.e1.start - 0.25 && t < s2.e1Hide + 0.3) return edit(s2.e1, s2.e1Hide);
    if (t >= s2.learnt[0] && t < s2.learnt[1] + 0.3) return { html: `<span class="g">✓</span>${esc(D.dictation.misheard.learnt)}`, alpha: K.win(t, s2.learnt[0], s2.learnt[1] + 0.3, 0.25, 0.3) };
    if (t >= s2.e2.start - 0.25 && t < s2.e2Hide + 0.3) return edit(s2.e2, s2.e2Hide);
    return { html: DEST, alpha: 1 };
  }
  function slipS2(t) {
    if (t < s2.open || t > s2.deliver + 0.5) return null;
    const st = { t, tokens: tokensS2(t), caret: t < s2.release, cmd: cmdS2(t), exit: K.p(t, s2.deliver, s2.deliver + 0.35, 'in') };
    st.scroll = api => {
      const list = newestS2(t); if (!list.length) return 0;
      const target = k => Math.max(0, api.lineOf(k) - 1);
      const [nk, nb] = list[list.length - 1], pk = list.length > 1 ? list[list.length - 2][0] : nk;
      let line = K.lerp(target(pk), target(nk), K.p(t, nb, nb + 0.45, 'inOut'));
      const last = Math.max(0, api.lastLine() - 1);
      if (t >= s2.e2Return) line = K.lerp(0, last, K.p(t, s2.e2Return, s2.e2Return + 0.5, 'inOut'));
      else if (t >= s2.e2Scroll) line = K.lerp(last, 0, K.p(t, s2.e2Scroll, s2.e2Scroll + 0.5, 'inOut'));
      return line;
    };
    if (t >= s2.click2 && t < s2.click3 + 0.4) {
      const a = K.p(t, s2.click2, s2.click2 + 0.25, 'out') * (1 - K.p(t, s2.click3 + 0.12, s2.click3 + 0.4));
      st.picker = { x: M.picker ? M.picker[0] : 0, y: M.picker ? M.picker[1] : 0, alpha: a, rows: D.dictation.misheard.alternatives, cur: t >= s2.ptr3 + 0.35 ? 0 : 1 };
    }
    return st;
  }
  // ================= scene 3: the ask, the barge-in =================
  function slipS3(t) {
    if (t >= s3.hold && t < s3.morph + 0.45) {
      const routed = t >= s3.route, dim = t > s3.release + 0.3;
      const toks = s3.ask.words.filter(w => t >= w.at).map((w, i) => ({ key: 'q' + i, text: w.w, born: w.at, commit: w.at + 0.9, tint: i === 0 && routed ? BLUE : null, dim: dim && !(i === 0) }));
      let cmd;
      if (t >= s3.thinkLine) cmd = { html: `<span class="b sans">${esc(D.flora.thinking)}</span>`, alpha: K.p(t, s3.thinkLine, s3.thinkLine + 0.3) };
      else if (routed) cmd = { html: `<span class="b">→ FLORA</span>`, alpha: 1 };
      else cmd = { html: DEST, alpha: 1 };
      return { t, tokens: toks, caret: t < s3.release, cmd, scroll: api => Math.max(0, api.lastLine() - 1) };
    }
    if (t >= s3.barge && t < s4.open + 0.6) {
      const toks = s3.show.words.filter(w => t >= w.at).map((w, i) => ({ key: 'm' + i, text: w.w, born: w.at, commit: w.at + 0.9 }));
      return { t, tokens: toks, caret: t < s3.release3, cmd: { html: `<span class="b">→ FLORA</span>`, alpha: 1 }, scroll: () => 0 };
    }
    return null;
  }
  const slipState = t => slipS2(t) || slipS3(t);
  function readerState(t) {
    if (t >= s3.morph && t < s3.fold + 0.45) return { t, prog: 'reply', tag: 'FLORA', tagColor: BLUE, introAt: s3.morph + 0.3 };
    if (t >= s3.read2At && t < s3.barge + 0.4) return { t: Math.min(t, s3.barge), prog: 'article', tag: 'ARTICLE', tagColor: INK2, introAt: s3.read2At + 0.2 };
    return null;
  }
  // ================= scene 4/5: the sheet's voice line =================
  const CMDS = [
    { u: s4.regroup, work: 'Grouping by component…', until: s4.regroupAnim + s4.regroupDur + 0.4 },
    { u: s4.resolve, work: 'Resolving 10 finished sessions…', until: s4.resolveAnim + s4.resolveDur + 0.5 },
    { u: s4.approve, work: 'Approving · migration 0042 on staging…', until: s4.approved + 0.9 },
    { u: s5.say, work: 'Drafting the automation…', until: s5.fAccess + 0.6, wake: true },
    { u: s5.stripe, work: 'Adding Stripe payouts…', until: s5.stripeOn + 0.6 },
    { u: s5.enable, work: 'Turning it on…', until: s5.active + 0.8 },
  ];
  function footState(t) {
    for (const c of CMDS) {
      if (t < c.u.start - 0.3 || t >= c.until + 0.3) continue;
      if (t < c.u.end + 0.35) {
        const words = Motion.stream(c.u, t, 'w', c.wake && t >= c.u.words[1].at + 0.15 ? BLUE : null);
        return { html: words, color: RED, alpha: K.p(t, c.u.start - 0.3, c.u.start, 'out') };
      }
      return { html: `<span class="fs">${esc(c.work)}</span>`, color: BLUE, alpha: 1 - K.p(t, c.until, c.until + 0.3) };
    }
    return null;
  }

  // ================= pointer =================
  const { Path } = Motion;
  const geoS = p => Cap.toScreen(p);
  const labelS = geoS(Cap.geo.label), tueS = (() => { const r = Cap.geo.tue; return { x: r.x + G.CHROME.x, y: r.y + G.CHROME.y + G.CHROME_HEAD, w: r.w, h: r.h }; })();
  const PTR = new Path([
    { t: 0, x: 1180, y: 660, dur: 0 },
    { t: s2.ptr, x: M.caret.x + 8, y: M.caret.cy + 1, dur: 0.9 },
    { t: s2.click + 0.5, x: M.caret.x + 260, y: M.caret.cy + 150, dur: 0.8 },
    { t: s2.ptr2, x: 0, y: 0, dur: 0.85 },        // 'pantry la' token (filled after measuring)
    { t: s2.ptr3, x: 0, y: 0, dur: 0.5 },         // picker row 0 (filled after measuring)
    { t: s2.click3 + 0.6, x: 1330, y: 840, dur: 0.9 },
    { t: s3.ptrA, x: M.selStart[0], y: M.selStart[1], dur: 0.8 },
    { t: s3.drag[0], dur: s3.drag[1] - s3.drag[0], fn: p => { const e = K.ease.inOut(p); return [K.lerp(M.selStart[0], M.selEnd[0], e), K.lerp(M.selStart[1], M.selEnd[1], e)]; } },
    { t: s3.drag[1] + 0.5, x: M.selEnd[0] + 70, y: M.selEnd[1] + 120, dur: 0.7 },
    { t: s4.ptrRes, x: 0, y: 0, dur: 0.8 },       // Resolved tab (filled)
    { t: s4.ptrWb, x: 0, y: 0, dur: 0.6 },        // Workbench tab (filled)
    { t: s4.ptrP1, x: M.row1.x, y: M.row1.y, dur: 0.9 },
    { t: s4.approved + 0.8, x: 1480, y: 960, dur: 1.0 },
    { t: s6.ptrTab, x: M.tabPlan[0], y: M.tabPlan[1], dur: 0.85 },
    { t: s6.ptrCard, dur: 1.0, x: geoS(Cap.circlePoint(0, 0))[0], y: geoS(Cap.circlePoint(0, 0))[1] },
    { t: s6.circle[0], dur: s6.circle[1] - s6.circle[0], fn: p => geoS(Cap.circlePoint(p, 1)) },
    { t: s6.ptrArrow, x: geoS(Cap.arrowPoint(0, 0))[0], y: geoS(Cap.arrowPoint(0, 0))[1], dur: 0.8 },
    { t: s6.arrow[0], dur: s6.arrow[1] - s6.arrow[0], fn: p => geoS(Cap.arrowPoint(K.ease.inOut(p), K.p(p, 0.9, 1))) },
    { t: s6.arrow[1] + 0.4, x: geoS(Cap.geo.arrow.b)[0] + 90, y: geoS(Cap.geo.arrow.b)[1] + 120, dur: 0.6 },
    { t: s6.ptrMid, x: 1000, y: 640, dur: 0.8 },
    { t: s6.ptrLabel, x: labelS[0] + 190, y: labelS[1] + 30, dur: 1.0 },
    { t: s6.ptrCard2, x: tueS.x + tueS.w + 50, y: tueS.y + tueS.h / 2, dur: 1.0 },
    { t: s6.ptrAway, x: 1380, y: 900, dur: 1.0 },
  ]);
  const CLICKS = [s2.click, s2.click2, s2.click3, s4.clickRes, s4.clickWb, s4.clickP1, s6.clickTab];

  // ================= furniture =================
  const HUD = [
    [s3.hudTab, ['⌘', '⇥'], '', 1.2], [s3.hudF8, ['F8'], 'read aloud', 1.6], [s5.hudEsc, ['esc'], '', 1.2],
    [s6.hud, ['fn', 'fn'], 'talk + mark', 1.8], [s6.hudTab1, ['⌘', '⇥'], '', 1.2], [s6.hudTab2, ['⌘', '⇥'], '', 1.2], [s6.hudStop, ['fn', 'fn'], 'stop', 1.4],
    [s7.hudCopy, ['⌘', 'C'], 'copy for any agent', 1.6], [s7.hudTab, ['⌘', '⇥'], '', 1.2], [s7.hudPaste, ['⌘', 'V'], '', 1.2],
  ];
  const CAPS = [
    [T.rest.cap, 'At rest', 'Three dots. Always there, never in the way.'],
    [s2.cap, 'Dictation', 'See every word as you say it. Fix anything by saying so.'],
    [s3.cap, 'FLORA', 'Ask about every agent you run — and hear the answer.'],
    [s3.cap2, 'Reader', 'Every voice, same reader.'],
    [s4.cap, 'Control center', 'Your day, and every agent in it — regroup and resolve by voice.'],
    [s5.cap, 'Automations', 'Standing work, drafted by talking.'],
    [s6.cap, 'Talk + mark', 'Marks that stay on the thing you mean.'],
    [s6.cap2, 'Talk + mark', 'They scroll with the page and hide with the window.'],
    [s7.cap, 'One payload', 'One payload, any agent.'],
  ];
  function renderHud(t) {
    let hold = null; for (const h of T.holds) if (t >= h[0] - 0.05 && t < h[1] + 0.35) hold = h;
    if (hold) {
      const a = K.win(t, hold[0] - 0.05, hold[1] + 0.35, 0.2, 0.3);
      html(E.hud, `<span class="kc${t < hold[1] ? ' on' : ''}">fn</span><span class="lbl">${t < hold[1] ? 'hold · talk' : 'release'}</span>`);
      css(E.hud, { visibility: 'visible', opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 6).toFixed(1)}px)` }); return;
    }
    let cur = null; for (const h of HUD) if (t >= h[0] && t < h[0] + h[3] + 0.3) cur = h;
    if (!cur) { css(E.hud, { visibility: 'hidden' }); return; }
    const [t0, keys, label, dur] = cur; const a = K.win(t, t0, t0 + dur + 0.3, 0.2, 0.3);
    const pressed = t >= t0 + 0.05 && t < t0 + 0.35;
    html(E.hud, keys.map((k, i) => `<span class="kc${pressed && i === keys.length - 1 ? ' on' : ''}">${k}</span>`).join('') + (label ? `<span class="lbl">${esc(label)}</span>` : ''));
    css(E.hud, { visibility: 'visible', opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 6).toFixed(1)}px)` });
  }
  function renderCaption(t) {
    let cur = null, prev = null; for (const c of CAPS) if (t >= c[0]) { prev = cur; cur = c; }
    if (!cur || t < T.title.b || t >= s8.fade) { css(E.cap, { visibility: 'hidden' }); return; }
    const a = K.p(t, cur[0], cur[0] + 0.35, 'out');
    text(E.capL, cur[1]); text(E.capS, cur[2]);
    const sa = K.win(t, cur[0], cur[0] + 3.4, 0.35, 0.45);
    css(E.cap, { visibility: 'visible' });
    css(E.capL, { opacity: (prev && prev[1] === cur[1] ? 1 : a).toFixed(3) });
    css(E.capS, { opacity: sa.toFixed(3), transform: `translateY(${((1 - a) * -6).toFixed(1)}px)`, visibility: sa > 0 ? 'visible' : 'hidden' });
  }
  function renderCursor(t) {
    const hide = t < T.title.b || t >= s8.fade;
    if (hide) { css(E.cursor, { visibility: 'hidden' }); css(E.ripple, { visibility: 'hidden' }); return; }
    const [x, y] = PTR.at(t);
    css(E.cursor, { visibility: 'visible', transform: `translate(${(x - 4).toFixed(1)}px, ${(y - 2).toFixed(1)}px)` });
    let rp = 0, rt = 0; for (const c of CLICKS) if (t >= c && t < c + 0.4) { rp = (t - c) / 0.4; rt = c; }
    if (rp > 0) { const [cx, cy] = PTR.at(rt); css(E.ripple, { visibility: 'visible', transform: `translate(${(cx - 20).toFixed(1)}px, ${(cy - 20).toFixed(1)}px) scale(${(0.2 + 0.8 * K.ease.out(rp)).toFixed(3)})`, opacity: (1 - rp).toFixed(3) }); }
    else css(E.ripple, { visibility: 'hidden' });
  }
  function renderTitle(t) {
    if (t >= T.title.b) { css(E.title, { visibility: 'hidden' }); return; }
    css(E.title, { visibility: 'visible' });
    E.tParts.forEach((el, i) => { const a = K.p(t, 0.3 + i * 0.4, 0.9 + i * 0.4, 'out'); css(el, { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 6).toFixed(1)}px)` }); });
  }
  function renderEnd(t) {
    const a = K.p(t, s8.fade, s8.fade + 0.7);
    if (a <= 0) { css(E.end, { visibility: 'hidden' }); return; }
    css(E.end, { visibility: 'visible', opacity: a.toFixed(3) });
    E.eLines.forEach((el, i) => { const p = K.p(t, s8.lines + i * 0.45, s8.lines + i * 0.45 + 0.45, 'out'); css(el, { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * 8).toFixed(1)}px)` }); });
    const p = K.p(t, s8.name, s8.name + 0.5, 'out'); css(E.eFoot, { opacity: p.toFixed(3) });
  }

  // ================= desktop state =================
  const front = t => t < s3.front ? 'notion' : t < s6.front1 ? 'chrome' : t < s6.front2 ? 'notion' : t < s7.front ? 'chrome' : 'term';
  const SWITCHES = [s3.front, s6.front1, s6.front2, s7.front];
  const tab = t => t < s3.front - 0.1 ? 'plan' : t < s6.clickTab + 0.05 ? 'article' : 'plan';
  function scroll(t) { if (t < s6.scroll1[0]) return 0; if (t < s6.scroll2[0]) return 200 * K.p(t, s6.scroll1[0], s6.scroll1[1], 'inOut'); return 200 * (1 - K.p(t, s6.scroll2[0], s6.scroll2[1], 'inOut')); }
  const sel = t => t < s3.drag[0] || t >= s4.open ? 0 : K.ease.inOut(K.clamp((t - s3.drag[0]) / (s3.drag[1] - s3.drag[0])));
  function notionText(t) { const f = D.dictation.final; if (t < s2.deliver + 0.1) return ''; return f.slice(0, Math.round(f.length * K.p(t, s2.deliver + 0.1, s2.deliver + 1.1, 'linear'))); }
  const CHIP2 = `<span class="ok">✓</span>${esc(D.dictation.receipt)}`, CHIP7 = `<span class="ok">✓</span>${esc(D.handoff.copied)}`;

  // ================= renderAt =================
  window.renderAt = function (t) {
    const fr = front(t);
    Desktop.setFront(fr);
    { let ls = 0; for (const s of SWITCHES) if (t >= s) ls = s; const p = ls ? K.p(t, ls, ls + 0.22, 'out') : 1; css(Desktop.$[fr], { transform: `scale(${(0.992 + 0.008 * p).toFixed(4)})` }); for (const k of ['notion', 'chrome', 'term']) if (k !== fr) css(Desktop.$[k], { transform: 'none' }); }
    Desktop.setTab(tab(t)); Desktop.setPlanScroll(scroll(t)); Desktop.setArticleSelection(sel(t));
    Desktop.setNotion(notionText(t), t >= s2.click && t < s3.front, t < s2.click);
    Desktop.setTermPaste(t >= s7.paste ? D.handoff.pastedLine : '', true);
    Cap.renderMarks(t);
    // the signature object
    const surf = Paper.stateAt(SURF, t, HEIGHTS); window.__surfState = surf.state;
    const viewRects = { slip: surf.rectOf('slip'), reader: surf.rectOf('reader'), sheet: surf.rectOf('sheet'), strip: surf.rectOf('strip'), receipt: surf.rectOf('receipt'), chip: surf.rectOf('chip') };
    const covered = t < T.title.b || t >= s8.fade + 0.7;
    Paper.render(surf, viewRects, covered);
    if (surf.alphas.slip > 0) Slip.render(slipState(t)); else Slip.render(null);
    Reader.render(surf.alphas.reader > 0 ? readerState(t) : null);
    if (surf.alphas.sheet > 0) Sheet.render({ t, foot: footState(t) });
    if (surf.alphas.strip > 0) Cap.renderStrip(t, [s6.a1, s6.a2, s6.a3, s6.a4]);
    html(E.chip, t < s5.cap ? CHIP2 : CHIP7);
    Cap.renderTear(t, viewRects.receipt, M.termCaret);
    // ink trace along the bottom edge while listening / recording
    const dm = Motion.modeAt(DOTMODES, t);
    const listening = dm.mode === 'listen' || dm.mode === 'record';
    const traceA = listening ? K.p(t, dm.since, dm.since + 0.3) : (dm.prev === 'listen' || dm.prev === 'record') ? 1 - K.p(t, dm.since, dm.since + 0.3) : 0;
    Paper.renderTrace(t, surf.rect.w, traceA * (surf.state === 'tab' ? 0 : 1));
    Paper.renderDots(t, dm, unreadAt(t), dm.mode === 'speak' ? Paper.ticks(t) : null, covered);
    renderCursor(t); renderHud(t); renderCaption(t); renderTitle(t); renderEnd(t);
  };

  // ---- fill the measured pointer targets (renderAt is pure, so probing is safe) ----
  { window.renderAt(s2.click2 - 0.05); const r = Slip.tokenScreenRect('c3'); PTR.segs[3].x = r.x + r.w * 0.45; PTR.segs[3].y = r.y + r.h * 0.6;
    M.picker = [r.x - 10, r.y + r.h + 6];
    window.renderAt(s2.ptr3 + 0.1); const pr = Slip.pickerRowRect(0); PTR.segs[4].x = pr.x + pr.w * 0.4; PTR.segs[4].y = pr.y + pr.h / 2;
    window.renderAt(s4.ptrRes + 0.1); const tr = Sheet.headTab('res'), tw = Sheet.headTab('wb'); PTR.segs[9].x = tr.x; PTR.segs[9].y = tr.y; PTR.segs[10].x = tw.x; PTR.segs[10].y = tw.y;
    window.renderAt(0); }
  window.FILM = { T, M, PTR };
})();
