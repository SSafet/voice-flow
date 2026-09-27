// Concept A — "Horizon". Pure renderAt(t): the DOM is built once, every frame only sets styles/text.
(function () {
  'use strict';
  const V = window.VF, D = window.Desk;
  const { p, kf, kf2, lerp, clamp, css, text, html, $, $$, noise } = K;
  const H = 1080, LINE_Y = 1052.5, CX = 960, LANE_X = 580, LANE_W = 760, DECK_X = 220, DECK_W = 1480, DECK_TOP = 404;
  const C = { g: '#0E0D0C', tx: '#F3F0E9', tx2: '#BDB7AB', tx3: '#9C968B', dim: '#A9A398', amber: '#F5A524', ok: '#86C98A', bad: '#FF7A6B' };
  const endOf = K.endOf;
  const win = (t, a, b, i = 0.3, o = 0.3, e = 'inOut') => Math.max(0, Math.min(p(t, a, a + i, e), 1 - p(t, b - o, b, e)));

  // ================================================================ timeline
  const ALL = [];
  const tl = (s, start, wps, seed) => { const x = K.speechTimeline(s, start, wps, seed); ALL.push(x); return x; };
  const T = {};
  {
    const d = V.dictation;
    T.titleEnd = 4.0; T.cap1 = 4.3; T.clickField = 9.6; T.cap2 = 9.9;
    T.fnDown1 = 10.6;
    T.u1 = tl(d.utter1, 11.5, 2.8, 1); T.u1End = endOf(T.u1);
    T.e1 = tl(d.edit1.said, T.u1End + 1.0, 2.9, 2); T.e1End = endOf(T.e1);
    T.e1Apply = T.e1End + 0.55;
    T.u3 = tl(d.utter3Heard, T.e1Apply + 1.9, 2.8, 3); T.u3End = endOf(T.u3);
    T.lowConf = T.u3End + 0.45;
    T.altMove = T.lowConf + 0.4; T.altClick = T.altMove + 1.1; T.altPick = T.altClick + 1.9;
    T.learnt = [T.altPick + 0.45, T.altPick + 2.3];
    T.e2 = tl(d.edit2.said, T.altPick + 1.4, 2.8, 4); T.e2End = endOf(T.e2);
    T.e2ScrollUp = [T.e2End + 0.45, T.e2End + 1.25]; T.e2Apply = T.e2End + 1.45;
    T.e2ScrollBack = [T.e2Apply + 2.0, T.e2Apply + 2.8];
    T.fnUp1 = T.e2ScrollBack[1] + 1.2; T.flight = [T.fnUp1, T.fnUp1 + 0.9]; T.receipt1 = [T.fnUp1 + 0.95, T.fnUp1 + 3.1];
    // scene 3
    T.cap3 = T.receipt1[1] + 0.6; T.fnDown2 = T.cap3 + 0.6;
    T.ask = tl(V.flora.ask, T.fnDown2 + 0.8, 3.0, 5); T.askEnd = endOf(T.ask);
    T.wake = T.ask[0].at + 0.95;
    T.fnUp2 = T.askEnd + 0.45; T.think = [T.fnUp2 + 0.35, T.fnUp2 + 2.5]; T.readerUp = T.think[1];
    let rs = T.readerUp + 0.7;
    T.reply = V.flora.reply.map((s, i) => { const w = tl(s, rs, 3.2, 10 + i); rs = endOf(w) + 0.4; return w; });
    T.replyEnd = rs - 0.4; T.readerDown = [T.replyEnd + 0.6, T.replyEnd + 1.3];
    // 3b — same reader for any text
    T.cmdTab1 = T.readerDown[1] + 0.3; T.cap3b = T.cmdTab1 + 0.1;
    T.selMove = [T.cmdTab1 + 0.35, T.cmdTab1 + 0.95]; T.selDrag = [T.cmdTab1 + 1.05, T.cmdTab1 + 2.15];
    T.f8 = T.selDrag[1] + 0.4; T.reader2Up = T.f8 + 0.15;
    let as = T.reader2Up + 0.7;
    T.art = V.flora.anyText.sentences.map((s, i) => { const w = tl(s, as, 3.5, 20 + i); as = endOf(w) + 0.3; return w; });
    T.artEnd = as - 0.3; T.reader2Down = [T.artEnd + 0.5, T.artEnd + 1.2];
    // "Show me."
    T.fnDown3 = T.reader2Down[1] + 0.3;
    T.showMe = tl(V.flora.followUp, T.fnDown3 + 0.7, 2.6, 30); T.showMeEnd = endOf(T.showMe);
    T.fnUp3 = T.showMeEnd + 0.45;
    // scene 4 — control center
    T.deckUp = [T.fnUp3 + 0.25, T.fnUp3 + 1.0]; T.cap4 = T.deckUp[0] + 0.2;
    T.fnDown4 = T.deckUp[1] + 2.3;
    T.regroup = tl(V.controlCommands.regroup, T.fnDown4 + 0.55, 2.8, 40); T.regroupEnd = endOf(T.regroup);
    T.fnUp4 = T.regroupEnd + 0.35; T.flip = [T.fnUp4 + 0.3, T.fnUp4 + 1.9];
    T.fnDown5 = T.flip[1] + 1.6;
    T.resolve = tl(V.controlCommands.resolve, T.fnDown5 + 0.55, 2.8, 41); T.resolveEnd = endOf(T.resolve);
    T.fnUp5 = T.resolveEnd + 0.35; T.resolveAnim = [T.fnUp5 + 0.3, T.fnUp5 + 2.1];
    T.clickResolved = T.resolveAnim[1] + 2.0; T.clickWorkbench = T.clickResolved + 2.6;
    T.clickCheckout = T.clickWorkbench + 2.0; T.expand = [T.clickCheckout + 0.05, T.clickCheckout + 0.55];
    T.fnDown6 = T.clickCheckout + 2.6;
    T.approve = tl(V.controlCommands.approve, T.fnDown6 + 0.55, 2.5, 42); T.approveEnd = endOf(T.approve);
    T.fnUp6 = T.approveEnd + 0.35; T.approved = T.fnUp6 + 0.3;
    // scene 5 — automations
    T.cap5 = T.approved + 2.2; T.fnDown7 = T.cap5 + 0.5;
    T.auto = tl(V.automation.said, T.fnDown7 + 0.75, 2.8, 50); T.autoEnd = endOf(T.auto);
    T.autoView = T.auto[0].at + 1.0; T.fnUp7 = T.autoEnd + 0.45;
    T.draftFields = [0, 1, 2, 3].map(i => T.fnUp7 + 0.5 + i * 0.55);
    T.draftStreams = [0, 1, 2, 3].map(i => T.fnUp7 + 2.8 + i * 0.4);
    T.fnDown8 = T.draftStreams[3] + 1.8;
    T.stripe = tl(V.automation.addStripe, T.fnDown8 + 0.55, 2.7, 51); T.stripeEnd = endOf(T.stripe);
    T.fnUp8 = T.stripeEnd + 0.35; T.stripeOn = T.fnUp8 + 0.4;
    T.fnDown9 = T.stripeOn + 1.6;
    T.enable = tl(V.automation.enable, T.fnDown9 + 0.55, 2.5, 52); T.enableEnd = endOf(T.enable);
    T.fnUp9 = T.enableEnd + 0.35; T.active = T.fnUp9 + 0.4;
    T.clickStreams = T.active + 2.0; T.streamsView = [T.clickStreams + 0.05, T.clickStreams + 0.5];
    T.deckDown = [T.clickStreams + 3.6, T.clickStreams + 4.3];
    // scene 6 — talk + mark
    T.cap6 = T.deckDown[1] + 0.2; T.clickPlanTab = T.cap6 + 1.4;
    T.fnfn1 = T.clickPlanTab + 1.5; T.capStart = T.fnfn1 + 0.45;
    T.ann = V.annotations.map(a => ({ ...a, at: T.capStart + a.t }));
    T.annSpeech = T.ann.map((a, i) => tl(a.said, a.at, 2.8, 60 + i));
    const a = T.ann;
    T.draw0 = [a[0].at + 0.25, a[0].at + 2.05]; T.anchor0 = T.draw0[1] + 0.12;
    T.draw1 = [a[1].at + 0.1, a[1].at + 1.35]; T.anchor1 = T.draw1[1] + 0.12;
    T.anchor2 = endOf(T.annSpeech[2]) + 0.2;
    T.draw3 = [endOf(T.annSpeech[3]) + 0.05, endOf(T.annSpeech[3]) + 0.7]; T.anchor3 = T.draw3[1] + 0.1;
    T.scroll = [T.anchor3 + 2.0, T.anchor3 + 3.4];
    T.cmdTab2 = T.scroll[1] + 1.3; T.cmdTab3 = T.cmdTab2 + 2.4;
    T.fnfn2 = T.cmdTab3 + 2.6; T.capEnd = T.fnfn2 + 0.25;
    // scene 7 — payload
    T.payUp = [T.capEnd + 0.9, T.capEnd + 1.6]; T.cap7 = T.payUp[0] + 0.1;
    T.cmdC = T.payUp[1] + 4.6; T.payDown = [T.cmdC + 0.3, T.cmdC + 1.0]; T.receipt2 = [T.cmdC + 0.9, T.cmdC + 3.9];
    T.clickTerm = T.cmdC + 2.4; T.cmdV = T.clickTerm + 1.3;
    T.fadeOut = [T.cmdV + 3.2, T.cmdV + 4.1];
    // scene 8 — end card
    T.endStart = T.fadeOut[1]; T.endLine = i => T.endStart + 0.3 + i * 0.65; T.endBrand = T.endStart + 4.2;
    window.DURATION = Math.round((T.endBrand + 3.2) * 10) / 10;
  }
  window.T = T;

  // ================================================================ speech envelope (for the waveform)
  function envelope(t) {
    let e = 0;
    for (const w of ALL) {
      if (t < w[0].at - 0.2 || t > endOf(w) + 0.2) continue;
      for (const x of w) {
        const dt = t - x.at; if (dt < -0.02 || dt > 0.55) continue;
        const syl = Math.max(1, Math.round(x.w.replace(/[^a-z]/gi, '').length / 3));
        for (let s = 0; s < syl; s++) { const ds = dt - s * 0.12; e += (0.6 + 0.4 * K.hash(x.i * 7 + s)) * Math.exp(-Math.pow((ds - 0.05) / 0.07, 2)); }
      }
    }
    return clamp(e, 0, 1);
  }

  // ================================================================ key HUD, captions, clicks, front app
  const HUD = [];
  const hold = (a, b) => HUD.push({ a, b, keys: ['fn'], held: true, note: 'hold · talk' });
  hold(T.fnDown1, T.fnUp1); hold(T.fnDown2, T.fnUp2); hold(T.fnDown3, T.fnUp3); hold(T.fnDown4, T.fnUp4); hold(T.fnDown5, T.fnUp5);
  hold(T.fnDown6, T.fnUp6); hold(T.fnDown7, T.fnUp7); hold(T.fnDown8, T.fnUp8); hold(T.fnDown9, T.fnUp9);
  HUD.push({ a: T.cmdTab1 - 0.2, b: T.cmdTab1 + 0.9, keys: ['⌘', '⇥'] });
  HUD.push({ a: T.f8 - 0.15, b: T.f8 + 1.0, keys: ['F8'], note: 'read aloud' });
  HUD.push({ a: T.fnfn1 - 0.2, b: T.fnfn1 + 1.4, keys: ['fn', 'fn'], note: 'double-tap · talk + mark' });
  HUD.push({ a: T.scroll[0] - 0.1, b: T.scroll[1] + 0.3, keys: [], note: 'scroll' });
  HUD.push({ a: T.cmdTab2 - 0.2, b: T.cmdTab2 + 0.9, keys: ['⌘', '⇥'] });
  HUD.push({ a: T.cmdTab3 - 0.2, b: T.cmdTab3 + 0.9, keys: ['⌘', '⇥'] });
  HUD.push({ a: T.fnfn2 - 0.2, b: T.fnfn2 + 1.2, keys: ['fn', 'fn'], note: 'double-tap · stop' });
  HUD.push({ a: T.cmdC - 0.1, b: T.cmdC + 1.1, keys: ['⌘', 'C'] });
  HUD.push({ a: T.cmdV - 0.1, b: T.cmdV + 1.1, keys: ['⌘', 'V'] });

  const CAPS = [
    [T.cap1, 'At rest', 'Three dots. Always there, never in the way.'],
    [T.cap2, 'Dictation', 'Every word as you say it. Fix it by saying so.'],
    [T.cap3, 'FLORA', 'Ask FLORA. Hear it back, word by word.'],
    [T.cap3b, 'Any text', 'Every voice, same reader.'],
    [T.cap4, 'Control center', 'Every agent, one place — and a clean workbench.'],
    [T.cap5, 'Automations', 'Standing orders, in plain words.'],
    [T.cap6, 'Talk and mark', 'Marks that stay on the thing you mean.'],
    [T.cap7, 'Hand-off', 'One payload, any agent.'],
  ];
  const CLICKS = [T.clickField, T.altClick, T.altPick, T.clickResolved, T.clickWorkbench, T.clickCheckout, T.clickStreams, T.clickPlanTab, T.clickTerm, T.selDrag[0]];
  const FRONT = [[T.cmdTab1, 'chrome'], [T.cmdTab2, 'notion'], [T.cmdTab3, 'chrome'], [T.clickTerm, 'term']];
  function stackAt(t) { let st = ['term', 'chrome', 'notion'], since = 0; for (const [tt, n] of FRONT) if (t >= tt) { st = st.filter(x => x !== n); st.push(n); since = tt; } return { st, since }; }
  const fnHeld = t => { let v = 0; for (const h of HUD) if (h.held) v = Math.max(v, win(t, h.a, h.b + 0.15, 0.25, 0.3)); return v; };

  // ================================================================ horizon state
  const MODE = {
    rest: { w: 150, dl: 0, amber: 0, wave: 0, think: 0, prog: 0, rec: 0, deck: 0 },
    listen: { w: 760, dl: 1, amber: 1, wave: 1, think: 0, prog: 0, rec: 0, deck: 0 },
    think: { w: 200, dl: 0, amber: 1, wave: 0, think: 1, prog: 0, rec: 0, deck: 0 },
    read: { w: 760, dl: 0, amber: 0, wave: 0, think: 0, prog: 1, rec: 0, deck: 0 },
    deck: { w: 1480, dl: 1, amber: 0, wave: 1, think: 0, prog: 0, rec: 0, deck: 1 },
    rec: { w: 760, dl: 1, amber: 1, wave: 1, think: 0, prog: 0, rec: 1, deck: 0 },
  };
  const HS = [[0, 'rest'], [T.fnDown1, 'listen'], [T.fnUp1, 'rest'], [T.fnDown2, 'listen'], [T.fnUp2, 'think'], [T.readerUp - 0.1, 'read'],
    [T.readerDown[0], 'rest'], [T.f8, 'read'], [T.reader2Down[0], 'rest'], [T.fnDown3, 'listen'], [T.fnUp3 + 0.1, 'deck'], [T.deckDown[0], 'rest'],
    [T.fnfn1, 'rec'], [T.capEnd, 'rest'], [T.payUp[0] - 0.2, 'deck'], [T.payDown[0], 'rest']];
  function hparams(t) {
    let i = 0; while (i + 1 < HS.length && t >= HS[i + 1][0]) i++;
    const cur = MODE[HS[i][1]], prev = i > 0 ? MODE[HS[i - 1][1]] : cur, q = p(t, HS[i][0], HS[i][0] + 0.6, 'inOut');
    const o = {}; for (const k in cur) o[k] = lerp(prev[k], cur[k], q); o.mode = HS[i][1]; return o;
  }

  // ================================================================ DOM (built once)
  let R; // measured rects
  const E = {};
  function buildFilm() {
    const stage = $('#stage');
    // horizon svg + dots + receipts + lane + reader + deck + cmdline + film furniture
    stage.insertAdjacentHTML('beforeend', `
      <div id="hz">
        <svg id="hz-svg" width="1920" height="1080"><defs>
          <linearGradient id="lg" gradientUnits="userSpaceOnUse" y1="0" y2="0"><stop offset="0" stop-color="#FFF8EB" stop-opacity="0"/><stop offset=".1" stop-color="#FFF8EB" stop-opacity=".8"/><stop offset=".9" stop-color="#FFF8EB" stop-opacity=".8"/><stop offset="1" stop-color="#FFF8EB" stop-opacity="0"/></linearGradient>
          <linearGradient id="lgb" gradientUnits="userSpaceOnUse" y1="0" y2="0"><stop offset="0" stop-color="#FFF8EB" stop-opacity="0"/><stop offset=".1" stop-color="#FFF8EB" stop-opacity="1"/><stop offset="1" stop-color="#FFF8EB" stop-opacity="1"/></linearGradient>
          <linearGradient id="lga" gradientUnits="userSpaceOnUse" y1="0" y2="0"><stop offset="0" stop-color="#F5A524" stop-opacity="0"/><stop offset=".5" stop-color="#F5A524" stop-opacity="1"/><stop offset="1" stop-color="#F5A524" stop-opacity="0"/></linearGradient>
        </defs>
        <path id="hz-line" fill="none" stroke="url(#lg)" stroke-width="1"/>
        <path id="hz-prog" fill="none" stroke="url(#lgb)" stroke-width="1.5" stroke-linecap="round"/>
        <path id="hz-glow" fill="none" stroke="url(#lga)" stroke-width="2" stroke-linecap="round"/>
        </svg>
        <div id="dot-ring"></div><div class="dot" id="d0"></div><div class="dot" id="d1"></div><div class="dot" id="d2"></div>
        <div id="ticks"></div>
        <div id="think"></div><div id="receipt"></div>
        <div id="lane"><div class="backing"></div><div class="lane-in">
          <div class="lane-head" id="lane-head"><span class="lbl amber" id="lane-lbl"></span><span id="lane-sub"></span><span id="lane-cmd"></span></div>
          <div id="lane-clip"><div id="lane-text"></div></div>
          <div id="lane-foot"></div></div></div>
        <div id="altmenu"><div class="backing"></div><div class="alt hi"></div><div class="alt"></div><div class="alt"></div></div>
        <div id="reader"><div class="backing"></div><div class="rd-in">
          <div class="rd-speaker"><span class="lbl amber" id="rd-lbl"></span><span id="rd-src"></span><span class="right"><span id="rd-speed"></span><span class="pause"><i></i><i></i></span></span></div>
          <div class="rd-rows" id="rd-rows"></div></div></div>
        <div id="cmdline"><span class="lbl amber">to FLORA</span><span id="cmd-words"></span></div>
        <div id="deck"></div>
      </div>
      <div id="caption"><div class="cap-label" id="cap-label"></div><div class="cap-line" id="cap-line"></div></div>
      <div id="keyhud"></div>
      <div id="ripple"></div>
      <svg id="cursor" viewBox="0 0 22 30"><path d="M2 1.5 L2 22.5 L7.2 17.6 L11 27 L15 25.3 L11.3 16 L18.6 16 Z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>
      <div id="title"><div class="t-mark"><i style="left:57px"></i><i style="left:72px"></i><i style="left:87px"></i></div><div class="t-name">VoiceFlow</div><div class="t-concept">Concept A — Horizon</div><div class="t-thesis">Everything you say lands on one line.</div></div>
      <div id="endcard">${V.endCard.map(l => `<div class="e-line">${l}</div>`).join('')}<div class="e-brand"><b>VoiceFlow</b> · Concept A — Horizon</div></div>
      <span id="meas" style="position:absolute;left:-9999px;top:-9999px;white-space:nowrap;visibility:hidden"></span>`);
    buildDeck();
    for (const id of ['hz-line', 'hz-prog', 'hz-glow', 'd0', 'd1', 'd2', 'dot-ring', 'ticks', 'think', 'receipt', 'lane', 'lane-head', 'lane-lbl', 'lane-sub', 'lane-cmd', 'lane-clip', 'lane-text', 'lane-foot', 'altmenu', 'reader', 'rd-lbl', 'rd-src', 'rd-speed', 'rd-rows', 'cmdline', 'cmd-words', 'deck', 'caption', 'cap-label', 'cap-line', 'keyhud', 'ripple', 'cursor', 'title', 'endcard', 'meas', 'menubar', 'win-notion', 'win-chrome', 'win-term', 'n-desc', 'n-desc-text', 'page-plan', 'page-art', 'pl-scroll', 'c-tab-plan', 'c-tab-art', 'c-url-a', 'c-url-b', 'mb-app-a', 'mb-app-b', 'mb-app-c', 't-paste', 'marks'])
      E[id] = document.getElementById(id);
    E.lg = $('#lg'); E.lgb = $('#lgb'); E.lga = $('#lga');
    E.nFocus = $('#n-desc .n-focus'); E.nCaret = $('#n-desc .n-caret'); E.nEmpty = $('#n-desc .n-empty');
    E.artWords = $$('#art-p2 .aw'); E.artGaps = $$('#art-p2 .aw-gap');
    E.ticks = $('#ticks');
    // ticks + thumbs
    E.ticks.innerHTML = V.annotations.map((a, i) => `<div class="tick" id="tick-${i}"></div><div class="thumb" id="thumb-${i}"></div>`).join('');
    E.tickEls = V.annotations.map((a, i) => $('#tick-' + i)); E.thumbEls = V.annotations.map((a, i) => $('#thumb-' + i));
    E.altRows = $$('#altmenu .alt'); V.dictation.misheard.alternatives.forEach((s, i) => text(E.altRows[i], s));
    E.endLines = $$('#endcard .e-line'); E.endBrand = $('#endcard .e-brand');
    E.hudEl = E.keyhud;
  }

  // ---- deck DOM
  const ROW_H = 50, ROWS_TOP = 46, BODY_PAD = 32, BODY_W = 1416, EXP_H = 122;
  const rowH = s => ROW_H + (s.priority ? 18 : 0);
  const DONE = V.sessions.filter(s => s.status === 'done');
  function buildDeck() {
    const s1 = V.sessions.find(s => s.id === 1), A = V.checkoutAsk;
    const row = s => `<div class="row${s.priority ? ' tall' : ''}" id="row-${s.id}">${s.priority ? `<span class="pri">${s.priority}</span>` : ''}
      <span class="gl"><i class="g-needs"></i><i class="g-failed"></i><i class="g-review"></i><i class="g-running"></i><i class="g-idle"></i><i class="g-done"></i></span>
      <div class="main"><div class="ti">${s.title}</div><div class="me"><span class="m-a">${s.runtime} · ${s.age} · ${s.line}</span>${s.id === 1 ? `<span class="m-b">${s.runtime} · ${s.age} · ${A.approvedLine}</span>` : ''}</div>
      ${s.id === 1 ? `<div class="detail"><div class="dt">${A.title}</div><div class="db">${A.body}</div><div class="da"><span class="act amber">Approve</span><span class="act">Not now</span></div></div>` : ''}</div></div>`;
    const heads = (names, cls) => names.map((n, i) => `<div class="colhead ${cls}" id="${cls}-${i}">${n}<b></b></div>`).join('');
    const divs = (n, cls) => Array.from({ length: n - 1 }, (_, i) => `<div class="divider ${cls}" id="${cls}-${i}"></div>`).join('');
    const au = V.automation;
    const detailHTML = s => s.on === false ? `<span class="sd"><span class="sd-a">${s.detail} · ${s.fresh}</span><span class="sd-b">${s.detail} · connected just now</span></span>` : `<span class="sd">${s.detail ? s.detail + ' · ' : ''}${s.fresh}</span>`;
    const streamRow = (s, i, id) => `<div class="s-row" id="${id}-${i}"><span class="sn">${s.name}</span>${detailHTML(s)}<span class="sw"><span class="off">Off</span><span class="on">On</span></span></div>`;
    const md = V.payloadMarkdown.map(l => { const m = l.match(/^(.*?)\s{2,}(shot-\d\.png)$/); const body = m ? m[1] : l; const cls = body.startsWith('##') ? 'h' : /^\[/.test(body) ? 'q' : 'm';
      return `<span class="ln"><span class="${cls}">${body || ' '}</span>${m ? `<span class="shot">${m[2]}</span>` : ''}</span>`; }).join('');
    E.deck = $('#deck');
    E.deck.innerHTML = `
      <div class="deck-view" id="v-cc">
        <div class="deck-head"><div class="tabs"><span class="tab" id="tab-wb">Workbench<b id="wb-n">20</b></span><span class="tab" id="tab-rs">Resolved<b id="rs-n"></b></span><span class="tab" id="tab-hi">History</span><div id="tab-ul"></div></div>
          <div class="head-right"><span id="grp"><span id="grp-a">Group: Project ▾</span><span id="grp-b">Group: Component ▾</span></span><span class="search-glyph"></span></div></div>
        <div class="deck-body" id="cc-body">${heads(V.projects, 'hp')}${heads(V.components, 'hc')}${divs(4, 'dp')}${divs(3, 'dc')}${V.sessions.map(row).join('')}</div></div>
      <div class="deck-view" id="v-auto">
        <div class="deck-head"><div class="crumb"><span class="lbl amber">FLORA</span><span class="chev">›</span><span class="cur"><span id="crumb-a">Automations</span><span id="crumb-b">Data streams</span></span></div>
          <div class="head-right"><span class="tab" id="tab-streams">Data streams<b>7</b></span></div></div>
        <div class="deck-body" id="auto-body">
          <div class="auto-list"><div class="colhead">Automations<b>3</b></div>
            ${au.existing.map((a, i) => `<div class="a-row" style="top:${52 + i * 60}px"><div class="an"><span>${a.name}</span></div><div class="as"><span>${a.schedule}</span></div><span class="sw on">On</span></div>`).join('')}
            <div class="a-row" id="a-new" style="top:${52 + 2 * 60}px"><div class="an"><span id="an-a">New automation</span><span id="an-b">${au.draft.name}</span></div><div class="as"><span id="as-a">—</span><span id="as-b">${au.draft.schedule}</span><span id="as-c">${au.draft.schedule} · next run ${au.draft.nextRun}</span></div><span class="sw"><span id="sw-a" style="position:absolute;right:0;top:0">Draft</span><span id="sw-b" class="on" style="position:absolute;right:0;top:0;white-space:nowrap">On</span></span></div>
          </div>
          <div class="auto-draft"><div class="divider"></div>
            <div class="dl-row" id="dl-0"><span class="dl-k">Name</span><span class="dl-v" id="f-0"></span></div>
            <div class="dl-row" id="dl-1"><span class="dl-k">Schedule</span><span class="dl-v" id="f-1"></span></div>
            <div class="dl-row" id="dl-2"><span class="dl-k">Deliver</span><span class="dl-v" id="f-2"></span></div>
            <div class="dl-row" id="dl-3"><span class="dl-k">Access</span><span class="dl-v" id="f-3"></span></div>
            <div class="dl-row streams" id="dl-4"><span class="dl-k">Data streams</span><div class="dl-v">${au.streams.map((s, i) => streamRow(s, i, 'ds')).join('')}</div></div>
            <div class="dl-row" id="dl-5"><span class="dl-k">Status</span><span class="dl-v" id="f-status"><span id="st-a">Draft</span><span id="st-b" style="color:${C.amber}">Active · next ${au.draft.nextRun}</span></span></div>
          </div></div></div>
      <div class="deck-view" id="v-streams"><div class="deck-body streams-body" style="top:0"><div class="colhead" style="top:22px">Data streams<b>7</b></div>
        ${[...au.streams, ...au.otherStreams].map((s, i) => `<div class="s-row" id="st-${i}" style="top:${56 + i * 48}px"><span class="sn">${s.name}</span>${detailHTML(s)}<span class="sw"><span class="off">Off</span><span class="on">On</span></span></div>`).join('')}
        </div></div>
      <div class="deck-view" id="v-pay">
        <div class="deck-head"><div class="pay-title"><span>${V.capture.title}</span><span class="pay-meta">${V.capture.length} · ${V.capture.marks} marks · ${V.capture.shots} shots</span></div>
          <div class="head-right"><span class="act" id="act-copy">Copy for any agent<kbd>⌘C</kbd></span><span class="act">Send to…</span></div></div>
        <div class="deck-body"><div class="pay-thumbs">${V.annotations.map((a, i) => `<div class="pt"><div class="im" id="pay-thumb-${i}"></div><span class="tm">${'0:' + String(Math.floor(a.t)).padStart(2, '0')}</span></div>`).join('')}</div>
          <pre class="pay-md"><div class="divider"></div>${md}</pre></div></div>`;
    E.views = { cc: $('#v-cc'), auto: $('#v-auto'), streams: $('#v-streams'), pay: $('#v-pay') };
    E.rows = {}; V.sessions.forEach(s => { const r = $('#row-' + s.id); E.rows[s.id] = { el: r, gl: $$('.gl i', r), pri: $('.pri', r), ma: $('.m-a', r), mb: $('.m-b', r), detail: $('.detail', r) }; });
    E.hp = V.projects.map((_, i) => $('#hp-' + i)); E.hc = V.components.map((_, i) => $('#hc-' + i));
    E.dp = [0, 1, 2].map(i => $('#dp-' + i)); E.dc = [0, 1].map(i => $('#dc-' + i));
    E.tabWb = $('#tab-wb'); E.tabRs = $('#tab-rs'); E.tabUl = $('#tab-ul'); E.wbN = $('#wb-n'); E.rsN = $('#rs-n'); E.grpA = $('#grp-a'); E.grpB = $('#grp-b');
    E.crumbA = $('#crumb-a'); E.crumbB = $('#crumb-b'); E.tabStreams = $('#tab-streams');
    E.anA = $('#an-a'); E.anB = $('#an-b'); E.asA = $('#as-a'); E.asB = $('#as-b'); E.asC = $('#as-c'); E.swA = $('#sw-a'); E.swB = $('#sw-b');
    E.dl = [0, 1, 2, 3, 4, 5].map(i => $('#dl-' + i)); E.f = [0, 1, 2, 3].map(i => $('#f-' + i)); E.stA = $('#st-a'); E.stB = $('#st-b');
    E.ds = [0, 1, 2, 3].map(i => $('#ds-' + i)); E.st = [0, 1, 2, 3, 4, 5, 6].map(i => $('#st-' + i));
    E.payThumbs = V.annotations.map((a, i) => $('#pay-thumb-' + i));
  }

  // ================================================================ measurement helpers
  const measCache = new Map();
  function measure(txt, size, ls = '-.003em') {
    const k = size + '|' + txt; if (measCache.has(k)) return measCache.get(k);
    const m = E.meas; m.style.font = `400 ${size}px system-ui, -apple-system, sans-serif`; m.style.letterSpacing = ls; m.textContent = txt;
    const w = m.getBoundingClientRect().width; measCache.set(k, w); return w;
  }

  // ================================================================ token rendering (lane + command lines)
  function renderTokens(container, toks, size, withCaret) {
    const key = toks.map(x => x.key).join('|') + (withCaret ? '|c' : '');
    if (container.__key !== key) {
      container.__key = key;
      container.innerHTML = toks.map(x => `<span class="tok"><span class="a"></span><span class="b"></span></span>`).join('') + (withCaret ? '<span id="caret"></span>' : '');
      container.__spans = $$('.tok', container); container.__caret = $('#caret', container);
    }
    toks.forEach((x, i) => {
      const sp = container.__spans[i], a = sp.firstChild, b = sp.lastChild;
      text(a, x.text); const wA = measure(x.text, size);
      let w = wA;
      if (x.alt != null && x.mix < 1) { text(b, x.alt); w = lerp(measure(x.alt, size), wA, x.mix); css(b, { opacity: String(1 - x.mix) }); css(a, { opacity: String(x.mix) }); }
      else { css(b, { opacity: '0' }); css(a, { opacity: '1' }); }
      const wf = x.width == null ? 1 : x.width, prov = x.prov || 0;
      css(sp, { width: (w * wf + 0.5).toFixed(1) + 'px', marginRight: (0.28 * size * wf).toFixed(1) + 'px', opacity: (lerp(1, 0.6, prov) * (x.fade == null ? 1 : x.fade)).toFixed(3), color: x.amber ? K.mix(C.tx, C.amber, x.amber) : C.tx });
      sp.classList.toggle('prov', prov > 0.5); sp.classList.toggle('low', !!x.lowconf);
      css(a, { backgroundSize: `${((x.strike || 0) * 100).toFixed(1)}% 2px` });
    });
    if (container.__caret) css(container.__caret, { opacity: withCaret ? '1' : '0' });
    return container.__spans;
  }
  const provAt = (t, at) => 1 - p(t, at + 0.5, at + 1.0, 'inOut');
  const streamed = (tlx, t, keyp, opts = {}) => { const o = []; for (const w of tlx) { if (t < w.at) break; o.push({ key: keyp + w.i, text: w.w, prov: provAt(t, w.at), ...opts }); } return o; };

  // ---- scene 2 token model
  function dictTokens(t) {
    const toks = []; const u1 = T.u1, u3 = T.u3;
    const rev = { 1: { from: 'on boarding', until: u1[1].at + 0.62 }, 8: { from: 'desk', until: u1[8].at + 0.62 } };
    for (let i = 0; i < u1.length; i++) {
      const w = u1[i]; if (t < w.at) break;
      const tok = { key: 'u1' + i, text: w.w, prov: provAt(t, w.at) };
      if (rev[i]) { const r = rev[i]; tok.alt = r.from; tok.mix = p(t, r.until, r.until + 0.35, 'inOut'); if (tok.mix < 1) tok.prov = Math.max(tok.prov, 0.6); }
      if (i === 1) { // edit 2: 'onboarding' → 'first-run'
        if (t >= T.e2Apply) { tok.prov = 0; tok.strike = p(t, T.e2Apply, T.e2Apply + 0.4, 'out'); tok.width = 1 - p(t, T.e2Apply + 0.4, T.e2Apply + 0.85, 'inOut'); }
        toks.push(tok);
        if (t >= T.e2Apply + 0.4) toks.push({ key: 'ins2', text: 'first-run', width: p(t, T.e2Apply + 0.4, T.e2Apply + 0.8, 'out'), amber: 1 - p(t, T.e2Apply + 0.9, T.e2Apply + 2.1, 'inOut') });
        continue;
      }
      if (i === 10 && t >= T.e1Apply) toks.push({ key: 'ins1', text: V.dictation.edit1.inserted, width: p(t, T.e1Apply, T.e1Apply + 0.4, 'out'), amber: 1 - p(t, T.e1Apply + 0.4, T.e1Apply + 1.6, 'inOut') });
      toks.push(tok);
    }
    for (let i = 0; i < u3.length; i++) {
      const w = u3[i]; if (t < w.at) break;
      if (i === 3) {
        if (t < u3[4].at) toks.push({ key: 'u3-3', text: 'pantry', prov: provAt(t, w.at) });
        else { const rep = t >= T.altPick + 0.1, q = p(t, T.altPick + 0.1, T.altPick + 0.45, 'inOut');
          toks.push({ key: 'u3-pl', text: V.dictation.misheard.chosen, alt: V.dictation.misheard.heard, mix: q, prov: rep ? 0 : provAt(t, u3[4].at), lowconf: t >= T.lowConf && !rep, amber: rep ? 1 - p(t, T.altPick + 0.5, T.altPick + 1.7, 'inOut') : 0 }); }
        continue;
      }
      if (i === 4) continue;
      toks.push({ key: 'u3' + i, text: w.w, prov: provAt(t, w.at) });
    }
    return toks;
  }
  function wakeTokens(tlx, t, keyp, wakeAt) {
    const o = streamed(tlx, t, keyp);
    if (o.length) { o[0].width = 1 - p(t, wakeAt, wakeAt + 0.45, 'inOut'); o[0].fade = 1 - p(t, wakeAt, wakeAt + 0.3, 'inOut'); }
    return o;
  }

  // ================================================================ lane
  function laneAt(t) {
    // returns null or {r (rise 0..1), mode, toks, head:{lbl,sub,cmd}, foot, flight}
    if (t >= T.fnDown1 - 0.05 && t < T.flight[1] + 0.05) {
      const r = p(t, T.fnDown1, T.fnDown1 + 0.5, 'out');
      let cmd = null;
      if (t >= T.e1[0].at - 0.3 && t < T.e1Apply + 0.9) cmd = { toks: streamed(T.e1, t, 'e1'), op: win(t, T.e1[0].at - 0.3, T.e1Apply + 0.9, 0.3, 0.4) };
      if (t >= T.e2[0].at - 0.3 && t < T.e2Apply + 1.2) cmd = { toks: streamed(T.e2, t, 'e2'), op: win(t, T.e2[0].at - 0.3, T.e2Apply + 1.2, 0.3, 0.4) };
      const foot = t >= T.learnt[0] && t < T.learnt[1] + 0.3 ? { text: V.dictation.misheard.learnt, op: win(t, T.learnt[0], T.learnt[1] + 0.3, 0.3, 0.3) } : null;
      const scrollF = clamp(1 - p(t, T.e2ScrollUp[0], T.e2ScrollUp[1], 'inOut') + p(t, T.e2ScrollBack[0], T.e2ScrollBack[1], 'inOut'));
      return { r, mode: 'dict', toks: dictTokens(t), cmd, foot, scrollF, flight: p(t, T.flight[0], T.flight[1], 'in'), caret: t < T.flight[0] };
    }
    if (t >= T.fnDown2 - 0.05 && t < T.fnUp2 + 0.6) {
      const r = p(t, T.fnDown2, T.fnDown2 + 0.5, 'out') - p(t, T.fnUp2 + 0.05, T.fnUp2 + 0.55, 'inOut');
      return { r, mode: 'ask', toks: wakeTokens(T.ask, t, 'ask', T.wake), lbl: { text: 'to FLORA', op: p(t, T.wake + 0.1, T.wake + 0.5, 'inOut') }, scrollF: 1, caret: t < T.fnUp2 };
    }
    if (t >= T.fnDown3 - 0.05 && t < T.fnUp3 + 0.6) {
      const r = p(t, T.fnDown3, T.fnDown3 + 0.5, 'out') - p(t, T.fnUp3 + 0.05, T.fnUp3 + 0.55, 'inOut');
      return { r, mode: 'show', toks: streamed(T.showMe, t, 'sm'), lbl: { text: 'to FLORA', op: 1 }, scrollF: 1, caret: t < T.fnUp3 };
    }
    if (t >= T.capStart - 0.05 && t < T.capEnd + 0.6) {
      const r = p(t, T.capStart, T.capStart + 0.5, 'out') - p(t, T.capEnd, T.capEnd + 0.5, 'inOut');
      let toks = [], fade = 1;
      for (let i = T.ann.length - 1; i >= 0; i--) if (t >= T.ann[i].at) { toks = streamed(T.annSpeech[i], t, 'an' + i); fade = p(t, T.ann[i].at, T.ann[i].at + 0.25, 'out'); break; }
      return { r, mode: 'rec', toks, lbl: { text: 'capture', op: 1 }, sub: `Chrome — ${V.pantrella.url}`, scrollF: 1, caret: true, bodyOp: fade };
    }
    return null;
  }

  function renderLane(t, hp) {
    const L = laneAt(t);
    if (!L || L.r <= 0) { css(E.lane, { opacity: '0' }); css(E.altmenu, { opacity: '0' }); return null; }
    const bottom = lerp(64, 128, hp.rec);
    // head
    const lblOp = L.lbl ? L.lbl.op : 0, cmdOp = L.cmd ? L.cmd.op : 0, headH = Math.max(lblOp, cmdOp) * 28;
    css(E['lane-head'], { height: headH.toFixed(1) + 'px', opacity: Math.max(lblOp, cmdOp).toFixed(3) });
    text(E['lane-lbl'], L.cmd ? 'edit' : (L.lbl ? L.lbl.text : ''));
    text(E['lane-sub'], L.sub || '');
    css(E['lane-sub'], { fontSize: '15px', color: C.tx2 });
    if (L.cmd) { css(E['lane-cmd'], { display: 'inline-block' }); renderTokens(E['lane-cmd'], L.cmd.toks, 15, false); } else { css(E['lane-cmd'], { display: 'none' }); }
    // body
    renderTokens(E['lane-text'], L.toks, 26, !!L.caret);
    css(E['lane-text'], { opacity: (L.bodyOp == null ? 1 : L.bodyOp).toFixed(3) });
    let altOp = 0;
    if (t >= T.altClick && t < T.altPick + 0.4) altOp = win(t, T.altClick, T.altPick + 0.4, 0.3, 0.3, 'inOut');
    const contentH = E['lane-text'].offsetHeight, menuH = E.altmenu.offsetHeight + 10;
    const clipH = lerp(Math.min(72, Math.max(36, contentH)), 36 + menuH, altOp);
    css(E['lane-clip'], { height: clipH.toFixed(1) + 'px' });
    const scroll = lerp(Math.max(0, contentH - 72) * (L.scrollF == null ? 1 : L.scrollF), Math.max(0, contentH - 36), altOp);
    css(E['lane-text'], { transform: `translateY(${(-scroll).toFixed(1)}px)` });
    const sf = L.scrollF == null ? 1 : L.scrollF, scrolling = sf > 0.001 && sf < 0.999 && contentH > 72;
    css(E['lane-clip'], { maskImage: scrolling ? 'linear-gradient(to bottom, transparent, #000 14px, #000 calc(100% - 14px), transparent)' : 'none', webkitMaskImage: scrolling ? 'linear-gradient(to bottom, transparent, #000 14px, #000 calc(100% - 14px), transparent)' : 'none' });
    // foot
    const footOp = L.foot ? L.foot.op : 0;
    text(E['lane-foot'], L.foot ? L.foot.text : ''); css(E['lane-foot'], { height: (footOp * 30).toFixed(1) + 'px', opacity: footOp.toFixed(3), paddingTop: (footOp * 4).toFixed(1) + 'px' });
    // rise / flight
    let tf = `translateY(${((1 - L.r) * 18).toFixed(1)}px)`, op = Math.min(1, L.r * 2.5), clip = `inset(calc(${((1 - L.r) * 100).toFixed(1)}% - 70px) -130px -50px -130px)`;
    if (L.flight > 0) {
      const f = L.flight, laneRect = { x: LANE_X + LANE_W / 2, y: H - bottom - E.lane.offsetHeight / 2 };
      const dx = (R.desc.x + 120) - laneRect.x, dy = (R.desc.cy) - laneRect.y;
      tf = `translate(${(dx * f).toFixed(1)}px, ${(dy * f).toFixed(1)}px) scale(${lerp(1, 0.28, f).toFixed(3)})`; op = 1 - p(f, 0.45, 1, 'in'); clip = 'none';
    }
    css(E.lane, { opacity: op.toFixed(3), bottom: bottom.toFixed(1) + 'px', transform: tf, clipPath: clip });
    // alternatives menu under the low-confidence word (inside the lane's field)
    const spLow = E['lane-text'].__spans[L.toks.findIndex(x => x.key === 'u3-pl')];
    if (spLow) { const r = spLow.getBoundingClientRect(); E.altRect = { x: r.left, y: r.bottom + 10, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }
    if (altOp > 0 && spLow) css(E.altmenu, { opacity: altOp.toFixed(3), left: (E.altRect.x - 8).toFixed(1) + 'px', top: (E.altRect.y - (1 - altOp) * 6).toFixed(1) + 'px' });
    else css(E.altmenu, { opacity: '0' });
    return L;
  }

  // ================================================================ deck command line
  function cmdAt(t) {
    const segs = [[T.fnDown4, T.fnUp4, T.regroup, 'rg'], [T.fnDown5, T.fnUp5, T.resolve, 'rs'], [T.fnDown6, T.fnUp6, T.approve, 'ap'], [T.fnDown7, T.fnUp7, T.auto, 'au'], [T.fnDown8, T.fnUp8, T.stripe, 'st'], [T.fnDown9, T.fnUp9, T.enable, 'en']];
    for (const [a, b, tlx, k] of segs) if (t >= a - 0.05 && t < b + 0.7) {
      const op = win(t, a, b + 0.7, 0.3, 0.45);
      const toks = k === 'au' ? wakeTokens(tlx, t, k, tlx[0].at + 0.9) : streamed(tlx, t, k);
      return { op, toks };
    }
    return null;
  }
  function renderCmd(t) {
    const c = cmdAt(t);
    if (!c) { css(E.cmdline, { opacity: '0' }); return; }
    renderTokens(E['cmd-words'], c.toks, 18, true);
    css(E.cmdline, { opacity: c.op.toFixed(3), top: (LINE_Y - 36).toFixed(1) + 'px', left: (DECK_X + 66) + 'px', transform: `translateY(${((1 - c.op) * 6).toFixed(1)}px)` });
  }

  // ================================================================ reader
  const SETS = {
    flora: { lbl: 'FLORA', src: '', speed: '1.1×', tls: () => T.reply, up: () => T.readerUp, down: () => T.readerDown },
    art: { lbl: 'reading', src: V.flora.anyText.source, speed: '1.2×', tls: () => T.art, up: () => T.reader2Up, down: () => T.reader2Down },
  };
  function readerAt(t) {
    for (const k in SETS) { const s = SETS[k]; const up = s.up(), dn = s.down(); if (t >= up - 0.05 && t < dn[1] + 0.05) return { set: k, r: p(t, up, up + 0.55, 'out') - p(t, dn[0], dn[1], 'inOut') }; }
    return null;
  }
  function renderReader(t) {
    const S = readerAt(t);
    if (!S || S.r <= 0) { css(E.reader, { opacity: '0' }); return null; }
    const set = SETS[S.set], tls = set.tls();
    if (E['rd-rows'].__set !== S.set) {
      E['rd-rows'].__set = S.set;
      E['rd-rows'].innerHTML = tls.map((s, i) => `<div class="rd-row" id="rr-${i}">${s.map((w, j) => `<span class="rw">${w.w}</span>`).join(' ')}</div>`).join('');
      E.rdRows = tls.map((s, i) => { const el = $('#rr-' + i); return { el, words: $$('.rw', el), h: el.offsetHeight }; });
      text(E['rd-lbl'], set.lbl); text(E['rd-src'], set.src); text(E['rd-speed'], set.speed);
      css(E['rd-src'], { fontSize: '15px', color: C.tx2 });
    }
    // fractional sentence index
    let s = 0; for (let k = 0; k < tls.length - 1; k++) s += p(t, endOf(tls[k]) - 0.2, tls[k + 1][0].at, 'inOut');
    const k0 = Math.min(tls.length - 1, Math.floor(s)), f = s - k0, k1 = Math.min(tls.length - 1, k0 + 1);
    const SC = 0.68, CUR_TOP = 66, GAP = 14;
    const layout = k => { const h = i => E.rdRows[i].h; const L = {};
      for (let i = 0; i < tls.length; i++) {
        const d = i - k;
        if (d === 0) L[i] = { y: CUR_TOP, sc: 1, op: 1, col: 'cur' };
        else if (d === -1) L[i] = { y: CUR_TOP - (h(i) * SC + GAP), sc: SC, op: 1, col: 'prev' };
        else if (d === -2) L[i] = { y: CUR_TOP - (h(i + 1) * SC + GAP) - (h(i) * SC + 10), sc: SC, op: 0, col: 'prev' };
        else if (d === 1) L[i] = { y: CUR_TOP + h(k) + GAP, sc: SC, op: 1, col: 'next' };
        else if (d === 2) L[i] = { y: CUR_TOP + h(k) + GAP + h(i - 1) * SC + 10, sc: SC, op: 0, col: 'next' };
        else L[i] = { y: d < 0 ? -80 : CUR_TOP + 200, sc: SC, op: 0, col: d < 0 ? 'prev' : 'next' };
      }
      // visible extents of this layout (prev · current · next)
      L.minY = k > 0 ? L[k - 1].y : L[k].y;
      L.maxY = k + 1 < tls.length ? L[k + 1].y + h(k + 1) * SC : L[k].y + h(k);
      return L; };
    const A = layout(k0), B = layout(k1);
    const shift = lerp(A.minY, B.minY, f), extent = lerp(A.maxY, B.maxY, f) - shift;
    let total = 0, spoken = 0;
    tls.forEach((tlx, i) => {
      const a = A[i], b = B[i], y = lerp(a.y, b.y, f) - shift, sc = lerp(a.sc, b.sc, f), op = lerp(a.op, b.op, f);
      const row = E.rdRows[i];
      // row base colour: prev → tx2, next → tx3, current → words decide
      let base = C.dim;
      if (a.col === 'cur' && b.col === 'prev') base = K.mix(C.tx, C.tx2, f);
      else if (a.col === 'prev') base = C.tx2;
      else if (a.col === 'next' && b.col === 'cur') base = C.dim;
      else if (a.col === 'next') base = C.tx3;
      else if (a.col === 'cur') base = C.tx;
      css(row.el, { transform: `translateY(${y.toFixed(1)}px) scale(${sc.toFixed(3)})`, opacity: op.toFixed(3), color: base });
      const isCur = (a.col === 'cur' && f < 0.999) || (b.col === 'cur' && f > 0.001);
      const n = tlx.length; total += n;
      let cnt = 0; for (const w of tlx) if (t >= w.at) cnt++;
      spoken += cnt;
      row.words.forEach((wEl, j) => {
        if (!isCur) { wEl.classList.remove('cur'); css(wEl, { color: '', backgroundImage: '' }); return; }
        const w = tlx[j];
        if (t < w.at) { wEl.classList.remove('cur'); css(wEl, { color: C.dim, backgroundImage: '' }); }
        else if (j + 1 < n && t >= tlx[j + 1].at || (j + 1 === n && t >= w.at + 0.4)) { wEl.classList.remove('cur'); css(wEl, { color: C.tx, backgroundImage: '' }); }
        else { const nxt = j + 1 < n ? tlx[j + 1].at : w.at + 0.4; const q = clamp((t - w.at) / (nxt - w.at)) * 100;
          wEl.classList.add('cur'); css(wEl, { color: 'transparent', backgroundImage: `linear-gradient(90deg, ${C.tx} ${q.toFixed(1)}%, ${C.amber} ${(q + 6).toFixed(1)}%)` }); }
      });
    });
    // container height follows the visible rows (speaker line + rows), bottom-anchored on the horizon
    const hgt = 34 + extent + 6;
    css(E.reader, { height: hgt.toFixed(1) + 'px', bottom: '64px', opacity: Math.min(1, S.r * 2.5).toFixed(3), transform: `translateY(${((1 - S.r) * 18).toFixed(1)}px)`, clipPath: `inset(calc(${((1 - S.r) * 100).toFixed(1)}% - 70px) -130px -50px -130px)` });
    return { frac: total ? spoken / total : 0 };
  }

  // ================================================================ horizon rendering
  const linePts = new Array(120);
  function renderHorizon(t, hp, readFrac) {
    const w = hp.w, x0 = CX - w / 2, x1 = CX + w / 2, env = envelope(t) * hp.wave;
    // waveform line
    const N = 96; let d = '';
    for (let i = 0; i <= N; i++) {
      const x = x0 + (w * i) / N, u = i / N, taper = Math.sin(Math.PI * u);
      const n = (noise(x * 0.016 + t * 2.4, 3) - 0.5) * 2 * (0.55 + 0.45 * (noise(x * 0.05 - t * 1.6, 7)));
      const y = LINE_Y + env * 6.5 * n * Math.pow(taper, 0.7);
      linePts[i] = [x, y]; d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(2);
    }
    E['hz-line'].setAttribute('d', d);
    E.lg.setAttribute('x1', x0); E.lg.setAttribute('x2', x1);
    // progress / recording fill (bright part)
    let pf = 0;
    if (hp.prog > 0.01 && readFrac != null) pf = readFrac * hp.prog;
    if (hp.rec > 0.01) pf = clamp((t - T.capStart) / 30) * hp.rec;
    if (pf > 0) { const xe = x0 + w * pf; E['hz-prog'].setAttribute('d', `M${x0.toFixed(1)} ${LINE_Y}L${xe.toFixed(1)} ${LINE_Y}`); E.lgb.setAttribute('x1', x0); E.lgb.setAttribute('x2', x0 + 60); css(E['hz-prog'], { opacity: Math.max(hp.prog, hp.rec).toFixed(3) }); }
    else css(E['hz-prog'], { opacity: '0' });
    // thinking light travelling along the contracted line
    if (hp.think > 0.01) { const u = (t * 0.55) % 1, xl = x0 + u * w; E['hz-glow'].setAttribute('d', `M${(xl - 45).toFixed(1)} ${LINE_Y}L${(xl + 45).toFixed(1)} ${LINE_Y}`); E.lga.setAttribute('x1', xl - 45); E.lga.setAttribute('x2', xl + 45); css(E['hz-glow'], { opacity: hp.think.toFixed(3) }); }
    else css(E['hz-glow'], { opacity: '0' });
    // dots
    const live = Math.max(hp.amber, fnHeld(t), hp.rec);
    const unread = t >= 4 && t < T.approved ? 1 - p(t, T.approved, T.approved + 0.5) : 0;
    const restF = 1 - Math.max(hp.dl, hp.prog, hp.think, hp.deck);
    const leftX = x0 + 12;
    for (let i = 0; i < 3; i++) {
      const xc = lerp(CX - 18 + i * 18, leftX + i * 18, hp.dl);
      const yi = LINE_Y + (env > 0 ? (linePts[Math.round(((xc - x0) / w) * N)] || [0, LINE_Y])[1] - LINE_Y : 0);
      const amberMix = i === 1 ? Math.max(live, unread * restF) : live;
      css(E['d' + i], { left: xc.toFixed(1) + 'px', top: yi.toFixed(2) + 'px', background: K.mix('#D9D5CC', C.amber, amberMix), opacity: '1' });
      if (i === 1) css(E['dot-ring'], { left: xc.toFixed(1) + 'px', top: yi.toFixed(2) + 'px', opacity: (unread * restF * (1 - live)).toFixed(3) });
    }
    // think line + receipts
    const thinkOp = win(t, T.think[0], T.think[1] + 0.2, 0.3, 0.3);
    text(E.think, V.flora.thinking); css(E.think, { opacity: thinkOp.toFixed(3), top: (LINE_Y - 34).toFixed(1) + 'px' });
    let rc = null;
    if (t >= T.receipt1[0] && t < T.receipt1[1]) rc = { s: V.dictation.receipt, op: win(t, T.receipt1[0], T.receipt1[1], 0.3, 0.4) };
    else if (t >= T.capEnd + 0.6 && t < T.payUp[1]) rc = { s: `${V.capture.length} · ${V.capture.marks} marks · ${V.capture.shots} shots`, op: win(t, T.capEnd + 0.6, T.payUp[1], 0.3, 0.4) };
    else if (t >= T.receipt2[0] && t < T.receipt2[1]) rc = { s: V.handoff.copied, op: win(t, T.receipt2[0], T.receipt2[1], 0.3, 0.4) };
    if (rc) { text(E.receipt, rc.s); css(E.receipt, { opacity: rc.op.toFixed(3), top: (LINE_Y - 34 + (1 - rc.op) * 4).toFixed(1) + 'px' }); } else css(E.receipt, { opacity: '0' });
    // capture ticks + thumbnails
    T.ann.forEach((a, i) => {
      const anchorT = [T.anchor0, T.anchor1, T.anchor2, T.anchor3][i];
      const on = hp.rec > 0.01 && t >= anchorT;
      const xt = x0 + w * clamp(a.t / 30);
      css(E.tickEls[i], { opacity: on ? (hp.rec * p(t, anchorT, anchorT + 0.25)).toFixed(3) : '0', left: xt.toFixed(1) + 'px', top: LINE_Y + 'px' });
      const th = E.thumbEls[i];
      if (on && t < anchorT + 2.1) {
        if (!th.__built) { th.__built = true; th.innerHTML = thumbSVG(i); }
        const rise = p(t, anchorT, anchorT + 0.35, 'out'), sink = p(t, anchorT + 1.6, anchorT + 2.05, 'in');
        css(th, { opacity: (rise * (1 - sink)).toFixed(3), left: xt.toFixed(1) + 'px', top: (LINE_Y - 14 - 60).toFixed(1) + 'px', transform: `translateY(${((1 - rise) * 22 + sink * 40).toFixed(1)}px) scale(${lerp(1, 0.15, sink).toFixed(3)})` });
      } else css(th, { opacity: '0' });
    });
  }

  // ================================================================ deck: control center
  function layoutCC(grouping, include, presence, expanded) {
    const groups = grouping === 'project' ? V.projects : V.components, key = grouping === 'project' ? 'project' : 'component';
    const colW = BODY_W / groups.length, pos = {}, counts = groups.map(() => 0);
    groups.forEach((g, ci) => { let y = ROWS_TOP; V.sessions.filter(s => s[key] === g && include(s)).forEach(s => { const pr = presence[s.id] == null ? 1 : presence[s.id]; counts[ci] += pr; pos[s.id] = { x: BODY_PAD + ci * colW, y, w: colW, pr, ci }; y += (rowH(s) + (expanded[s.id] || 0) * EXP_H) * pr; }); });
    return { pos, colW, counts, n: groups.length };
  }
  const GL = ['needs', 'failed', 'review', 'running', 'idle', 'done'];
  function renderCC(t) {
    const flipF = p(t, T.flip[0], T.flip[1] - 0.6, 'inOut'); // header/divider cross-fade
    const hOut = 1 - p(t, T.flip[0], T.flip[0] + 0.35, 'inOut'), hIn = p(t, T.flip[1] - 0.75, T.flip[1] - 0.3, 'inOut');
    const grouping = t < T.flip[0] + 0.01 ? 'project' : 'component';
    const presence = {}, checkF = {};
    DONE.forEach((s, k) => { const a = T.resolveAnim[0] + k * 0.07; checkF[s.id] = p(t, a, a + 0.25, 'out'); presence[s.id] = 1 - p(t, a + 0.45, a + 0.95, 'inOut'); });
    const resolvedView = p(t, T.clickResolved + 0.05, T.clickResolved + 0.45, 'inOut') - p(t, T.clickWorkbench + 0.05, T.clickWorkbench + 0.45, 'inOut');
    const expandP = p(t, T.expand[0], T.expand[1], 'out') * (1 - p(t, T.approved + 1.3, T.approved + 1.8, 'inOut'));
    const expanded = { 1: expandP };
    const approvedQ = p(t, T.approved, T.approved + 0.5, 'inOut');
    // layouts
    const wbA = layoutCC('project', s => true, presence, expanded), wbB = layoutCC('component', s => true, presence, expanded);
    const rsB = layoutCC('component', s => s.status === 'done', {}, {});
    let wbCount = 0, rsCount = 0;
    V.sessions.forEach((s, idx) => {
      const r = E.rows[s.id]; const done = s.status === 'done';
      let x, y, pr, colW;
      if (done && resolvedView > 0.001 && presence[s.id] < 0.5) { const q = rsB.pos[s.id]; x = q.x; y = q.y; pr = resolvedView; colW = rsB.colW; }
      else {
        const a = wbA.pos[s.id], b = wbB.pos[s.id];
        const fi = p(t, T.flip[0] + idx * 0.03, T.flip[0] + idx * 0.03 + 1.0, 'inOut');
        x = lerp(a.x, b.x, fi); y = lerp(a.y, b.y, fi) - Math.sin(Math.PI * fi) * 34 * (a.ci !== b.ci ? 1 : 0.3); colW = lerp(a.w, b.w, fi); pr = a.pr * (1 - resolvedView);
      }
      const op = pr; if (!done) wbCount += 1; else { if (presence[s.id] < 0.5) rsCount += 1; else wbCount += 1; }
      css(r.el, { transform: `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`, width: (colW - 4).toFixed(1) + 'px', opacity: clamp(op).toFixed(3), height: (rowH(s) + (expanded[s.id] || 0) * EXP_H).toFixed(1) + 'px' });
      // glyphs
      const gi = GL.indexOf(s.status);
      r.gl.forEach((g, i) => {
        let o = i === gi ? 1 : 0;
        if (s.id === 1) { if (i === gi) o = 1 - approvedQ; if (GL[i] === 'running') o = approvedQ; }
        css(g, { opacity: o.toFixed(3) });
        if (GL[i] === 'done') g.classList.toggle('bright', done && (checkF[s.id] || 0) > 0.05 && presence[s.id] > 0.05);
      });
      if (r.pri) css(r.pri, { opacity: s.id === 1 ? (1 - approvedQ).toFixed(3) : '1' });
      if (r.mb) { css(r.ma, { opacity: (1 - approvedQ).toFixed(3) }); css(r.mb, { opacity: approvedQ.toFixed(3) }); }
      if (r.detail) css(r.detail, { opacity: expandP.toFixed(3), height: (expandP * EXP_H).toFixed(1) + 'px' });
    });
    // column headers + dividers
    const colFade = grouping === 'project' ? 1 - flipF : 1 - flipF; // flipF: 0 → project, 1 → component
    const headers = (els, lay, base) => els.forEach((h, i) => { css(h, { left: (BODY_PAD + i * lay.colW + 58).toFixed(1) + 'px', opacity: base.toFixed(3) }); text(h.lastChild, String(Math.round(lay.counts[i]))); });
    const resolvedCounts = rsB.counts;
    const wbHeadOp = 1 - resolvedView;
    headers(E.hp, wbA, hOut * wbHeadOp);
    // component headers show workbench counts, or resolved counts in the resolved view
    E.hc.forEach((h, i) => { css(h, { left: (BODY_PAD + i * wbB.colW + 58).toFixed(1) + 'px', opacity: Math.max(hIn * wbHeadOp, resolvedView).toFixed(3) }); text(h.lastChild, String(Math.round(resolvedView > 0.5 ? resolvedCounts[i] : wbB.counts[i]))); });
    E.dp.forEach((d, i) => css(d, { left: (BODY_PAD + (i + 1) * wbA.colW - 14).toFixed(1) + 'px', opacity: (hOut * wbHeadOp).toFixed(3) }));
    E.dc.forEach((d, i) => css(d, { left: (BODY_PAD + (i + 1) * wbB.colW - 14).toFixed(1) + 'px', opacity: Math.max(hIn, resolvedView).toFixed(3) }));
    // tabs
    const wbShown = Math.round(20 - DONE.reduce((a, s) => a + (1 - presence[s.id]), 0)), rsShown = 20 - wbShown;
    text(E.wbN, String(wbShown)); text(E.rsN, rsShown > 0 ? String(rsShown) : '');
    const ulA = { x: E.tabWb.offsetLeft, w: E.tabWb.offsetWidth }, ulB = { x: E.tabRs.offsetLeft, w: E.tabRs.offsetWidth };
    css(E.tabUl, { left: lerp(ulA.x, ulB.x, resolvedView).toFixed(1) + 'px', width: lerp(ulA.w, ulB.w, resolvedView).toFixed(1) + 'px' });
    css(E.tabWb, { color: K.mix(C.tx, C.tx2, resolvedView) }); css(E.tabRs, { color: K.mix(C.tx2, C.tx, resolvedView) });
    css(E.grpA, { opacity: hOut.toFixed(3) }); css(E.grpB, { opacity: hIn.toFixed(3) });
    return { wbB, rsB, resolvedView };
  }

  // ================================================================ deck: automations, streams, payload
  function typed(el, s, q) { const n = Math.round(s.length * clamp(q)); text(el, s.slice(0, n)); }
  function renderAuto(t) {
    const au = V.automation, d = au.draft;
    const nameQ = p(t, T.draftFields[0], T.draftFields[0] + 0.45, 'inOut');
    css(E.anA, { opacity: (1 - nameQ).toFixed(3) }); css(E.anB, { opacity: nameQ.toFixed(3) });
    const schedQ = p(t, T.draftFields[1], T.draftFields[1] + 0.45, 'inOut'), nextQ = p(t, T.active + 0.15, T.active + 0.6, 'inOut');
    css(E.asA, { opacity: (1 - schedQ).toFixed(3) }); css(E.asB, { opacity: (schedQ * (1 - nextQ)).toFixed(3) }); css(E.asC, { opacity: nextQ.toFixed(3) });
    const actQ = p(t, T.active, T.active + 0.45, 'inOut');
    css(E.swA, { opacity: (1 - actQ).toFixed(3) }); css(E.swB, { opacity: actQ.toFixed(3) });
    const vals = [d.name, d.schedule, d.deliver, d.access];
    vals.forEach((v, i) => { const a = T.draftFields[i], q = p(t, a, a + 0.55, 'linear'), rowOp = p(t, a - 0.1, a + 0.3, 'out'); typed(E.f[i], v, q); css(E.dl[i], { opacity: rowOp.toFixed(3), transform: `translateY(${((1 - rowOp) * 8).toFixed(1)}px)` }); });
    const s4 = p(t, T.draftStreams[0] - 0.1, T.draftStreams[0] + 0.3, 'out');
    css(E.dl[4], { opacity: s4.toFixed(3), transform: `translateY(${((1 - s4) * 8).toFixed(1)}px)` });
    au.streams.forEach((s, i) => { const a = T.draftStreams[i], q = p(t, a, a + 0.35, 'out'); let on = s.on ? 1 : p(t, T.stripeOn, T.stripeOn + 0.4, 'inOut');
      css(E.ds[i], { opacity: q.toFixed(3), transform: `translateY(${((1 - q) * 8).toFixed(1)}px)` });
      css($('.on', E.ds[i]), { opacity: on.toFixed(3) }); css($('.off', E.ds[i]), { opacity: (1 - on).toFixed(3) });
      const da = $('.sd-a', E.ds[i]), db = $('.sd-b', E.ds[i]); if (da) { css(da, { opacity: (1 - on).toFixed(3) }); css(db, { opacity: on.toFixed(3) }); } });
    const s5 = p(t, T.draftStreams[3] + 0.3, T.draftStreams[3] + 0.7, 'out');
    css(E.dl[5], { opacity: s5.toFixed(3), transform: `translateY(${((1 - s5) * 8).toFixed(1)}px)` });
    css(E.stA, { opacity: (1 - actQ).toFixed(3) }); css(E.stB, { opacity: actQ.toFixed(3) });
    const crumbQ = p(t, T.streamsView[0], T.streamsView[1], 'inOut');
    css(E.crumbA, { opacity: (1 - crumbQ).toFixed(3) }); css(E.crumbB, { opacity: crumbQ.toFixed(3) });
    css(E.tabStreams, { color: K.mix(C.tx2, C.tx, crumbQ) });
  }
  function renderStreams(t) {
    const all = [...V.automation.streams.map(s => ({ ...s, on: s.on || t >= T.stripeOn })), ...V.automation.otherStreams.map(s => ({ ...s, on: true }))];
    all.forEach((s, i) => { const q = p(t, T.streamsView[0] + i * 0.04, T.streamsView[0] + i * 0.04 + 0.35, 'out'); css(E.st[i], { opacity: q.toFixed(3), transform: `translateY(${((1 - q) * 6).toFixed(1)}px)` }); css($('.on', E.st[i]), { opacity: s.on ? '1' : '0' }); css($('.off', E.st[i]), { opacity: s.on ? '0' : '1' });
      const da = $('.sd-a', E.st[i]), db = $('.sd-b', E.st[i]); if (da) { css(da, { opacity: s.on ? '0' : '1' }); css(db, { opacity: s.on ? '1' : '0' }); } });
  }
  function renderDeck(t) {
    let r = 0;
    if (t >= T.deckUp[0] - 0.05 && t < T.deckDown[1] + 0.05) r = p(t, T.deckUp[0], T.deckUp[1], 'out') - p(t, T.deckDown[0], T.deckDown[1], 'inOut');
    else if (t >= T.payUp[0] - 0.05 && t < T.payDown[1] + 0.05) r = p(t, T.payUp[0], T.payUp[1], 'out') - p(t, T.payDown[0], T.payDown[1], 'inOut');
    if (r <= 0) { css(E.deck, { opacity: '0' }); return null; }
    // header-first sheet: slides up while clipped at its resting bottom edge, so it grows upward out of the horizon
    const dy = (1 - r) * 600;
    css(E.deck, { opacity: Math.min(1, r * 3).toFixed(3), transform: `translateY(${dy.toFixed(1)}px)`, clipPath: `inset(0 0 ${dy.toFixed(1)}px 0 round 16px)` });
    const ccOp = 1 - p(t, T.autoView, T.autoView + 0.45, 'inOut');
    const autoOp = t < T.payUp[0] - 0.1 ? p(t, T.autoView, T.autoView + 0.45, 'inOut') - p(t, T.streamsView[0], T.streamsView[1], 'inOut') : 0;
    const strOp = t < T.payUp[0] - 0.1 ? p(t, T.streamsView[0], T.streamsView[1], 'inOut') : 0;
    const payOp = t >= T.payUp[0] - 0.1 ? 1 : 0;
    css(E.views.cc, { opacity: (payOp ? 0 : ccOp).toFixed(3) }); css(E.views.auto, { opacity: autoOp.toFixed(3) }); css(E.views.streams, { opacity: strOp.toFixed(3) }); css(E.views.pay, { opacity: payOp.toFixed(3) });
    let cc = null;
    if (!payOp && ccOp > 0) cc = renderCC(t);
    if (autoOp > 0) renderAuto(t);
    if (strOp > 0) renderStreams(t);
    if (payOp && !E.__payBuilt) { E.__payBuilt = true; E.payThumbs.forEach((el, i) => { el.innerHTML = thumbSVG(i); }); }
    return { r, cc };
  }

  // ================================================================ annotations (inside the Chrome page, content coordinates)
  const ANN = {};
  function ellipsePath(cx, cy, rx, ry, amp, seed, drawn) {
    const N = 80; let d = '';
    for (let i = 0; i <= N * drawn; i++) { const u = i / N, a = -1.25 + u * Math.PI * 2.12; const m = 1 + (noise(u * 9, seed) - 0.5) * 2 * (amp / rx); const x = cx + Math.cos(a) * rx * m + (noise(u * 5 + 3, seed + 1) - 0.5) * amp * 0.6, y = cy + Math.sin(a) * ry * m; d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1); }
    return d;
  }
  function quadPt(a, c, b, u) { const x = (1 - u) * (1 - u) * a[0] + 2 * (1 - u) * u * c[0] + u * u * b[0], y = (1 - u) * (1 - u) * a[1] + 2 * (1 - u) * u * c[1] + u * u * b[1]; return [x, y]; }
  function buildMarks() {
    const svg = E.marks;
    const tue = R.cardTue, btn = R.btnShop, kc = R.kcalWed;
    ANN.circle = { cx: tue.x + tue.w / 2, cy: tue.y + tue.h / 2, rx: tue.w / 2 + 14, ry: tue.h / 2 + 12 };
    // arrow: down the gutter between the card columns, then a hook into the button's top-right corner
    ANN.arrow = { a: [tue.x - 12, tue.y + tue.h + 16], c: [tue.x - 8, btn.y - 34], b: [btn.x + btn.w - 34, btn.y - 7] };
    ANN.label = { x: btn.x + 2, y: btn.y + btn.h + 27 };
    ANN.strike = { a: [kc.x - 4, kc.y + kc.h * 0.58], b: [kc.x + kc.w + 5, kc.y + kc.h * 0.46] };
    ANN.anchors = [tue, btn, btn, { x: kc.x - 2, y: kc.y - 1, w: kc.w + 4, h: kc.h + 2 }];
    ANN.tags = ['⌖ meal-card · Tue', '⌖ button · Shopping list', '⌖ button · Shopping list', '⌖ meal-card · Wed · 540 kcal'];
    svg.innerHTML = `
      <g id="mk-ink" fill="none" stroke="${C.amber}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="filter:drop-shadow(0 1px 1px rgba(0,0,0,.18))">
        <path id="mk-circle"/><path id="mk-arrow"/><path id="mk-head"/><path id="mk-strike"/></g>
      <text id="mk-label" x="${ANN.label.x}" y="${ANN.label.y}" font-size="22" font-weight="600" fill="${C.amber}" style="filter:drop-shadow(0 1px 2px rgba(14,13,12,.45))"></text>
      ${[0, 1, 2, 3].map(i => { const an = ANN.anchors[i], tw = measure(ANN.tags[i], 13) * 1.06 + 16; return `<g id="mk-anchor-${i}" opacity="0"><rect x="${an.x - 4}" y="${an.y - 4}" width="${an.w + 8}" height="${an.h + 8}" rx="6" fill="none" stroke="${C.amber}" stroke-width="1" stroke-dasharray="5 4"/><rect x="${an.x - 4}" y="${an.y - 30}" width="${tw.toFixed(0)}" height="22" rx="4" fill="${C.g}"/><text x="${an.x + 4}" y="${an.y - 14.5}" font-size="13" font-weight="600" fill="${C.amber}">${ANN.tags[i]}</text></g>`; }).join('')}`;
    ['mk-circle', 'mk-arrow', 'mk-head', 'mk-strike', 'mk-label', 'mk-ink'].forEach(id => E[id] = $('#' + id, svg));
    E.mkAnchors = [0, 1, 2, 3].map(i => $('#mk-anchor-' + i, svg));
  }
  function renderMarks(t, chromeFront) {
    const vis = chromeFront;
    css(E['mk-ink'], { opacity: vis.toFixed(3) }); css(E['mk-label'], { opacity: vis.toFixed(3) }); E.mkAnchors.forEach(g => css(g, { opacity: vis.toFixed(3) }));
    // circle
    const d0 = p(t, T.draw0[0], T.draw0[1], 'inOut'), snap0 = p(t, T.anchor0, T.anchor0 + 0.45, 'inOut');
    const cd = d0 > 0 ? ellipsePath(ANN.circle.cx, ANN.circle.cy, ANN.circle.rx, ANN.circle.ry, lerp(7.5, 2.2, snap0), 4, d0) : '';
    if (E['mk-circle'].__d !== cd) { E['mk-circle'].__d = cd; E['mk-circle'].setAttribute('d', cd); }
    // arrow
    const d1 = p(t, T.draw1[0], T.draw1[1], 'inOut');
    let ad = '';
    if (d1 > 0) { const N = 40; for (let i = 0; i <= N * d1; i++) { const u = i / N; const [x, y] = quadPt(ANN.arrow.a, ANN.arrow.c, ANN.arrow.b, u); const jx = (noise(u * 6, 11) - 0.5) * 3, jy = (noise(u * 6, 12) - 0.5) * 3; ad += (i ? 'L' : 'M') + (x + jx).toFixed(1) + ' ' + (y + jy).toFixed(1); } }
    if (E['mk-arrow'].__d !== ad) { E['mk-arrow'].__d = ad; E['mk-arrow'].setAttribute('d', ad); }
    const hd = p(t, T.draw1[1] - 0.15, T.draw1[1] + 0.12, 'out');
    let hdd = '';
    if (hd > 0) { const [bx, by] = ANN.arrow.b, [px, py] = quadPt(ANN.arrow.a, ANN.arrow.c, ANN.arrow.b, 0.93); const ang = Math.atan2(by - py, bx - px), L = 18 * hd;
      const l1 = [bx - Math.cos(ang - 0.5) * L, by - Math.sin(ang - 0.5) * L], l2 = [bx - Math.cos(ang + 0.5) * L, by - Math.sin(ang + 0.5) * L];
      hdd = `M${l1[0].toFixed(1)} ${l1[1].toFixed(1)}L${bx} ${by}L${l2[0].toFixed(1)} ${l2[1].toFixed(1)}`; }
    if (E['mk-head'].__d !== hdd) { E['mk-head'].__d = hdd; E['mk-head'].setAttribute('d', hdd); }
    // label typed by voice: the words after the colon in annotation 3's speech
    const sp2 = T.annSpeech[2]; const labelWords = V.annotations[2].text.split(' '); const startIdx = sp2.length - labelWords.length;
    let shown = 0; for (let i = startIdx; i < sp2.length; i++) if (t >= sp2[i].at) shown = i - startIdx + 1;
    text(E['mk-label'], labelWords.slice(0, shown).join(' '));
    // strike
    const d3 = p(t, T.draw3[0], T.draw3[1], 'inOut');
    let sd = '';
    if (d3 > 0) { const N = 16; for (let i = 0; i <= N * d3; i++) { const u = i / N; const x = lerp(ANN.strike.a[0], ANN.strike.b[0], u), y = lerp(ANN.strike.a[1], ANN.strike.b[1], u) + (noise(u * 5, 21) - 0.5) * 2.2; sd += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1); } }
    if (E['mk-strike'].__d !== sd) { E['mk-strike'].__d = sd; E['mk-strike'].setAttribute('d', sd); }
    // anchoring cues
    [T.anchor0, T.anchor1, T.anchor2, T.anchor3].forEach((a, i) => { const o = win(t, a, a + 0.85, 0.12, 0.3) * vis; css(E.mkAnchors[i], { opacity: o.toFixed(3) }); });
  }
  // miniature of the plan page with the mark, for ticks + payload (content coordinates, viewBox = chrome content)
  function thumbSVG(i) {
    const cw = R.chromeContent.w, ch = R.chromeContent.h;
    const cards = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map(d => R['card' + d]);
    let mark = '';
    if (i === 0) mark = `<path d="${ellipsePath(ANN.circle.cx, ANN.circle.cy, ANN.circle.rx, ANN.circle.ry, 2.2, 4, 1)}" fill="none" stroke="${C.amber}" stroke-width="9"/>`;
    if (i === 1) { const pts = []; for (let k = 0; k <= 20; k++) { const [x, y] = quadPt(ANN.arrow.a, ANN.arrow.c, ANN.arrow.b, k / 20); pts.push((k ? 'L' : 'M') + x.toFixed(0) + ' ' + y.toFixed(0)); } mark = `<path d="${pts.join('')}" fill="none" stroke="${C.amber}" stroke-width="9"/>`; }
    if (i === 2) mark = `<rect x="${ANN.label.x}" y="${ANN.label.y - 22}" width="${measure(V.annotations[2].text, 22)}" height="24" fill="${C.amber}" opacity=".9"/>`;
    if (i === 3) mark = `<path d="M${ANN.strike.a[0]} ${ANN.strike.a[1]}L${ANN.strike.b[0]} ${ANN.strike.b[1]}" stroke="${C.amber}" stroke-width="9"/>`;
    return `<svg viewBox="0 0 ${cw} ${ch}" preserveAspectRatio="xMidYMid slice"><rect width="${cw}" height="${ch}" fill="#FAF7F2"/><rect width="${cw}" height="64" fill="#F4EFE7"/><rect x="40" y="22" width="22" height="22" rx="6" fill="#4F7A4A"/><rect x="72" y="24" width="120" height="16" rx="4" fill="#3F6B3A"/>
      <rect x="40" y="104" width="360" height="24" rx="4" fill="#26231F" opacity=".85"/>
      ${cards.map(c => `<rect x="${c.x}" y="${c.y}" width="${c.w}" height="${c.h}" rx="14" fill="#fff" stroke="#E2DACB" stroke-width="2"/><rect x="${c.x + 18}" y="${c.y + 17}" width="116" height="116" rx="10" fill="#D8B38A"/><rect x="${c.x + 150}" y="${c.y + 24}" width="60" height="12" rx="3" fill="#4F7A4A"/><rect x="${c.x + 150}" y="${c.y + 48}" width="190" height="16" rx="4" fill="#3A362F"/><rect x="${c.x + 150}" y="${c.y + 72}" width="140" height="14" rx="4" fill="#3A362F" opacity=".7"/><rect x="${c.x + 150}" y="${c.y + 110}" width="120" height="12" rx="3" fill="#8A8377"/>`).join('')}
      <rect x="${R.btnShop.x}" y="${R.btnShop.y}" width="${R.btnShop.w}" height="${R.btnShop.h}" rx="10" fill="#4F7A4A"/><rect x="${R.btnShop.x + R.btnShop.w + 14}" y="${R.btnShop.y}" width="150" height="${R.btnShop.h}" rx="10" fill="#fff" stroke="#C9D7C4" stroke-width="2"/>
      ${mark}</svg>`;
  }

  // ================================================================ windows, chrome page, notion field
  function renderWindows(t) {
    const { st, since } = stackAt(t), front = st[st.length - 1];
    const lift = p(t, since, since + 0.28, 'out');
    const els = { notion: E['win-notion'], chrome: E['win-chrome'], term: E['win-term'] };
    st.forEach((n, i) => { const isF = i === st.length - 1; css(els[n], { zIndex: String(10 + i), transform: isF && since > 0 ? `scale(${lerp(0.992, 1, lift).toFixed(4)})` : 'none' }); });
    // menu bar app name
    const q = since > 0 ? lift : 1;
    css(E['mb-app-a'], { opacity: front === 'notion' ? q.toFixed(3) : (st[st.length - 2] === 'notion' && since > 0 ? (1 - q).toFixed(3) : '0') });
    css(E['mb-app-b'], { opacity: front === 'chrome' ? q.toFixed(3) : (st[st.length - 2] === 'chrome' && since > 0 ? (1 - q).toFixed(3) : '0') });
    css(E['mb-app-c'], { opacity: front === 'term' ? q.toFixed(3) : '0' });
    // chrome: tab + page
    const planQ = p(t, T.clickPlanTab + 0.03, T.clickPlanTab + 0.25, 'inOut');
    E['c-tab-plan'].classList.toggle('cur', planQ > 0.5); E['c-tab-art'].classList.toggle('cur', planQ <= 0.5);
    css(E['page-plan'], { opacity: planQ.toFixed(3) }); css(E['page-art'], { opacity: (1 - planQ).toFixed(3) });
    css(E['c-url-a'], { opacity: planQ.toFixed(3) }); css(E['c-url-b'], { opacity: (1 - planQ).toFixed(3) });
    const scroll = 150 * p(t, T.scroll[0], T.scroll[1], 'inOut');
    css(E['pl-scroll'], { transform: `translateY(${(-scroll).toFixed(1)}px)` });
    // article selection
    if (t >= T.selDrag[0] - 0.05 && E.artWords.length) {
      const q = p(t, T.selDrag[0], T.selDrag[1], 'inOut'), n = Math.round(E.artWords.length * q);
      E.artWords.forEach((w, i) => w.classList.toggle('sel', i < n && t < T.clickPlanTab));
      E.artGaps.forEach((g, i) => g.classList.toggle('sel', E.artWords.indexOf(g.previousElementSibling) < n - 1 && t < T.clickPlanTab));
    } else { E.artWords.forEach(w => w.classList.remove('sel')); E.artGaps.forEach(g => g.classList.remove('sel')); }
    // notion description field
    const focus = t >= T.clickField ? 1 - p(t, T.cap3, T.cap3 + 0.4, 'inOut') : 0;
    const landed = p(t, T.flight[0] + 0.5, T.flight[0] + 0.95, 'out');
    css(E.nFocus, { opacity: (focus * 1).toFixed(3) }); css(E.nCaret, { opacity: (focus * (1 - landed)).toFixed(3) });
    css(E.nEmpty, { opacity: (t >= T.clickField ? 0 : 1).toFixed(3) }); css(E['n-desc-text'], { opacity: landed.toFixed(3) });
    // terminal paste
    text(E['t-paste'], t >= T.cmdV + 0.08 ? V.handoff.pastedLine : '');
    return { front, chromeFront: front === 'chrome' ? (since > 0 ? lift : 1) : (st[st.length - 2] === 'chrome' && since > 0 ? 1 - lift : 0), scroll };
  }

  // ================================================================ captions, HUD, cursor, title/end
  function renderCaption(t) {
    let cur = null; for (const c of CAPS) if (t >= c[0]) cur = c;
    if (!cur) { css(E.caption, { opacity: '0' }); return; }
    const lab = p(t, cur[0], cur[0] + 0.35, 'out'), line = win(t, cur[0], cur[0] + 3.8, 0.4, 0.6);
    text(E['cap-label'], cur[1]); text(E['cap-line'], cur[2]);
    css(E.caption, { opacity: '1' }); css(E['cap-label'], { opacity: lab.toFixed(3) });
    css(E['cap-line'], { opacity: line.toFixed(3), transform: `translateY(${((1 - p(t, cur[0], cur[0] + 0.5, 'out')) * 8).toFixed(1)}px)` });
  }
  function renderHUD(t) {
    let cur = null; for (const h of HUD) if (t >= h.a - 0.2 && t < h.b + 0.35) cur = h;
    if (!cur) { css(E.hudEl, { opacity: '0' }); return; }
    const key = cur.keys.join('+') + (cur.held ? 'H' : '') + (cur.note || '');
    if (E.hudEl.__key !== key) { E.hudEl.__key = key; E.hudEl.innerHTML = cur.keys.map(k => `<kbd class="${cur.held ? 'held' : ''}">${k}</kbd>`).join('') + (cur.note ? `<span class="note">${cur.note}</span>` : ''); }
    const o = win(t, cur.a - 0.2, cur.b + 0.35, 0.2, 0.3);
    css(E.hudEl, { opacity: o.toFixed(3), transform: `translateY(${((1 - o) * 6).toFixed(1)}px)` });
  }
  let WP = [], ALT_PT = [0, 0];
  function buildCursor() {
    const desc = R.desc, tabPlan = R.tabPlan;
    const field = [desc.x + 90, desc.cy + 2];
    const wbB = layoutCC('component', s => true, Object.fromEntries(DONE.map(s => [s.id, 0])), {});
    const q1 = wbB.pos[1]; const checkoutPt = [DECK_X + q1.x + 120, DECK_TOP + 58 + q1.y + 18];
    const tue = R.cardTue, so = R.scrollOrigin;
    const circleStart = (() => { const a = -1.25; return [so.x + ANN.circle.cx + Math.cos(a) * ANN.circle.rx, so.y + ANN.circle.cy + Math.sin(a) * ANN.circle.ry]; })();
    const arrowStart = [so.x + ANN.arrow.a[0], so.y + ANN.arrow.a[1]];
    WP = [
      [0, 1180, 640], [6.4, 1180, 640], [9.3, ...field], [T.altMove - 0.2, ...field],
      // alt menu handled by override; after picking, drift up out of the lane
      [T.altPick + 0.9, ...ALT_PT], [T.altPick + 1.9, desc.x + 420, desc.cy - 70], [T.cmdTab1, desc.x + 420, desc.cy - 70],
      // 3b selection: handled by override from selMove[0] to selDrag[1]
      [T.selDrag[1] + 0.9, R.artWords[R.artWords.length - 1].x + 120, R.artWords[R.artWords.length - 1].y + 60], [T.fnUp3, R.artWords[R.artWords.length - 1].x + 120, R.artWords[R.artWords.length - 1].y + 60],
      [T.deckUp[1], 1760, 340], [T.clickResolved - 1.3, 1760, 340], [T.clickResolved - 0.15, 0, 0 /* tab-rs (override) */], [T.clickWorkbench - 0.15, 0, 0], [T.clickCheckout - 1.4, 0, 0],
      [T.clickCheckout - 0.15, ...checkoutPt], [T.approved + 0.6, ...checkoutPt], [T.approved + 1.6, 1760, 360], [T.clickStreams - 1.2, 1760, 360], [T.clickStreams - 0.15, 0, 0 /* tab-streams (override) */],
      [T.clickStreams + 1.0, 0, 0], [T.deckDown[1], 1760, 640], [T.clickPlanTab - 1.2, 1760, 640], [T.clickPlanTab - 0.12, tabPlan.cx, tabPlan.cy], [T.clickPlanTab + 0.6, tabPlan.cx, tabPlan.cy],
      [T.draw0[0] - 0.1, ...circleStart], [T.draw0[1], ...circleStart /* override draws */], [T.draw1[0] - 0.1, ...arrowStart], [T.draw1[1], ...arrowStart],
      [T.draw1[1] + 1.2, so.x + 1180, so.y + 560], [T.scroll[0] - 0.6, so.x + 1180, so.y + 560], [T.scroll[0] - 0.05, so.x + 900, so.y + 600], [T.cmdTab2, so.x + 900, so.y + 600],
      [T.clickTerm - 1.3, so.x + 900, so.y + 600], [T.clickTerm - 0.12, R.termStrip.x, R.termStrip.y], [T.cmdV, R.termStrip.x, R.termStrip.y], [T.cmdV + 1.5, R.termStrip.x + 190, R.termStrip.y - 50], [T.fadeOut[1], R.termStrip.x + 190, R.termStrip.y - 50],
    ];
    WP.sort((a, b) => a[0] - b[0]);
  }
  function tabPoint(el) { const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2 + 1]; }
  function cursorAt(t, cc) {
    // overrides
    if (t >= T.altMove && t < T.altPick + 0.9 && E.altRect) {
      const from = [R.desc.x + 90, R.desc.cy + 2], word = [E.altRect.cx, E.altRect.cy + 6];
      if (t < T.altClick + 0.4) { const q = p(t, T.altMove, T.altClick - 0.1, 'inOut'); return [lerp(from[0], word[0], q), lerp(from[1], word[1], q)]; }
      if (t >= T.altPick - 0.15) return ALT_PT;
      const row = [E.altRect.x + 44, E.altRect.y + 18]; const q = p(t, T.altClick + 0.5, T.altPick - 0.15, 'inOut'); return [lerp(word[0], row[0], q), lerp(word[1], row[1], q)];
    }
    if (t >= T.selMove[0] && t < T.selDrag[1] + 0.9) {
      const w0 = R.artWords[0], wn = R.artWords[R.artWords.length - 1];
      const start = [w0.x - 2, w0.y + w0.h / 2], end = [wn.x + wn.w + 2, wn.y + wn.h / 2];
      const from = [R.desc.x + 420, R.desc.cy - 70];
      if (t < T.selDrag[0]) { const q = p(t, T.selMove[0], T.selMove[1], 'inOut'); return [lerp(from[0], start[0], q), lerp(from[1], start[1], q)]; }
      const q = p(t, T.selDrag[0], T.selDrag[1], 'inOut');
      // drag along the words (through the paragraph), landing on the last word
      const idx = Math.min(R.artWords.length - 1, Math.floor(q * (R.artWords.length - 1))), wq = R.artWords[idx];
      if (q >= 0.999) return end;
      return [wq.x + wq.w * (q * (R.artWords.length - 1) - idx), wq.y + wq.h / 2];
    }
    if (t >= T.clickResolved - 1.3 && t < T.clickCheckout - 1.4) {
      const a = [1760, 340], rs = tabPoint(E.tabRs), wb = tabPoint(E.tabWb);
      if (t < T.clickResolved - 0.15) { const q = p(t, T.clickResolved - 1.3, T.clickResolved - 0.15, 'inOut'); return [lerp(a[0], rs[0], q), lerp(a[1], rs[1], q)]; }
      if (t < T.clickWorkbench - 1.0) return rs;
      const q = p(t, T.clickWorkbench - 1.0, T.clickWorkbench - 0.15, 'inOut'); return [lerp(rs[0], wb[0], q), lerp(rs[1], wb[1], q)];
    }
    if (t >= T.clickCheckout - 1.4 && t < T.clickCheckout - 0.15) { const wb = tabPoint(E.tabWb), c = WP.find(w => w[0] === T.clickCheckout - 0.15); const q = p(t, T.clickCheckout - 1.4, T.clickCheckout - 0.15, 'inOut'); return [lerp(wb[0], c[1], q), lerp(wb[1], c[2], q)]; }
    if (t >= T.clickStreams - 1.2 && t < T.clickStreams + 1.0) { const a = [1760, 360], s = tabPoint(E.tabStreams); const q = p(t, T.clickStreams - 1.2, T.clickStreams - 0.15, 'inOut'); return [lerp(a[0], s[0], q), lerp(a[1], s[1], q)]; }
    if (t >= T.clickStreams + 1.0 && t < T.deckDown[1]) { const s = tabPoint(E.tabStreams); const q = p(t, T.clickStreams + 1.0, T.deckDown[1], 'inOut'); return [lerp(s[0], 1760, q), lerp(s[1], 640, q)]; }
    if (t >= T.draw0[0] && t < T.draw0[1]) { const d0 = p(t, T.draw0[0], T.draw0[1], 'inOut'); const a = -1.25 + d0 * Math.PI * 2.12; const so = R.scrollOrigin; const m = 1 + (noise(d0 * 9, 4) - 0.5) * 2 * (7.5 / ANN.circle.rx); return [so.x + ANN.circle.cx + Math.cos(a) * ANN.circle.rx * m + (noise(d0 * 5 + 3, 5) - 0.5) * 4.5, so.y + ANN.circle.cy + Math.sin(a) * ANN.circle.ry * m]; }
    if (t >= T.draw1[0] && t < T.draw1[1]) { const d1 = p(t, T.draw1[0], T.draw1[1], 'inOut'); const [x, y] = quadPt(ANN.arrow.a, ANN.arrow.c, ANN.arrow.b, d1); const so = R.scrollOrigin; return [so.x + x, so.y + y]; }
    if (t >= T.draw1[1] && t < T.draw1[1] + 1.2) { const so = R.scrollOrigin, b = [so.x + ANN.arrow.b[0], so.y + ANN.arrow.b[1]]; const q = p(t, T.draw1[1] + 0.3, T.draw1[1] + 1.2, 'inOut'); return [lerp(b[0], so.x + 1180, q), lerp(b[1], so.y + 560, q)]; }
    return kf2(t, WP.map(w => [w[0], [w[1], w[2]]]));
  }
  function renderCursor(t) {
    if (t < 4) { css(E.cursor, { opacity: '0' }); css(E.ripple, { opacity: '0' }); return; }
    const [x, y] = cursorAt(t);
    css(E.cursor, { opacity: '1', transform: `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)` });
    let rp = 0, rx = x, ry = y;
    for (const c of CLICKS) if (t >= c && t < c + 0.4) { rp = (t - c) / 0.4; }
    if (rp > 0) css(E.ripple, { opacity: (1 - rp).toFixed(3), transform: `translate(${(rx - 15 + 2).toFixed(1)}px, ${(ry - 15 + 2).toFixed(1)}px) scale(${(0.3 + rp * 1.1).toFixed(3)})` });
    else css(E.ripple, { opacity: '0' });
  }
  function renderTitleEnd(t) {
    if (t < T.titleEnd) { const o = win(t, 0, T.titleEnd, 0.9, 0.6); css(E.title, { visibility: 'visible', opacity: '1' }); $$('#title > *').forEach((el, i) => css(el, { opacity: o.toFixed(3), transform: `translateY(${((1 - p(t, 0.1 + i * 0.12, 0.9 + i * 0.12, 'out')) * 10).toFixed(1)}px)` })); }
    else css(E.title, { visibility: 'hidden', opacity: '0' });
    const eo = p(t, T.fadeOut[0], T.fadeOut[1], 'inOut');
    css(E.endcard, { opacity: eo.toFixed(3), visibility: eo > 0 ? 'visible' : 'hidden' });
    E.endLines.forEach((el, i) => { const q = p(t, T.endLine(i), T.endLine(i) + 0.6, 'out'); css(el, { opacity: q.toFixed(3), transform: `translateY(${((1 - q) * 10).toFixed(1)}px)` }); });
    const bq = p(t, T.endBrand, T.endBrand + 0.6, 'out'); css(E.endBrand, { opacity: bq.toFixed(3), transform: `translateY(${((1 - bq) * 8).toFixed(1)}px)` });
  }

  // ================================================================ renderAt
  window.renderAt = function (t) {
    const hp = hparams(t);
    const wn = renderWindows(t);
    renderMarks(t, wn.chromeFront);
    const rd = renderReader(t);
    renderLane(t, hp);
    renderDeck(t);
    renderCmd(t);
    renderHorizon(t, hp, rd ? rd.frac : null);
    renderCaption(t);
    renderHUD(t);
    renderCursor(t);
    renderTitleEnd(t);
  };

  // ================================================================ init
  function init() {
    D.build();
    buildFilm();
    R = D.measure();
    // all six cards for the thumbnails
    const s0 = R.scrollOrigin;
    ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].forEach(d => { const r = document.getElementById('card-' + d).getBoundingClientRect(); R['card' + d] = { x: r.left - s0.x, y: r.top - s0.y, w: r.width, h: r.height }; });
    buildMarks();
    // capture the alternatives-menu row point once (layout at the moment the menu is open) so the cursor can hold it purely
    window.renderAt(T.altClick + 0.6); ALT_PT = [E.altRect.x + 44, E.altRect.y + 18];
    buildCursor();
    window.renderAt(0);
    console.log('timeline', JSON.stringify({ u1End: T.u1End, fnUp1: T.fnUp1, cap3: T.cap3, readerUp: T.readerUp, replyEnd: T.replyEnd, cmdTab1: T.cmdTab1, artEnd: T.artEnd, deckUp: T.deckUp, flip: T.flip, resolveAnim: T.resolveAnim, approved: T.approved, cap5: T.cap5, active: T.active, deckDown: T.deckDown, capStart: T.capStart, capEnd: T.capEnd, payUp: T.payUp, cmdC: T.cmdC, cmdV: T.cmdV, endStart: T.endStart, DURATION: window.DURATION }, null, 0));
  }
  window.READY = (async () => { await document.fonts.ready; init(); })();
  const q = new URLSearchParams(location.search);
  if (q.has('t')) window.READY.then(() => window.renderAt(+q.get('t')));
})();
