// Concept B — Orbit: the film. Builds the DOM once, then renderAt(t) is a pure function of t.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const s2 = T.s2, s3 = T.s3, s4 = T.s4, s5 = T.s5, s6 = T.s6, s7 = T.s7, s8 = T.s8;
  const TEXT = '#EAF2FF', SEC = '#AFBCCE', CYAN = '#5CE1E6', VIOLET = '#9B8CFF', GREEN = '#7EE0A1';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  window.DURATION = T.end;

  // ================= build =================
  Desktop.build();
  Lens.build();
  Drum.build({ reply: D.flora.reply, article: D.flora.anyText.sentences });
  CC.build();
  Cap.build();
  const $ = id => document.getElementById(id);
  const E = { cursor: $('cursor'), ripple: $('ripple'), hud: $('hud'), cap: $('caption'), capL: $('caption').querySelector('.cap-l'), capS: $('caption').querySelector('.cap-s'), title: $('title'), end: $('endcard') };
  E.title.innerHTML = `<div class="t-name">VoiceFlow</div><div class="t-concept">Concept B — Orbit</div><div class="t-thesis">A companion that sits where you’re looking.</div>`;
  E.tParts = [...E.title.children];
  E.end.innerHTML = D.endCard.map(l => `<div class="e-line">${esc(l)}</div>`).join('') + `<div class="e-foot">VoiceFlow · Concept B — Orbit</div>`;
  E.eLines = [...E.end.querySelectorAll('.e-line')]; E.eFoot = E.end.querySelector('.e-foot');
  css(E.title, { zIndex: '35' }); css(E.end, { zIndex: '35' });

  // ================= measurements =================
  const M = {};
  { const r = Desktop.screenRect(Desktop.$.nCaret); M.caret = { x: r.x, cy: r.y + r.h / 2 }; }
  M.triadCaret = [M.caret.x + 18, M.caret.cy];
  M.LENS2 = { x: M.caret.x + 34, y: M.caret.cy - 242 };
  M.DRUM3 = { x: M.LENS2.x, bottom: M.caret.cy - 24 };
  { Desktop.setNotion(D.dictation.final, true, false); const r = Desktop.screenRect(Desktop.$.nCaret); M.caretEnd = { x: r.x, cy: r.y + r.h / 2 }; Desktop.setNotion('', false, true); }
  { // article selection: start of sentence 0, end of sentence 2
    const spans = Desktop.$.artSel.querySelectorAll('span');
    const r0 = spans[0].getClientRects()[0], rr = spans[2].getClientRects(); const r2 = rr[rr.length - 1];
    M.selStart = [r0.left + 1, r0.top + r0.height / 2]; M.selEnd = [r2.right + 1, r2.top + r2.height / 2];
    M.triadSel = [M.selEnd[0] + 22, M.selEnd[1]];
    M.DRUMB = { x: Math.max(360, Math.min(1920 - 760 - 40, M.triadSel[0] - 380)), bottom: M.triadSel[1] - 26 };
    M.LENSB = { x: Math.max(340, Math.min(1920 - 540 - 30, M.triadSel[0] - 270)), y: M.triadSel[1] + 28 };
  }
  { const r = Desktop.screenRect(Desktop.$.tabPlan); M.tabPlan = [r.x + r.w / 2, r.y + r.h / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tCaret); M.termCaret = [r.x + 4, r.y + r.h / 2]; }
  M.node1 = CC.nodePos(1, s4.ptrP1 + 5).pos;
  M.LENS4 = { x: 40, y: 760 }; M.LENS5 = { x: CC.CENTER[0] - 270, y: 892 };
  M.LENSREC = { x: 1010, y: 934, w: 580 };
  M.PACKET_TRIAD = [420 + 1080 + 24, 300 + 24];

  // ================= lens content =================
  const liftAmt = (t, a, swap, drop) => Math.min(K.p(t, a, a + 0.3, 'out'), 1 - K.p(t, swap, drop, 'inOut'));
  function tokensS2(t) {
    const out = []; const W = s2.u1.words;
    for (let i = 0; i < W.length; i++) {
      const w = W[i]; if (t < w.at) break;
      const tok = { key: 'a' + i, text: w.w, born: w.at, commit: w.at + 0.9 };
      if (i === 1) {
        if (t < s2.rev1.merge) { out.push({ key: 'a1', text: 'on', born: w.at, commit: 99 }); if (t >= w.at + 0.28) out.push({ key: 'a1b', text: 'boarding', born: w.at + 0.28, commit: 99 }); continue; }
        tok.swapAt = s2.rev1.merge; tok.commit = s2.rev1.merge + 0.5;
        if (t >= s2.e2Swap) { tok.text = 'first-run'; tok.swapAt = s2.e2Swap; tok.inserted = s2.e2Swap; }
      }
      if (i === 8) { if (t < s2.rev2.fix) tok.text = 'desk'; tok.swapAt = s2.rev2.fix; tok.commit = s2.rev2.fix + 0.5; }
      if (i <= 2) tok.lift = liftAmt(t, s2.e2Lift, s2.e2Swap, s2.e2Drop);
      if (i >= 6 && i <= 11) tok.lift = liftAmt(t, s2.e1Lift, s2.e1Swap, s2.e1Drop);
      out.push(tok);
      if (i === 9 && t >= s2.e1Swap) out.push({ key: 'ins', text: 'ask', born: s2.e1Swap, inserted: s2.e1Swap, lift: liftAmt(t, s2.e1Lift, s2.e1Swap, s2.e1Drop) });
    }
    const U = s2.u3.words;
    for (let i = 0; i < U.length; i++) {
      const w = U[i]; if (t < w.at) break;
      const tok = { key: 'c' + i, text: w.w, born: w.at, commit: w.at + 0.9 };
      if (i === 3) { if (t >= s2.swapWord) { tok.text = 'Pantrella'; tok.swapAt = s2.swapWord; tok.commit = s2.swapWord + 0.3; } else tok.lowConf = true; }
      if (i === 4) { if (t >= s2.swapWord) continue; tok.lowConf = true; }
      out.push(tok);
    }
    return out;
  }
  function newestS2(t) { // [key, born, prevKey]
    let list = [];
    for (let i = 0; i < s2.u1.words.length; i++) if (t >= s2.u1.words[i].at) list.push(['a' + i, s2.u1.words[i].at]);
    for (let i = 0; i < s2.u3.words.length; i++) if (t >= s2.u3.words[i].at) list.push([i === 4 && t >= s2.swapWord ? 'c3' : 'c' + i, s2.u3.words[i].at]);
    return list;
  }
  const streamHtml = (u, t, color) => u.words.filter(w => t >= w.at).map(w => `<span style="opacity:${K.p(t, w.at, w.at + 0.2).toFixed(2)}">${esc(w.w)}</span>`).join(' ');
  function footS2(t) {
    if (t >= s2.e1.start - 0.2 && t < s2.footFade + 0.3) return { glyph: '↺', html: streamHtml(s2.e1, t), lines: 2, alpha: K.win(t, s2.e1.start - 0.2, s2.footFade + 0.3, 0.25, 0.3) };
    if (t >= s2.learnt[0] && t < s2.learnt[1] + 0.3) return { glyph: '✓', glyphColor: GREEN, color: SEC, html: esc(D.dictation.misheard.learnt), lines: 1, alpha: K.win(t, s2.learnt[0], s2.learnt[1] + 0.3, 0.25, 0.3) };
    if (t >= s2.e2.start - 0.2 && t < s2.foot2Fade + 0.3) return { glyph: '↺', html: streamHtml(s2.e2, t), lines: 2, alpha: K.win(t, s2.e2.start - 0.2, s2.foot2Fade + 0.3, 0.25, 0.3) };
    return null;
  }
  function lensS2(t) {
    const open = K.p(t, s2.mic, s2.mic + 0.4, 'out'), fold = K.p(t, s2.deliver, s2.deliver + 0.45, 'in');
    if (open <= 0 || fold >= 1) return null;
    const tri = Orbit.pos(t);
    const st = { t, x: M.LENS2.x, y: M.LENS2.y, w: 540, lines: 3, rail: true, origin: tri, scale: (0.2 + 0.8 * open) * (1 - 0.95 * fold), alpha: open * (1 - fold),
      head: { tag: 'Notion · PT-141 Description', tagColor: CYAN, state: 'listening' }, tokens: tokensS2(t), foot: footS2(t) };
    st.post = () => {
      const list = newestS2(t); let scrollLine = 0;
      const lineOf = k => Lens.lineOf(k);
      const target = k => Math.max(0, lineOf(k) - 2);
      if (list.length) {
        const [nk, nb] = list[list.length - 1]; const pk = list.length > 1 ? list[list.length - 2][0] : nk;
        scrollLine = K.lerp(target(pk), target(nk), K.p(t, nb, nb + 0.45, 'inOut'));
        const last = Math.max(0, Lens.lastLine() - 2);
        if (t >= s2.e2Return) scrollLine = K.lerp(0, last, K.p(t, s2.e2Return, s2.e2Return + 0.5, 'inOut'));
        else if (t >= s2.e2Scroll) scrollLine = K.lerp(last, 0, K.p(t, s2.e2Scroll, s2.e2Scroll + 0.5, 'inOut'));
      }
      let picker;
      if (t >= s2.click2 && t < s2.click3 + 0.45) {
        const o = Lens.tokenOffset('c3');
        const a = K.p(t, s2.click2, s2.click2 + 0.35, 'out') * (1 - K.p(t, s2.click3 + 0.15, s2.click3 + 0.45));
        picker = { x: o.left - 14, y: o.top - 36 - scrollLine * 30, alpha: a, rows: D.dictation.misheard.alternatives, cur: t >= s2.click3 ? 0 : 1, shift: 30 * K.p(t, s2.click3, s2.click3 + 0.2, 'out') };
      }
      return { scrollLine, picker };
    };
    return st;
  }
  // commands: the lens after the wake (scene 3b → 5)
  const CMDS = [
    { u: s3.show, wake: false }, { u: s4.regroup }, { u: s4.resolve }, { u: s4.approve }, { u: s5.say, wake: true }, { u: s5.stripe }, { u: s5.enable },
  ];
  function cmdTokens(t) {
    let cur = -1;
    for (let i = 0; i < CMDS.length; i++) if (t >= CMDS[i].u.start - 0.3) cur = i;
    if (cur < 0) return [];
    const c = CMDS[cur], prev = CMDS[cur - 1];
    const out = [];
    if (t < c.u.start && prev) { const a = 1 - K.p(t, c.u.start - 0.3, c.u.start); prev.u.words.forEach((w, i) => out.push({ key: 'p' + (cur - 1) + '-' + i, text: w.w, born: -1, dim: true, alpha: a })); return out; }
    c.u.words.forEach((w, i) => { if (t < w.at) return; const tok = { key: 'k' + cur + '-' + i, text: w.w, born: w.at, commit: w.at + 0.9 }; if (c.wake && i === 0 && t >= c.u.words[1].at + 0.15) { tok.tint = VIOLET; tok.commit = null; } if (t > c.u.end + 1.2) { tok.dim = true; tok.commit = null; } out.push(tok); });
    return out;
  }
  function lensS3(t) {
    const tri = Orbit.pos(t);
    if (t >= s3.mic && t < s3.morph + 0.4) { // the ask
      const open = K.p(t, s3.mic, s3.mic + 0.4, 'out'), morph = K.p(t, s3.morph, s3.morph + 0.4, 'in');
      const routed = t >= s3.route, thinking = t >= s3.think;
      const toks = s3.ask.words.filter(w => t >= w.at).map((w, i) => { const tok = { key: 'q' + i, text: w.w, born: w.at, commit: w.at + 0.9 }; if (i === 0 && routed) { tok.tint = VIOLET; tok.commit = null; } if (thinking) tok.commit = null; return tok; });
      const head = routed ? { tag: 'FLORA', tagColor: VIOLET, state: thinking ? 'thinking' : 'listening' } : { tag: 'listening', tagColor: CYAN, state: '' };
      const foot = t >= s3.thinkLine ? { glyph: '◌', glyphColor: VIOLET, color: SEC, html: esc(D.flora.thinking), lines: 1, alpha: K.p(t, s3.thinkLine, s3.thinkLine + 0.3) } : null;
      return { t, x: M.LENS2.x, y: M.LENS2.y, w: 540 + 220 * morph, lines: 3, origin: tri, scale: 0.2 + 0.8 * open, alpha: open * (1 - morph), head, tokens: toks, foot, post: () => ({ scrollLine: Math.max(0, Lens.lastLine() - 2) }) };
    }
    return null;
  }
  function lensCmd(t) {
    if (t < s3.fold2 || t > s5.close + 0.7) return null;
    const tri = Orbit.pos(t);
    const open = K.p(t, s3.fold2 + 0.2, s3.fold2 + 0.6, 'out'), close = K.p(t, s5.close, s5.close + 0.6, 'in');
    if (open <= 0 || close >= 1) return null;
    // glide between anchors
    let pos;
    const g1 = K.p(t, s4.open, s4.open + 0.8, 'inOut'), g2 = K.p(t, s5.route, s5.route + 0.9, 'inOut');
    if (g2 > 0) pos = [K.lerp(M.LENS4.x, M.LENS5.x, g2), K.lerp(M.LENS4.y, M.LENS5.y, g2)];
    else pos = [K.lerp(M.LENSB.x, M.LENS4.x, g1), K.lerp(M.LENSB.y, M.LENS4.y, g1)];
    const thinking = (t >= s4.regroup.end + 0.1 && t < s4.regroupAnim + 0.9) || (t >= s4.resolve.end + 0.1 && t < s4.resolveAnim + 1.2) || (t >= s5.say.end + 0.1 && t < s5.fAccess + 0.3) || (t >= s3.show.end && t < s4.open + 0.8);
    const lines = g2 > 0.5 ? 2 : 3;
    return { t, x: pos[0], y: pos[1], w: 480 + 60 * g2, lines, origin: tri, scale: (0.2 + 0.8 * open) * (1 - 0.95 * close), alpha: open * (1 - close),
      head: { tag: 'FLORA', tagColor: VIOLET, state: thinking ? 'working' : 'listening' }, tokens: cmdTokens(t), post: () => ({ scrollLine: Math.max(0, Lens.lastLine() - (lines - 1)) }) };
  }
  // recording lens: follows the pointer
  const ANN = [s6.a1, s6.a2, s6.a3, s6.a4];
  function lensRec(t) {
    if (t < s6.c0 + 0.3 || t > s7.stop + 0.4) return null;
    const open = K.p(t, s6.c0 + 0.3, s6.c0 + 0.7, 'out'), close = K.p(t, s7.stop, s7.stop + 0.4, 'in');
    if (open <= 0 || close >= 1) return null;
    let cur = -1; for (let i = 0; i < ANN.length; i++) if (t >= ANN[i].start - 0.3) cur = i;
    const toks = [];
    if (cur >= 0) {
      const u = ANN[cur], prev = ANN[cur - 1];
      if (t < u.start && prev) prev.words.forEach((w, i) => toks.push({ key: 'r' + (cur - 1) + '-' + i, text: w.w, born: -1, dim: true, alpha: 1 - K.p(t, u.start - 0.3, u.start) }));
      else u.words.forEach((w, i) => { if (t >= w.at) toks.push({ key: 'r' + cur + '-' + i, text: w.w, born: w.at, commit: t > u.end + 1.5 ? null : w.at + 0.9, dim: t > u.end + 1.5 }); });
    }
    return { t, x: M.LENSREC.x, y: M.LENSREC.y, w: M.LENSREC.w, lines: 2, origin: open < 1 ? Orbit.pos(t) : Orbit.pos(s6.c0 + 0.7), scale: (0.2 + 0.8 * open) * (1 - 0.95 * close), alpha: open * (1 - close),
      head: { tag: 'Talk + mark', tagColor: CYAN, state: 'listening' }, tokens: toks, post: () => ({ scrollLine: Math.max(0, Lens.lastLine() - 1) }) };
  }
  const lensState = t => lensS2(t) || lensS3(t) || lensCmd(t) || lensRec(t);

  // ================= drum =================
  function drumState(t) {
    const tri = Orbit.pos(t);
    if (t >= s3.morph + 0.15 && t < s3.fold + 0.5) {
      const open = K.p(t, s3.morph + 0.15, s3.morph + 0.6, 'out'), fold = K.p(t, s3.fold, s3.fold + 0.5, 'in');
      if (fold >= 1) return null;
      return { t, x: M.DRUM3.x, bottom: M.DRUM3.bottom, tag: 'FLORA', tagColor: VIOLET, prog: 'reply', timeline: s3.read, p: Drum.position(s3.read, t, s3.morph + 0.3),
        origin: fold > 0 ? tri : [M.DRUM3.x, M.DRUM3.bottom], scale: (0.94 + 0.06 * open) * (1 - 0.95 * fold), alpha: open * (1 - fold) };
    }
    if (t >= s3.drum2 && t < s3.fold2 + 0.4) {
      const open = K.p(t, s3.drum2, s3.drum2 + 0.5, 'out'), fold = K.p(t, s3.fold2, s3.fold2 + 0.4, 'in');
      if (fold >= 1) return null;
      return { t, x: M.DRUMB.x, bottom: M.DRUMB.bottom, tag: 'Article', tagColor: CYAN, prog: 'article', timeline: s3.read2, p: Drum.position(s3.read2, t, s3.drum2 + 0.2),
        origin: tri, scale: (0.2 + 0.8 * open) * (1 - 0.95 * fold), alpha: open * (1 - fold) };
    }
    return null;
  }
  function receiptState(t) {
    const tri = Orbit.pos(t);
    if (t >= s2.receipt[0] && t < s2.receipt[1] + 0.3) return { x: tri[0] + 18, y: tri[1] - 6, text: D.dictation.receipt, alpha: K.win(t, s2.receipt[0], s2.receipt[1] + 0.3, 0.3, 0.3) };
    if (t >= s7.copy + 0.1 && t < s7.copy + 3.4) return { x: M.PACKET_TRIAD[0] + 18, y: M.PACKET_TRIAD[1] - 17, text: D.handoff.copied, alpha: K.win(t, s7.copy + 0.1, s7.copy + 3.4, 0.3, 0.3) };
    return null;
  }

  // ================= paths =================
  const { Path } = Orbit;
  const geoS = p => Cap.toScreen(p);
  const tueS = (() => { const r = Cap.geo.tue; return { x: r.x + G.CHROME.x, y: r.y + G.CHROME.y + 84, w: r.w, h: r.h }; })();
  const labelS = geoS(Cap.geo.label), strikeS = geoS(Cap.geo.strike.a), arrowBS = geoS(Cap.geo.arrow.b), arrowAS = geoS(Cap.geo.arrow.a);
  const PTR = new Path([
    { t: 0, x: 1180, y: 660, dur: 0 },
    { t: s2.ptr, x: M.caret.x + 70, y: M.caret.cy + 2, dur: 0.9 },
    { t: s2.ptr2, x: 0, y: 0, dur: 0.8 },   // filled after measuring the lens
    { t: s2.ptr3, x: 0, y: 0, dur: 0.5 },
    { t: s2.click3 + 0.8, x: M.caret.x + 720, y: M.caret.cy + 190, dur: 1.0 },
    { t: s3.ptrA, x: M.selStart[0], y: M.selStart[1], dur: 0.8 },
    { t: s3.drag[0], dur: s3.drag[1] - s3.drag[0], fn: p => { const e = K.ease.inOut(p); return [K.lerp(M.selStart[0], M.selEnd[0], e), K.lerp(M.selStart[1], M.selEnd[1], e)]; } },
    { t: s3.drag[1] + 0.6, x: M.selEnd[0] + 60, y: M.selEnd[1] + 120, dur: 0.7 },
    { t: s4.ptrRes, x: CC.target.resolved[0], y: CC.target.resolved[1], dur: 0.8 },
    { t: s4.ptrWb, x: CC.target.workbench[0], y: CC.target.workbench[1], dur: 0.6 },
    { t: s4.ptrP1, x: M.node1[0], y: M.node1[1], dur: 0.9 },
    { t: s5.cap + 0.8, x: 1420, y: 1000, dur: 1.2 },
    { t: s6.ptrTab, x: M.tabPlan[0], y: M.tabPlan[1], dur: 0.8 },
    { t: s6.ptrCard, dur: 1.0, x: geoS(Cap.circlePoint(0))[0], y: geoS(Cap.circlePoint(0))[1] },
    { t: s6.circle[0], dur: s6.circle[1] - s6.circle[0], fn: p => geoS(Cap.circlePoint(p)) },
    { t: s6.ptrArrow, x: arrowAS[0], y: arrowAS[1], dur: 0.8 },
    { t: s6.arrow[0], dur: s6.arrow[1] - s6.arrow[0], fn: p => geoS(Cap.arrowPoint(K.ease.inOut(p))) },
    { t: s6.arrow[1] + 0.4, x: arrowBS[0] + 80, y: arrowBS[1] + 110, dur: 0.6 },
    { t: s6.ptrMid, x: 1000, y: 640, dur: 0.8 },
    { t: s6.ptrLabel, x: labelS[0] + 170, y: labelS[1] + 34, dur: 1.0 },
    { t: s6.ptrCard2, x: tueS.x + tueS.w + 44, y: tueS.y + tueS.h / 2, dur: 1.0 },
    { t: s7.gather + 1.2, x: 1120, y: 800, dur: 1.0 },
  ]);
  const followPtr = tt => { const [x, y] = PTR.at(tt - 0.1); return [x - 30, y - 44]; };
  const TRI = new Path([
    { t: 0, x: 960, y: 386, dur: 0 },
    { t: T.title.b, x: G.DOCK.x, y: G.DOCK.y, dur: 0 },
    { t: s2.triad, x: M.triadCaret[0], y: M.triadCaret[1], dur: 0.85, bend: 0.22 },
    { t: s2.click2, x: 0, y: 0, dur: 0.3 },      // picker (filled after measuring)
    { t: s2.click3 + 0.3, x: M.triadCaret[0], y: M.triadCaret[1], dur: 0.4 },
    { t: s2.deliver + 1.35, x: M.caretEnd.x + 20, y: M.caretEnd.cy, dur: 0.5 },
    { t: s3.front, x: G.DOCK.x, y: G.DOCK.y, dur: 0.7, bend: 0.15 },
    { t: s3.triadSel, x: M.triadSel[0], y: M.triadSel[1], dur: 0.6, bend: 0.2 },
    { t: s4.open, x: CC.TRIAD[0], y: CC.TRIAD[1], dur: 0.8, bend: 0.2 },
    { t: s5.route, x: CC.CENTER[0], y: CC.CENTER[1], dur: 1.0 },
    { t: s5.close + 0.5, x: G.DOCK.x, y: G.DOCK.y, dur: 0.8 },
    { t: s6.c0, dur: 0.6, follow: followPtr },
    { t: s6.triadLabel, x: labelS[0] - 26, y: labelS[1] + 14, dur: 0.6 },
    { t: s6.triadBack3, dur: 0.6, follow: followPtr },
    { t: s6.triadStrike, x: strikeS[0] - 26, y: strikeS[1] - 2, dur: 0.5 },
    { t: s6.triadBack4, dur: 0.6, follow: followPtr },
    { t: s7.stop, x: M.PACKET_TRIAD[0], y: M.PACKET_TRIAD[1], dur: 0.5 },
    { t: s7.front, x: M.termCaret[0] + 26, y: M.termCaret[1], dur: 0.7 },
    { t: s8.fade, x: 960, y: 330, dur: 0.8 },
  ]);
  Orbit.path = TRI;
  Orbit.modes = [[0, 'rest'], [s2.mic, 'listen'], [s2.deliver, 'rest'], [s3.mic, 'listen'], [s3.think, 'think'], [s3.morph + 0.5, 'speak'], [s3.readEnd + 0.4, 'rest'],
    [s3.drum2, 'speak'], [s3.barge, 'listen'], [s3.show.end + 0.1, 'think'], [s4.open + 0.8, 'listen'],
    [s4.regroup.end + 0.1, 'think'], [s4.regroupAnim + 0.9, 'listen'], [s4.resolve.end + 0.1, 'think'], [s4.resolveAnim + 1.2, 'listen'],
    [s5.say.end + 0.1, 'think'], [s5.fAccess + 0.3, 'listen'], [s5.close, 'rest'], [s6.c0, 'record'], [s7.stop, 'rest']];
  Orbit.pulses = [s3.read, s3.read2];
  Orbit.unreadUntil = s4.approved; Orbit.unreadFrom = T.title.b;
  Orbit.init();
  // measure the 'pantry la' token and the picker row for the pointer + triad paths
  { Lens.render(lensS2(s2.click2 - 0.05)); const r = Lens.tokenRect('c3'); PTR.segs[2].x = r.x + r.w * 0.5; PTR.segs[2].y = r.y + r.h * 0.55;
    const lr = Lens.rect(); TRI.segs[3].x = lr.x + lr.w + 18; TRI.segs[3].y = r.y + r.h / 2;
    Lens.render(lensS2(s2.ptr3 + 0.1)); const pr = Lens.pickerRowRect(0); PTR.segs[3].x = pr.x + pr.w * 0.45; PTR.segs[3].y = pr.y + pr.h / 2;
    TRI.segs[3].x = pr.x + pr.w + 16; TRI.segs[3].y = pr.y - 4; Lens.render(null); }
  const CLICKS = [s2.click, s2.click2, s2.click3, s4.clickRes, s4.clickWb, s4.clickP1, s6.clickTab];

  // ================= furniture =================
  const HUD = [
    [s2.hud, ['fn', 'fn'], 'talk', 1.4], [s2.hudDone, ['fn', 'fn'], 'done', 1.4], [s3.hud, ['fn', 'fn'], 'talk', 1.4],
    [s3.hudTab, ['⌘ ⇥'], '', 1.2], [s3.hudF8, ['F8'], 'read aloud', 1.4], [s3.hud3, ['fn', 'fn'], 'talk', 1.4],
    [s5.hudEsc, ['esc'], '', 1.2], [s6.hud, ['fn', 'fn'], 'talk + mark', 1.6],
    [s6.hudTab1, ['⌘ ⇥'], '', 1.2], [s6.hudTab2, ['⌘ ⇥'], '', 1.2], [s6.hudStop, ['fn', 'fn'], 'stop', 1.4],
    [s7.hudCopy, ['⌘ C'], 'copy for any agent', 1.6], [s7.hudTab, ['⌘ ⇥'], '', 1.2], [s7.hudPaste, ['⌘ V'], '', 1.2],
  ];
  const CAPS = [
    [T.rest.cap, 'At rest', 'Three dots. Always there, never in the way.'],
    [s2.cap, 'Dictation', 'See every word as you say it. Fix anything by saying so.'],
    [s3.cap, 'FLORA', 'Ask about every agent you run — and hear the answer.'],
    [s3.cap2, 'Reader', 'Every voice, same reader.'],
    [s4.cap, 'Control center', 'Every agent, one place — regroup and resolve by voice.'],
    [s5.cap, 'Automations', 'Standing work, drafted by talking.'],
    [s6.cap, 'Talk + mark', 'Marks that stay on the thing you mean.'],
    [s6.cap2, 'Talk + mark', 'They scroll with the page and hide with the window.'],
    [s7.cap, 'One payload', 'One payload, any agent.'],
  ];
  function renderHud(t) {
    let cur = null; for (const h of HUD) if (t >= h[0] && t < h[0] + h[3] + 0.3) cur = h;
    if (!cur) { css(E.hud, { visibility: 'hidden' }); return; }
    const [t0, keys, label, dur, hold] = cur; const a = K.win(t, t0, t0 + dur + 0.3, 0.2, 0.3);
    const holdOn = hold && t >= t0 + 0.35 && t < t0 + 1.1;
    html(E.hud, keys.map((k, i) => `<span class="kc${holdOn && i === keys.length - 1 ? ' on' : ''}">${k}</span>`).join('') + (label ? `<span class="lbl">${esc(label)}</span>` : ''));
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
    E.tParts.forEach((el, i) => { const a = K.p(t, 0.3 + i * 0.45, 0.9 + i * 0.45, 'out'); css(el, { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 8).toFixed(1)}px)` }); });
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
  function notionText(t) { const f = D.dictation.final; if (t < s2.deliver + 0.15) return ''; return f.slice(0, Math.round(f.length * K.p(t, s2.deliver + 0.15, s2.deliver + 1.3, 'linear'))); }

  // ================= renderAt =================
  window.renderAt = function (t) {
    const fr = front(t);
    Desktop.setFront(fr);
    { let ls = 0; for (const s of SWITCHES) if (t >= s) ls = s; const p = ls ? K.p(t, ls, ls + 0.22, 'out') : 1; const w = Desktop.$[fr]; css(w, { transform: `scale(${(0.992 + 0.008 * p).toFixed(4)})` }); for (const k of ['notion', 'chrome', 'term']) if (k !== fr) css(Desktop.$[k], { transform: 'none' }); }
    Desktop.setTab(tab(t)); const sc = scroll(t); Desktop.setPlanScroll(sc); Desktop.setArticleSelection(sel(t));
    Desktop.setNotion(notionText(t), t >= s2.click, t < s2.click);
    Desktop.setTermPaste(t >= s7.paste ? D.handoff.pastedLine : '', true);
    Cap.renderMarks(t);
    const tri = Orbit.pos(t);
    CC.render(t, tri);
    Cap.renderTrail(t, tri); Cap.renderPacket(t, tri);
    Lens.render(lensState(t)); Drum.render(drumState(t)); Receipt.render(receiptState(t));
    // effects canvas
    Orbit.clear();
    if (t >= s2.deliver && t < s2.deliver + 1.3) Orbit.comet([M.LENS2.x + 70, M.LENS2.y + 150], [M.caret.x + 6, M.caret.cy], K.p(t, s2.deliver, s2.deliver + 1.25, 'linear') * 1.55, [92, 225, 230], 30, 1);
    if (t >= s6.c0 && t < s7.stop + 1) for (const b of Cap.beads(t, tri, sc)) Orbit.bead(b.x, b.y, b.r, b.a);
    if (t >= s7.copy + 0.45 && t < s7.beadArrive + 0.5) {
      const u = K.p(t, s7.copy + 0.5, s7.beadArrive, 'inOut'), [x, y] = Orbit.curve([960, 488], M.termCaret, u, 0.2, 1);
      const a = 1 - K.p(t, s7.beadArrive, s7.beadArrive + 0.4); Orbit.bead(x, y, 7 * (0.6 + 0.4 * a), a);
      if (u < 1) Orbit.comet([960, 488], M.termCaret, u, [200, 245, 250], 14, 1);
    }
    Orbit.drawTriad(t, t < T.title.b ? 1.6 : 1);
    renderCursor(t); renderHud(t); renderCaption(t); renderTitle(t); renderEnd(t);
  };
  window.FILM = { T, M, PTR, TRI };
})();
