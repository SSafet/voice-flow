// Concept C — Island: the film. Builds the DOM once; renderAt(t) is a pure function of t.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const s2 = T.s2, s3 = T.s3, s4 = T.s4, s5 = T.s5, s6 = T.s6, s7 = T.s7, s8 = T.s8;
  const C = Island.C;
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  window.DURATION = T.end;

  // ================= build =================
  Desktop.build();
  Island.build();
  Sheet.build();
  Island.readerBuild({ reply: D.flora.reply, article: D.flora.anyText.sentences });
  Island.recBuild([s6.a1, s6.a2, s6.a3, s6.a4]);
  Cap.build();
  const $ = id => document.getElementById(id);
  const E = { cursor: $('cursor'), ripple: $('ripple'), hud: $('hud'), cap: $('caption'), capL: $('caption').querySelector('.cap-l'), capS: $('caption').querySelector('.cap-s'), title: $('title'), end: $('endcard') };
  const notchSvg = `<svg class="t-notch" width="1920" height="60" xmlns="http://www.w3.org/2000/svg"><path d="M859 0A6 6 0 0 1 865 6L865 22A10 10 0 0 0 875 32L1045 32A10 10 0 0 0 1055 22L1055 6A6 6 0 0 1 1061 0Z" fill="#000"/><circle cx="1020" cy="22" r="2.5" fill="#F5F5F7" fill-opacity=".8"/><circle cx="1028" cy="22" r="2.5" fill="#F5F5F7" fill-opacity=".8"/><circle cx="1036" cy="22" r="2.5" fill="#F5F5F7" fill-opacity=".8"/></svg>`;
  E.title.innerHTML = `${notchSvg}<div class="t-name">VoiceFlow</div><div class="t-concept">Concept C — Island</div><div class="t-thesis">It lives in the notch.</div>`;
  E.tParts = [...E.title.children].slice(1); E.tNotch = E.title.querySelector('.t-notch');
  E.end.innerHTML = D.endCard.map(l => `<div class="e-line">${esc(l)}</div>`).join('') + `<div class="e-foot">VoiceFlow · Concept C — Island</div>`;
  E.eLines = [...E.end.querySelectorAll('.e-line')]; E.eFoot = E.end.querySelector('.e-foot');

  // ================= measurements =================
  const M = {};
  { const r = Desktop.screenRect(Desktop.$.nCaret); M.caret = { x: r.x, cy: r.y + r.h / 2 }; }
  { Desktop.setNotion(D.dictation.final, true, false); const r = Desktop.screenRect(Desktop.$.nCaret); M.caretEnd = { x: r.x, cy: r.y + r.h / 2 }; Desktop.setNotion('', false, true); }
  { const spans = Desktop.$.artSel.querySelectorAll(':scope > span');
    const r0 = spans[0].getClientRects()[0], rr = spans[2].getClientRects(); const r2 = rr[rr.length - 1];
    M.selStart = [r0.left + 1, r0.top + r0.height / 2]; M.selEnd = [r2.right + 1, r2.top + r2.height / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tabPlan); M.tabPlan = [r.x + r.w / 2, r.y + r.h / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tCaret); M.termCaret = [r.x + 4, r.y + r.h / 2]; }
  // receipt widths from the band text they carry
  const bandLeft = document.querySelector('#isl-in .b-left');
  function measureReceipt(h) { html(bandLeft, h); bandLeft.__html = null; const w = bandLeft.getBoundingClientRect().width; html(bandLeft, ''); return Math.min(346, Math.ceil(40 + w + 14)); }
  const RCPT1 = `<span class="ok">${esc(D.dictation.receipt)}</span>`, RCPT2 = `<span class="ok">${esc(D.handoff.copied)}</span>`, SUMM = `<span class="sum">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</span>`;
  M.rcpt1W = measureReceipt(RCPT1); M.rcpt2W = measureReceipt(RCPT2); M.summW = measureReceipt(SUMM);

  // ================= island geometry =================
  const H = Sheet.H;
  const geom = Motion.seq([
    { at: 0, w: 190, h: 32, r: 10, sh: 0 },
    { at: s2.mic, dur: 0.38, w: 440, h: 92, r: 14 },
    { at: s2.retract, dur: 0.4, w: 190, h: 32, r: 10, ease: 'inOut' },
    { at: s2.receipt[0] - 0.25, dur: 0.3, w: M.rcpt1W },
    { at: s2.receipt[1], dur: 0.3, w: 190, ease: 'inOut' },
    { at: s3.mic, dur: 0.38, w: 440, h: 92, r: 14 },
    { at: s3.think, dur: 0.35, h: 64 },
    { at: s3.morph, dur: 0.45, w: 528, h: 128 },
    { at: s3.fold, dur: 0.4, w: 190, h: 32, r: 10, ease: 'inOut' },
    { at: s3.reader2, dur: 0.4, w: 528, h: 128, r: 14 },
    { at: s3.barge, dur: 0.35, h: 64 },
    { at: s4.open, dur: 0.5, dur_sh: 0.28, w: 900, h: H.A, sh: 1 },
    { at: s4.regroupAnim, dur: 0.6, h: H.B },
    { at: s4.resolveAnim + 0.3, dur: 0.6, h: H.W },
    { at: s4.clickRes, dur: 0.45, h: H.R },
    { at: s4.clickWb, dur: 0.45, h: H.W },
    { at: s4.clickP1, dur: 0.45, h: H.W1 },
    { at: s5.route, dur: 0.5, h: H.AUTO },
    { at: s5.clickGl, dur: 0.45, h: H.GLANCE },
    { at: s5.close, dur: 0.45, dur_sh: 0.3, w: 190, h: 32, r: 10, sh: 0, ease: 'inOut' },
    { at: s6.c0, dur: 0.38, w: 348, h: 64, r: 12 },
    { at: s7.summary, dur: 0.35, w: M.summW, h: 32, r: 10 },
    { at: s7.sheet, dur: 0.5, dur_sh: 0.28, w: 900, h: H.PAY, r: 14, sh: 1 },
    { at: s7.copy, dur: 0.4, dur_sh: 0.3, w: 190, h: 32, r: 10, sh: 0, ease: 'inOut' },
    { at: s7.receipt[0] - 0.25, dur: 0.3, w: M.rcpt2W },
    { at: s7.receipt[1], dur: 0.3, w: 190, ease: 'inOut' },
  ], ['w', 'h', 'r', 'sh']);

  // ================= dots =================
  const MODES = [[0, 'rest'], [s2.mic, 'listen'], [s2.retract, 'rest'], [s3.mic, 'listen'], [s3.think, 'think'], [s3.morph + 0.4, 'speakF'], [s3.readEnd + 0.3, 'flora'], [s3.fold, 'rest'],
    [s3.reader2, 'speakA'], [s3.barge, 'listen'], [s3.show.end + 0.1, 'think'], [s4.open + 0.8, 'flora'],
    [s4.regroup.start - 0.3, 'listen'], [s4.regroup.end + 0.1, 'think'], [s4.regroupAnim + 1.0, 'flora'],
    [s4.resolve.start - 0.3, 'listen'], [s4.resolve.end + 0.1, 'think'], [s4.resolveAnim + 1.0, 'flora'],
    [s4.approve.start - 0.3, 'listen'], [s4.approve.end + 0.1, 'think'], [s4.approved + 0.4, 'flora'],
    [s5.say.start - 0.3, 'listen'], [s5.say.end + 0.1, 'think'], [s5.fAccess + 0.5, 'flora'],
    [s5.stripe.start - 0.3, 'listen'], [s5.stripe.end + 0.1, 'think'], [s5.stripeConn + 0.2, 'flora'],
    [s5.enable.start - 0.3, 'listen'], [s5.enable.end + 0.1, 'think'], [s5.active + 0.4, 'flora'],
    [s5.close, 'rest'], [s6.c0, 'record'], [s7.stop, 'rest']];
  const DOTP = {
    rest: { color: C.text, alpha: 0.8, chase: 0, conv: 0 }, listen: { color: C.live, alpha: 1, chase: 0, conv: 0 }, think: { color: C.flora, alpha: 1, chase: 1, conv: 0 },
    flora: { color: C.flora, alpha: 0.9, chase: 0, conv: 0 }, speakF: { color: C.flora, alpha: 1, chase: 0, conv: 0 }, speakA: { color: C.text, alpha: 0.95, chase: 0, conv: 0 }, record: { color: C.live, alpha: 1, chase: 0, conv: 1 },
  };
  function modeAt(t) { let i = 0; while (i + 1 < MODES.length && MODES[i + 1][0] <= t) i++; return { mode: MODES[i][1], since: MODES[i][0], prev: i > 0 ? MODES[i - 1][1] : 'rest' }; }
  function pulses(t) {
    const out = [0, 0, 0];
    for (const prog of [s3.read, s3.read2]) {
      if (t < prog.start || t > prog.end + 0.5) continue;
      let idx = 0;
      for (const s of prog.sentences) for (const w of s.words) { const d = t - w.at; if (d >= 0 && d < 0.5) out[idx % 3] += Math.exp(-d / 0.16); idx++; }
    }
    return out.map(v => Math.min(1, v));
  }
  function dotsState(t, w) {
    const m = modeAt(t), q = K.p(t, m.since, m.since + 0.3, 'inOut'), A = DOTP[m.prev], B = DOTP[m.mode];
    const color = K.mix(A.color, B.color, q), alpha = K.lerp(A.alpha, B.alpha, q), chase = K.lerp(A.chase, B.chase, q), conv = K.lerp(A.conv, B.conv, q);
    const pl = (m.mode.startsWith('speak') ? 1 : 0) * pulses(t);
    const scale = [0, 1, 2].map(i => 1 + 0.55 * (m.mode.startsWith('speak') ? pulses(t)[i] : 0));
    const unread = t >= T.title.b && t < s4.approved && m.mode === 'rest';
    return { place: K.clamp((w - 190) / 90), color, alpha, chase: chase > 0.02 ? chase : 0, converge: conv, scale, unread, t };
  }

  // ================= dictation tokens =================
  function tokensS2(t) {
    const out = []; const Wd = s2.u1.words;
    for (let i = 0; i < Wd.length; i++) {
      const w = Wd[i]; if (t < w.at) break;
      const tok = { key: 'a' + i, text: w.w, born: w.at, commit: w.at + 0.9 };
      if (i === 1) {
        if (t < s2.rev1.merge) { out.push({ key: 'a1', text: 'on', born: w.at, commit: 99 }); if (t >= w.at + 0.28) out.push({ key: 'a1b', text: 'boarding', born: w.at + 0.28, commit: 99 }); continue; }
        tok.swapAt = s2.rev1.merge; tok.commit = s2.rev1.merge + 0.5;
        if (t >= s2.e2Swap) { tok.text = 'first-run'; tok.swapAt = s2.e2Swap; tok.inserted = s2.e2Swap; tok.commit = null; }
      }
      if (i === 8) { if (t < s2.rev2.fix) tok.text = 'desk'; tok.swapAt = s2.rev2.fix; tok.commit = s2.rev2.fix + 0.5; }
      out.push(tok);
      if (i === 9 && t >= s2.e1Swap) out.push({ key: 'ins', text: 'ask', born: s2.e1Swap, inserted: s2.e1Swap, grow: K.p(t, s2.e1Swap, s2.e1Swap + 0.3, 'out') });
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
  function newestS2(t) {
    const list = [];
    for (let i = 0; i < s2.u1.words.length; i++) if (t >= s2.u1.words[i].at) list.push(['a' + i, s2.u1.words[i].at]);
    for (let i = 0; i < s2.u3.words.length; i++) if (t >= s2.u3.words[i].at) list.push([i === 4 && t >= s2.swapWord ? 'c3' : 'c' + i, s2.u3.words[i].at]);
    return list;
  }
  function scrollS2(t) {
    const list = newestS2(t); if (!list.length) return 0;
    const target = k => Math.max(0, Island.lineOf(k) - 1);
    const [nk, nb] = list[list.length - 1]; const pk = list.length > 1 ? list[list.length - 2][0] : nk;
    let sl = K.lerp(target(pk), target(nk), K.p(t, nb, nb + 0.45, 'inOut'));
    const last = Math.max(0, Island.lastLine() - 1);
    if (t >= s2.e2Return) sl = K.lerp(0, last, K.p(t, s2.e2Return, s2.e2Return + 0.55, 'inOut'));
    else if (t >= s2.e2Scroll) sl = K.lerp(last, 0, K.p(t, s2.e2Scroll, s2.e2Scroll + 0.55, 'inOut'));
    return sl;
  }
  const streamHtml = (u, t) => u.words.filter(w => t >= w.at).map(w => `<span style="opacity:${K.p(t, w.at, w.at + 0.2).toFixed(2)}">${esc(w.w)}</span>`).join(' ');
  const simpleTokens = (u, t, pre, opts = {}) => u.words.filter(w => t >= w.at).map((w, i) => { const tok = { key: pre + i, text: w.w, born: w.at, commit: w.at + 0.9 }; if (opts.tint && i === 0 && t >= opts.tintAt) { tok.tint = opts.tint; tok.commit = null; } if (opts.freezeAt != null && t >= opts.freezeAt) tok.commit = null; return tok; });

  // dictation body state
  function dictState(t) {
    if (t >= s2.mic && t < s2.deliver + 0.35) {
      const a = K.p(t, s2.mic + 0.12, s2.mic + 0.4, 'out') * (1 - K.p(t, s2.deliver, s2.deliver + 0.3, 'in'));
      return { t, tokens: tokensS2(t), scrollLine: () => scrollS2(t), alpha: a };
    }
    if (t >= s3.mic && t < s3.think + 0.35) {
      const a = K.p(t, s3.mic + 0.12, s3.mic + 0.4, 'out') * (1 - K.p(t, s3.think, s3.think + 0.3, 'in'));
      return { t, tokens: simpleTokens(s3.ask, t, 'q', { tint: C.flora, tintAt: s3.route, freezeAt: s3.think }), scrollLine: () => Math.max(0, Island.lastLine() - 1), alpha: a };
    }
    if (t >= s3.barge && t < s4.open + 0.3) {
      const a = K.p(t, s3.barge + 0.15, s3.barge + 0.4, 'out') * (1 - K.p(t, s4.open, s4.open + 0.25, 'in'));
      return { t, tokens: simpleTokens(s3.show, t, 'sm', { freezeAt: s3.show.end + 0.5 }), scrollLine: 0, alpha: a };
    }
    return null;
  }

  // ================= band =================
  const LAB = h => `<span class="lab">${h}</span>`;
  const FLORA = `<span class="flora">FLORA</span>`;
  const tail = h => `<span class="tail"><span style="margin-right:auto">${h}</span></span>`;
  function bandLeftState(t, w) {
    const grow = K.clamp((w - 190) / 120);
    // scene 2
    if (t >= s2.mic && t < s2.retract + 0.1) {
      const fade = 1 - K.p(t, s2.deliver, s2.deliver + 0.25);
      if (t >= s2.e1.start - 0.2 && t < s2.e1Fade + 0.3) return { html: `<span class="edit">EDIT</span>${tail(`<span class="cmd">${streamHtml(s2.e1, t)}</span>`)}`, alpha: grow * fade * K.win(t, s2.e1.start - 0.2, s2.e1Fade + 0.3, 0.25, 0.3), width: 440 - 48 - 52 };
      if (t >= s2.e2.start - 0.2 && t < s2.e2Fade + 0.3) return { html: `<span class="edit">EDIT</span>${tail(`<span class="cmd">${streamHtml(s2.e2, t)}</span>`)}`, alpha: grow * fade * K.win(t, s2.e2.start - 0.2, s2.e2Fade + 0.3, 0.25, 0.3), width: 440 - 48 - 52 };
      if (t >= s2.learnt[0] && t < s2.learnt[1] + 0.3) return { html: `<span class="ok">${esc(D.dictation.misheard.learnt)}</span>`, alpha: grow * fade * K.win(t, s2.learnt[0], s2.learnt[1] + 0.3, 0.25, 0.3) };
      const gaps = [[s2.e1.start - 0.2, s2.e1Fade + 0.3], [s2.learnt[0], s2.learnt[1] + 0.3], [s2.e2.start - 0.2, s2.e2Fade + 0.3]];
      let a = 1; for (const [a0, a1] of gaps) a *= 1 - K.win(t, a0 - 0.25, a1 + 0.25, 0.25, 0.25);
      return { html: LAB('Notion · PT-141 · Description'), alpha: grow * fade * a };
    }
    if (t >= s2.receipt[0] - 0.1 && t < s2.receipt[1] + 0.25) return { html: RCPT1, alpha: K.win(t, s2.receipt[0], s2.receipt[1] + 0.25, 0.25, 0.25), x: 40 };
    // scene 3
    if (t >= s3.mic && t < s3.fold + 0.15) {
      const fade = 1 - K.p(t, s3.fold, s3.fold + 0.2);
      if (t < s3.route) return { html: LAB('Notion · PT-141 · Description'), alpha: grow * fade };
      const rq = K.p(t, s3.route, s3.route + 0.3);
      return { html: FLORA, alpha: grow * fade * (0.3 + 0.7 * rq) };
    }
    if (t >= s3.reader2 && t < s3.barge) return { html: LAB('Reading · kitchenledger.co'), alpha: grow };
    if (t >= s3.barge && t < s4.open + 0.4) return { html: FLORA, alpha: grow * K.p(t, s3.barge + 0.1, s3.barge + 0.4) };
    // scenes 4–5: FLORA + the spoken command in the band
    if (t >= s4.open + 0.4 && t < s5.close + 0.1) {
      const cmds = [s4.regroup, s4.resolve, s4.approve, s5.say, s5.stripe, s5.enable];
      let cur = null; for (const u of cmds) if (t >= u.start - 0.3) cur = u;
      let cmd = '';
      if (cur) { const dim = t > cur.end + 1.3; const gone = t > cur.end + 4.5; if (!gone) cmd = `<span class="cmd14" style="opacity:${(dim ? 0.55 : 1).toFixed(2)}">${streamHtml(cur, t)}</span>`; }
      return { html: `${FLORA}${cmd}`, alpha: grow * (1 - K.p(t, s5.close, s5.close + 0.2)), x: 48 };
    }
    // scene 6: REC + clock
    if (t >= s6.c0 && t < s7.summary + 0.1) { const el = Math.max(0, t - s6.c0); const m = Math.floor(el / 60), s = Math.floor(el % 60); return { html: `<span class="rec">REC</span><span class="time">${m}:${String(s).padStart(2, '0')}</span>`, alpha: grow * (1 - K.p(t, s7.summary, s7.summary + 0.2)), x: 40 }; }
    if (t >= s7.summary && t < s7.sheet + 0.2) return { html: SUMM, alpha: K.win(t, s7.summary + 0.15, s7.sheet + 0.2, 0.3, 0.2), x: 40 };
    if (t >= s7.sheet && t < s7.copy + 0.2) return { html: LAB('Capture · Google Chrome'), alpha: grow * K.win(t, s7.sheet + 0.2, s7.copy + 0.2, 0.3, 0.2) };
    if (t >= s7.receipt[0] - 0.1 && t < s7.receipt[1] + 0.25) return { html: RCPT2, alpha: K.win(t, s7.receipt[0], s7.receipt[1] + 0.25, 0.25, 0.25), x: 40 };
    return null;
  }
  function bandRightState(t, w) {
    const grow = K.clamp((w - 190) / 120);
    const ctl = `<span>1.1×</span><span class="pause"><i></i><i></i></span>`;
    if (t >= s3.morph + 0.2 && t < s3.fold) return { html: ctl, alpha: grow * K.win(t, s3.morph + 0.2, s3.fold, 0.3, 0.2) };
    if (t >= s3.reader2 + 0.1 && t < s3.barge + 0.3) return { html: ctl, alpha: grow * K.win(t, s3.reader2 + 0.1, s3.barge + 0.3, 0.3, 0.25) };
    return null;
  }
  function listening(t) {
    const L = [[s2.mic, s2.deliver], [s3.mic, s3.hudDone], [s3.barge, s3.show.end + 0.2], [s4.regroup.start - 0.3, s4.regroup.end + 0.2], [s4.resolve.start - 0.3, s4.resolve.end + 0.2], [s4.approve.start - 0.3, s4.approve.end + 0.2],
      [s5.say.start - 0.3, s5.say.end + 0.2], [s5.stripe.start - 0.3, s5.stripe.end + 0.2], [s5.enable.start - 0.3, s5.enable.end + 0.2], [s6.c0 + 0.3, s7.stop]];
    let a = 0; for (const [a0, a1] of L) a = Math.max(a, K.win(t, a0, a1, 0.3, 0.3));
    return a;
  }

  // ================= reader / think / rec =================
  function readerState(t) {
    if (t >= s3.morph + 0.15 && t < s3.fold + 0.3) return { t, prog: 'reply', timeline: s3.read, p: Island.readerPos(s3.read, t, s3.morph + 0.1), alpha: K.p(t, s3.morph + 0.1, s3.morph + 0.45, 'out') * (1 - K.p(t, s3.fold, s3.fold + 0.25)) };
    if (t >= s3.reader2 + 0.1 && t < s3.barge + 0.3) return { t, prog: 'article', timeline: s3.read2, p: Island.readerPos(s3.read2, t, s3.reader2 + 0.1), alpha: K.p(t, s3.reader2 + 0.1, s3.reader2 + 0.45, 'out') * (1 - K.p(t, s3.barge, s3.barge + 0.25)), stopped: t >= s3.barge ? s3.barge : null };
    return null;
  }
  function thinkState(t) {
    if (t >= s3.thinkLine && t < s3.morph + 0.25) return { html: `${esc(D.flora.thinking)}`, alpha: K.win(t, s3.thinkLine, s3.morph + 0.25, 0.3, 0.2) };
    return null;
  }
  function recState(t) {
    if (t >= s6.c0 + 0.15 && t < s7.summary + 0.2) return { t, alpha: K.p(t, s6.c0 + 0.15, s6.c0 + 0.45, 'out') * (1 - K.p(t, s7.summary, s7.summary + 0.2)), avail: 348 - 36 };
    return null;
  }

  // ================= sheet =================
  function sheetState(t) {
    if (t >= s4.open && t < s5.close + 0.35) {
      const fade = { cc: K.p(t, s4.open + 0.15, s4.open + 0.45) * (1 - K.p(t, s5.route, s5.route + 0.3)), auto: K.p(t, s5.route + 0.25, s5.route + 0.6) * (1 - K.p(t, s5.close, s5.close + 0.22)), pay: 0 };
      return { fade, cc: { t, appearAt: s4.rows, regroupAt: s4.regroupAnim, resolveAt: s4.resolveAnim, resOpen: s4.clickRes, resClose: s4.clickWb, expandAt: s4.clickP1, approveAt: s4.approved },
        auto: { t, name: s5.fName, schedule: s5.fSchedule, deliver: s5.fDeliver, access: s5.fAccess, streams: s5.fStreams, stripeOn: s5.stripeOn, stripeConn: s5.stripeConn, active: s5.active, listAt: s5.list, glanceAt: s5.clickGl } };
    }
    if (t >= s7.sheet && t < s7.copy + 0.35) return { fade: { cc: 0, auto: 0, pay: K.p(t, s7.sheet + 0.2, s7.sheet + 0.5) * (1 - K.p(t, s7.copy, s7.copy + 0.22)) } };
    return null;
  }

  // ================= drop-down + thumbnails =================
  function dropState(t) {
    if (t < s2.click2 || t > s2.click3 + 0.45) return null;
    const a = K.p(t, s2.click2, s2.click2 + 0.3, 'out') * (1 - K.p(t, s2.click3 + 0.15, s2.click3 + 0.42));
    return { x: M.dropX, top: 92, w: 190, rows: D.dictation.misheard.alternatives, cur: t >= s2.click3 ? 0 : 1, hover: t >= s2.ptr3 + 0.45 && t < s2.click3 ? 0 : -1, alpha: a };
  }
  const SHOTS = [s6.shot1, s6.shot2, s6.shot3, s6.shot4];
  const REC_W = 348, PIP_X0 = 960 + REC_W / 2 - 18 - 111, PIP_Y = 8, PIP_W = 24, PIP_GAP = 5;
  function tdropState(t) {
    for (let k = 0; k < 4; k++) {
      const at = SHOTS[k]; if (t < at || t > at + 1.95) continue;
      const drop = K.p(t, at, at + 0.4, 'out'), shrink = K.p(t, at + 1.5, at + 1.9, 'inOut');
      const x0 = 960 + REC_W / 2 - 18 - 120, y0 = K.lerp(64 - 72, 64 + 8, drop);
      const px = PIP_X0 + k * (PIP_W + PIP_GAP), py = PIP_Y;
      return { k, x: K.lerp(x0, px, shrink), y: K.lerp(y0, py, shrink), scale: K.lerp(1, PIP_W / 120, shrink), alpha: 1 - K.p(t, at + 1.84, at + 1.92), tagAlpha: 1 - K.p(t, at + 1.45, at + 1.6), front: shrink > 0 };
    }
    return null;
  }
  function pipsState(t) {
    if (t < s6.c0 || t > s7.summary + 0.1) return { n: 0 };
    let n = 0; const pop = [];
    for (let k = 0; k < 4; k++) { const at = SHOTS[k] + 1.85; if (t >= at) { n = k + 1; pop[k] = K.p(t, at, at + 0.3, 'pop'); } }
    return { n, pop, right: 18, alpha: 1 - K.p(t, s7.summary, s7.summary + 0.2) };
  }

  // ================= pointer =================
  const { Path } = Motion;
  const geoS = p => Cap.toScreen(p);
  const tueS = (() => { const r = Cap.geo.tue; return { x: r.x + G.CHROME.x, y: r.y + G.CHROME.y + G.CHROME_HEAD, w: r.w, h: r.h }; })();
  const labelS = geoS(Cap.geo.label), arrowBS = geoS(Cap.geo.arrow.b), arrowAS = geoS(Cap.geo.arrow.a);
  const SEG = {};
  const PTR = new Path([
    { t: 0, x: 1180, y: 700, dur: 0 },
    { t: s2.ptr, x: M.caret.x + 60, y: M.caret.cy + 2, dur: 0.9 },
    SEG.tok = { t: s2.ptr2, x: 960, y: 70, dur: 0.8 },
    SEG.row = { t: s2.ptr3, x: 960, y: 120, dur: 0.6 },
    { t: s2.click3 + 0.8, x: M.caret.x + 700, y: M.caret.cy + 230, dur: 1.0 },
    { t: s3.ptrA, x: M.selStart[0], y: M.selStart[1], dur: 0.8 },
    { t: s3.drag[0], dur: s3.drag[1] - s3.drag[0], fn: p => { const e = K.ease.inOut(p); return [K.lerp(M.selStart[0], M.selEnd[0], e), K.lerp(M.selStart[1], M.selEnd[1], e)]; } },
    { t: s3.drag[1] + 0.6, x: M.selEnd[0] + 60, y: M.selEnd[1] + 120, dur: 0.7 },
    SEG.res = { t: s4.ptrRes, x: 960, y: 50, dur: 0.8 },
    SEG.wb = { t: s4.ptrWb, x: 960, y: 50, dur: 0.6 },
    SEG.p1 = { t: s4.ptrP1, x: 960, y: 200, dur: 0.9 },
    { t: s4.approved + 0.6, x: 1520, y: 720, dur: 1.0 },
    SEG.link = { t: s5.ptrGl, x: 960, y: 300, dur: 0.8 },
    { t: s5.clickGl + 0.6, x: 1520, y: 760, dur: 0.9 },
    { t: s6.ptrTab, x: M.tabPlan[0], y: M.tabPlan[1], dur: 0.8 },
    { t: s6.ptrCard, dur: 1.0, x: geoS(Cap.circlePoint(0))[0], y: geoS(Cap.circlePoint(0))[1] },
    { t: s6.circle[0], dur: s6.circle[1] - s6.circle[0], fn: p => geoS(Cap.circlePoint(p)) },
    { t: s6.ptrArrow, x: arrowAS[0], y: arrowAS[1], dur: 0.8 },
    { t: s6.arrow[0], dur: s6.arrow[1] - s6.arrow[0], fn: p => geoS(Cap.arrowPoint(K.ease.inOut(p))) },
    { t: s6.arrow[1] + 0.4, x: arrowBS[0] + 80, y: arrowBS[1] + 110, dur: 0.6 },
    { t: s6.ptrMid, x: 1000, y: 640, dur: 0.8 },
    { t: s6.ptrLabel, x: labelS[0] + 170, y: labelS[1] + 34, dur: 1.0 },
    { t: s6.ptrCard2, x: tueS.x + tueS.w + 44, y: tueS.y + tueS.h / 2, dur: 1.0 },
    { t: s7.sheet + 1.2, x: 1120, y: 800, dur: 1.0 },
  ]);
  const CLICKS = [s2.click, s2.click2, s2.click3, s4.clickRes, s4.clickWb, s4.clickP1, s5.clickGl, s6.clickTab];

  // ================= furniture =================
  const hold = (t0, t1, label = 'hold · talk') => [t0, ['fn'], label, t1 - t0, true];
  const HUD = [
    hold(s2.hud, s2.hudDone), [s2.hudDone, ['fn'], 'released', 1.0],
    hold(s3.hud, s3.hudDone), [s3.hudTab, ['⌘', '⇥'], '', 1.0], [s3.hudF8, ['F8'], 'read aloud', 1.4], hold(s3.hud3, s3.show.end + 0.2),
    hold(s4.regroup.start - 0.35, s4.regroup.end + 0.15), hold(s4.resolve.start - 0.35, s4.resolve.end + 0.15), hold(s4.approve.start - 0.35, s4.approve.end + 0.15),
    hold(s5.say.start - 0.35, s5.say.end + 0.15), hold(s5.stripe.start - 0.35, s5.stripe.end + 0.15), hold(s5.enable.start - 0.35, s5.enable.end + 0.15),
    [s5.hudEsc, ['esc'], '', 1.0], [s6.hudTab, ['⌘', '⇥'], '', 1.0], [s6.hud, ['fn', 'fn'], 'talk + mark', 1.6],
    [s6.hudTab1, ['⌘', '⇥'], '', 1.0], [s6.hudTab2, ['⌘', '⇥'], '', 1.0], [s6.hudStop, ['fn', 'fn'], 'stop', 1.4],
    [s7.hudCopy, ['⌘', 'C'], 'copy for any agent', 1.6], [s7.hudTab, ['⌘', '⇥'], '', 1.0], [s7.hudPaste, ['⌘', 'V'], '', 1.0],
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
    const [t0, keys, label, dur, held] = cur; const a = K.win(t, t0, t0 + dur + 0.3, 0.2, 0.3);
    const on = held ? t >= t0 + 0.2 && t < t0 + dur : (t >= t0 + 0.15 && t < t0 + 0.55);
    html(E.hud, keys.map((k, i) => `<span class="kc${on && i === keys.length - 1 ? ' on' : ''}">${k}</span>`).join('') + (label ? `<span class="lbl">${esc(label)}</span>` : ''));
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
    css(E.tNotch, { opacity: K.p(t, 0.1, 0.7, 'out').toFixed(3) });
    E.tParts.forEach((el, i) => { const a = K.p(t, 0.5 + i * 0.45, 1.1 + i * 0.45, 'out'); css(el, { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 8).toFixed(1)}px)` }); });
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
  const tab = t => t < s6.clickTab + 0.05 ? 'article' : 'plan';
  function scroll(t) { if (t < s6.scroll1[0]) return 0; if (t < s6.scroll2[0]) return 200 * K.p(t, s6.scroll1[0], s6.scroll1[1], 'inOut'); return 200 * (1 - K.p(t, s6.scroll2[0], s6.scroll2[1], 'inOut')); }
  const sel = t => t < s3.drag[0] || t >= s4.open ? 0 : K.ease.inOut(K.clamp((t - s3.drag[0]) / (s3.drag[1] - s3.drag[0])));
  function notionText(t) { const f = D.dictation.final; if (t < s2.arrive - 0.1) return ''; return f.slice(0, Math.round(f.length * K.p(t, s2.arrive - 0.1, s2.arrive + 0.9, 'linear'))); }

  // ================= renderAt =================
  window.renderAt = function (t) {
    const fr = front(t);
    Desktop.setFront(fr);
    { let ls = 0; for (const s of SWITCHES) if (t >= s) ls = s; const p = ls ? K.p(t, ls, ls + 0.22, 'out') : 1; const w = Desktop.$[fr]; css(w, { transform: `scale(${(0.992 + 0.008 * p).toFixed(4)})` }); for (const k of ['notion', 'chrome', 'term']) if (k !== fr) css(Desktop.$[k], { transform: 'none' }); }
    Desktop.setTab(tab(t)); const sc = scroll(t); Desktop.setPlanScroll(sc); Desktop.setArticleSelection(sel(t));
    Desktop.setNotion(notionText(t), t >= s2.click, t < s2.click);
    Desktop.setTermPaste(t >= s7.paste ? D.handoff.pastedLine : '', true);
    Cap.renderMarks(t);
    // the island
    const g = geom(t);
    const lis = listening(t);
    const rec = t >= s6.c0 && t < s7.summary;
    Island.render({ w: g.w, h: g.h, r: g.r, sheet: g.sh, dots: dotsState(t, g.w), meter: lis > 0.005 ? { t, amp: Motion.amp(t), alpha: lis * K.clamp((g.w - 190) / 120), right: rec ? 18 + 111 + 12 : 18 } : null,
      left: bandLeftState(t, g.w), right: bandRightState(t, g.w), pips: pipsState(t) });
    Island.dict(dictState(t)); Island.think(thinkState(t)); Island.reader(readerState(t)); Island.rec(recState(t));
    Sheet.render(sheetState(t));
    Island.drop(dropState(t)); Island.tdrop(tdropState(t));
    // effects: the delivery trail
    Motion.clear();
    if (t >= s2.deliver && t < s2.arrive + 0.6) Motion.trail([960, 60], [M.caret.x + 6, M.caret.cy], K.p(t, s2.deliver, s2.arrive + 0.5, 'inOut') * 1.6, [255, 205, 130], 60, 1, 0.16);
    renderCursor(t); renderHud(t); renderCaption(t); renderTitle(t); renderEnd(t);
  };

  // ================= measure the moving targets, then patch the pointer path =================
  window.renderAt(s2.click2 - 0.05);
  { const r = Island.tokenRect('c3'); SEG.tok.x = r.x + r.w * 0.5; SEG.tok.y = r.y + r.h * 0.55; M.dropX = Math.round(r.x - 14); }
  window.renderAt(s2.ptr3 + 0.1);
  { const r = Island.dropRowRect(0); SEG.row.x = r.x + r.w * 0.4; SEG.row.y = r.y + r.h / 2; }
  window.renderAt(s4.ptrRes + 0.5);
  { const r = Sheet.rect('#tab-res'); SEG.res.x = r.x + r.w / 2; SEG.res.y = r.y + r.h / 2; const w = Sheet.rect('#tab-wb'); SEG.wb.x = w.x + w.w / 2; SEG.wb.y = w.y + w.h / 2; }
  { const r = Sheet.rowRect(1, 'W'); SEG.p1.x = r.x + 120; SEG.p1.y = r.y + 14; }
  window.renderAt(s5.ptrGl + 0.5);
  { const r = Sheet.rect('#a-link'); SEG.link.x = r.x + r.w * 0.5; SEG.link.y = r.y + r.h / 2; }
  window.renderAt(0);
  window.FILM = { T, M, PTR, geom, H };
})();
