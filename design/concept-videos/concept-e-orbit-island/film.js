// Concept E — Orbit Island: the film. Builds the DOM once; renderAt(t) is a pure function of t.
// Orbit's story and desktop; the island (C) is the one place words appear; the triad rests in the notch
// and travels to where you work — the focused text caret, or the pointer while you talk — and returns.
(function () {
  const D = window.VF, K = window.K, T = window.T, G = window.GEO, css = K.css, text = K.text, html = K.html;
  const s2 = T.s2, s3 = T.s3, s4 = T.s4, s5 = T.s5, s6 = T.s6, s7 = T.s7, s8 = T.s8;
  const C = Island.C;
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  window.DURATION = T.end;

  // ================= build =================
  Desktop.build();
  Island.build();
  Payload.build();
  Island.readerBuild({ reply: D.flora.reply, article: D.flora.anyText.sentences });
  Island.recBuild([s6.a1, s6.a2, s6.a3, s6.a4]);
  CC.build();
  Cap.build();
  const $ = id => document.getElementById(id);
  const E = { cursor: $('cursor'), ripple: $('ripple'), hud: $('hud'), cap: $('caption'), capL: $('caption').querySelector('.cap-l'), capS: $('caption').querySelector('.cap-s'), title: $('title'), end: $('endcard') };
  E.title.innerHTML = `<div class="t-name">VoiceFlow</div><div class="t-concept">Concept E · Orbit Island</div><div class="t-thesis">Words in the notch. It listens where you work.</div>`;
  E.tParts = [...E.title.children];
  E.end.innerHTML = D.endCard.map(l => `<div class="e-line">${esc(l)}</div>`).join('') + `<div class="e-foot">VoiceFlow · Concept E — Orbit Island</div>`;
  E.eLines = [...E.end.querySelectorAll('.e-line')]; E.eFoot = E.end.querySelector('.e-foot');

  // ================= measurements =================
  const M = {};
  { // the Notion caret for every prefix of the final text — the triad rides it while the text lands
    const F = D.dictation.final; M.CARET = [];
    for (let n = 0; n <= F.length; n++) { Desktop.setNotion(F.slice(0, n), true, false); const r = Desktop.screenRect(Desktop.$.nCaret); M.CARET.push({ x: r.x, cy: r.y + r.h / 2 }); }
    Desktop.setNotion('', false, true); M.caret = M.CARET[0];
  }
  { const spans = Desktop.$.artSel.querySelectorAll(':scope > span');
    const r0 = spans[0].getClientRects()[0], rr = spans[2].getClientRects(); const r2 = rr[rr.length - 1];
    M.selStart = [r0.left + 1, r0.top + r0.height / 2]; M.selEnd = [r2.right + 1, r2.top + r2.height / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tabPlan); M.tabPlan = [r.x + r.w / 2, r.y + r.h / 2]; }
  { const r = Desktop.screenRect(Desktop.$.tCaret); M.termCaret = [r.x + 4, r.y + r.h / 2]; }
  M.node1 = CC.nodePos(1, s4.ptrP1 + 5).pos;
  // receipt widths from the band text they carry (text starts 48 px in, after the triad's shoulder)
  const bandLeft = document.querySelector('#isl-in .b-left');
  function measureReceipt(h) { html(bandLeft, h); bandLeft.__html = null; const w = bandLeft.getBoundingClientRect().width; html(bandLeft, ''); return Math.min(348, Math.ceil(48 + w + 12)); }
  const RCPT1 = `<span class="ok">${esc(D.dictation.receipt)}</span>`, RCPT2 = `<span class="ok">${esc(D.handoff.copied)}</span>`, SUMM = `<span class="sum">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</span>`;
  M.rcpt1W = measureReceipt(RCPT1); M.rcpt2W = measureReceipt(RCPT2); M.summW = measureReceipt(SUMM);

  // ================= island geometry =================
  // In the control center the island holds FLORA + state (300 × 32) and opens to the dictation size while
  // a command streams; it closes 1.8 s after a command ends unless the next one is about to start.
  const CMDS = [s4.regroup, s4.resolve, s4.approve, s5.say, s5.stripe, s5.enable];
  const CMD = [];   // [{u, openAt, closeAt (visible until), closes}]
  { let openNow = false, openAt = 0;
    CMDS.forEach((u, i) => {
      const next = CMDS[i + 1];
      if (!openNow) { openAt = u.start - 0.35; openNow = true; }
      const closeAt = u.end + 1.8, closes = !next || next.start - 0.35 > closeAt + 0.45;
      CMD.push({ u, openAt, closes, until: closes ? closeAt + 0.25 : next.start - 0.05, closeAt });
      if (closes) openNow = false;
    }); }
  const CC_W = 190;   // closed island in the control center: the notch itself says FLORA + state
  const ccEntries = [];
  CMD.forEach((c, i) => { if (i === 0 || CMD[i - 1].closes) ccEntries.push({ at: c.openAt, dur: 0.35, w: 440, h: 92, r: 14 }); if (c.closes) ccEntries.push({ at: c.closeAt, dur: 0.4, w: CC_W, h: 32, r: 10, ease: 'inOut' }); });
  const geom = Orbit.seq([
    { at: 0, w: 190, h: 32, r: 10, sh: 0 },
    { at: s2.grow, dur: 0.38, w: 440, h: 92, r: 14 },
    { at: s2.retract, dur: 0.4, w: 190, h: 32, r: 10, ease: 'inOut' },
    { at: s2.receipt[0] - 0.25, dur: 0.3, w: M.rcpt1W },
    { at: s2.receipt[1], dur: 0.3, w: 190, ease: 'inOut' },
    { at: s3.grow, dur: 0.38, w: 440, h: 92, r: 14 },
    { at: s3.think, dur: 0.35, h: 64 },
    { at: s3.morph, dur: 0.45, w: 528, h: 128 },
    { at: s3.fold, dur: 0.4, w: 190, h: 32, r: 10, ease: 'inOut' },
    { at: s3.reader2, dur: 0.4, w: 528, h: 128, r: 14 },
    { at: s3.barge, dur: 0.35, w: 440, h: 64 },
    { at: s4.open, dur: 0.45, w: CC_W, h: 32, r: 10, ease: 'inOut' },
    ...ccEntries,
    { at: s5.close, dur: 0.4, w: 190, h: 32, r: 10, ease: 'inOut' },
    { at: s6.c0, dur: 0.38, w: 348, h: 64, r: 12 },
    { at: s7.summary, dur: 0.35, w: M.summW, h: 32, r: 10 },
    { at: s7.sheet, dur: 0.5, dur_sh: 0.28, w: 900, h: Payload.H, r: 14, sh: 1 },
    { at: s7.copy, dur: 0.4, dur_sh: 0.3, w: 190, h: 32, r: 10, sh: 0, ease: 'inOut' },
    { at: s7.receipt[0] - 0.25, dur: 0.3, w: M.rcpt2W },
    { at: s7.receipt[1], dur: 0.3, w: 190, ease: 'inOut' },
  ], ['w', 'h', 'r', 'sh']);

  // ================= dictation tokens (B's token model at island scale) =================
  const liftAmt = (t, a, swap, drop) => Math.min(K.p(t, a, a + 0.3, 'out'), 1 - K.p(t, swap, drop, 'inOut'));
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
      if (i <= 2) tok.lift = liftAmt(t, s2.e2Lift, s2.e2Swap, s2.e2Drop);
      if (i >= 6 && i <= 11) tok.lift = liftAmt(t, s2.e1Lift, s2.e1Swap, s2.e1Drop);
      out.push(tok);
      if (i === 9 && t >= s2.e1Swap) out.push({ key: 'ins', text: 'ask', born: s2.e1Swap, inserted: s2.e1Swap, grow: K.p(t, s2.e1Swap, s2.e1Swap + 0.3, 'out'), lift: liftAmt(t, s2.e1Lift, s2.e1Swap, s2.e1Drop) });
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
  // whole-line scroll: the 2-line window follows the newest word; edit 2 walks back to the start and returns
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
  const simpleTokens = (u, t, pre, opts = {}) => u.words.filter(w => t >= w.at).map((w, i) => { const tok = { key: pre + i, text: w.w, born: w.at, commit: w.at + 0.9 }; if (opts.tint && i === 0 && t >= opts.tintAt) { tok.tint = opts.tint; tok.commit = null; } if (opts.freezeAt != null && t >= opts.freezeAt) tok.commit = null; if (opts.dimAfter != null && t > opts.dimAfter) { tok.dim = true; tok.commit = null; } return tok; });
  function smoothScroll(u, pre, t) {
    const seen = u.words.filter(w => t >= w.at); if (!seen.length) return 0;
    const target = k => Math.max(0, Island.lineOf(k) - 1);
    const n = seen.length, nk = pre + (n - 1), pk = n > 1 ? pre + (n - 2) : nk;
    return K.lerp(target(pk), target(nk), K.p(t, seen[n - 1].at, seen[n - 1].at + 0.45, 'inOut'));
  }
  // the control-center command currently in the island body
  function cmdNow(t) { let cur = null; for (let i = 0; i < CMD.length; i++) if (t >= CMD[i].u.start - 0.35 && t < CMD[i].until) cur = { ...CMD[i], i }; return cur; }

  // dictation body state
  function dictState(t) {
    if (t >= s2.grow && t < s2.deliver + 0.35) {
      const a = K.p(t, s2.grow + 0.12, s2.grow + 0.4, 'out') * (1 - K.p(t, s2.deliver, s2.deliver + 0.3, 'in'));
      return { t, tokens: tokensS2(t), scrollLine: () => scrollS2(t), alpha: a };
    }
    if (t >= s3.grow && t < s3.think + 0.35) {
      const a = K.p(t, s3.grow + 0.12, s3.grow + 0.4, 'out') * (1 - K.p(t, s3.think, s3.think + 0.3, 'in'));
      return { t, tokens: simpleTokens(s3.ask, t, 'q', { tint: C.flora, tintAt: s3.route, freezeAt: s3.think }), scrollLine: () => smoothScroll(s3.ask, 'q', t), alpha: a };
    }
    if (t >= s3.barge && t < s4.open + 0.3) {
      const a = K.p(t, s3.barge + 0.15, s3.barge + 0.4, 'out') * (1 - K.p(t, s4.open, s4.open + 0.25, 'in'));
      return { t, tokens: simpleTokens(s3.show, t, 'sm', { freezeAt: s3.show.end + 0.5 }), scrollLine: 0, alpha: a };
    }
    const c = cmdNow(t);
    if (c) {
      const a = K.p(t, c.openAt + 0.12, c.openAt + 0.4, 'out') * (1 - K.p(t, c.until - 0.25, c.until, 'in'));
      return { t, tokens: simpleTokens(c.u, t, 'k' + c.i + '-', { freezeAt: c.u.end + 0.6, dimAfter: c.u.end + 1.3 }), scrollLine: () => smoothScroll(c.u, 'k' + c.i + '-', t), alpha: a };
    }
    return null;
  }

  // ================= band =================
  const LAB = h => `<span class="lab">${h}</span>`;
  const FLORA = `<span class="flora">FLORA</span>`;
  const STATE = s => `<span class="state">${s}</span>`;
  // the streamed command is right-aligned and dissolves on the left only once it overflows its slot
  const MEAS = document.createElement('span'); MEAS.id = 'measure'; document.getElementById('stage').appendChild(MEAS);
  const textW = s => { text(MEAS, s); return MEAS.getBoundingClientRect().width; };
  const tail = (h, plain, avail) => `<span class="tail${textW(plain) > avail ? ' ov' : ''}"><span style="margin-right:auto">${h}</span></span>`;
  // band text starts 48 px in when the triad is home at the shoulder, 18 px in (aligned with the body) when it is away
  const homeP = t => { const [x, y] = Orbit.pos(t), [hx, hy] = home(t); const d = Math.hypot(x - hx, y - hy); return K.clamp(1 - (d - 8) / 40); };
  const labelX = t => K.lerp(18, 48, homeP(t));
  function bandLeftState(t, w) {
    const grow = K.clamp((w - 190) / 120);
    const x = labelX(t);
    // scene 2
    if (t >= s2.grow && t < s2.retract + 0.1) {
      const fade = 1 - K.p(t, s2.deliver, s2.deliver + 0.25);
      const cmd = (u, fadeAt) => { const avail = 440 - x - 18 - 22; return { html: `<span class="edit">↺</span>${tail(`<span class="cmd">${streamHtml(u, t)}</span>`, u.words.filter(wd => t >= wd.at).map(wd => wd.w).join(' '), avail)}`, alpha: grow * fade * K.win(t, u.start - 0.2, fadeAt + 0.3, 0.25, 0.3), width: 440 - x - 18, x }; };
      if (t >= s2.e1.start - 0.2 && t < s2.e1Fade + 0.3) return cmd(s2.e1, s2.e1Fade);
      if (t >= s2.e2.start - 0.2 && t < s2.e2Fade + 0.3) return cmd(s2.e2, s2.e2Fade);
      if (t >= s2.learnt[0] && t < s2.learnt[1] + 0.3) return { html: `<span class="ok">${esc(D.dictation.misheard.learnt)}</span>`, alpha: grow * fade * K.win(t, s2.learnt[0], s2.learnt[1] + 0.3, 0.25, 0.3), x };
      const gaps = [[s2.e1.start - 0.2, s2.e1Fade + 0.3], [s2.learnt[0], s2.learnt[1] + 0.3], [s2.e2.start - 0.2, s2.e2Fade + 0.3]];
      let a = 1; for (const [a0, a1] of gaps) a *= 1 - K.win(t, a0 - 0.25, a1 + 0.25, 0.25, 0.25);
      return { html: LAB('Notion · PT-141 · Description'), alpha: grow * fade * a, x };
    }
    if (t >= s2.receipt[0] - 0.1 && t < s2.receipt[1] + 0.25) return { html: RCPT1, alpha: K.win(t, s2.receipt[0], s2.receipt[1] + 0.25, 0.25, 0.25), x };
    // scene 3
    if (t >= s3.grow && t < s3.fold + 0.15) {
      const fade = 1 - K.p(t, s3.fold, s3.fold + 0.2);
      if (t < s3.route) return { html: LAB('Notion · PT-141 · Description'), alpha: grow * fade, x };
      const rq = K.p(t, s3.route, s3.route + 0.3);
      const state = t >= s3.morph ? '' : t >= s3.think ? 'thinking' : 'listening';
      return { html: FLORA + (state ? STATE(state) : ''), alpha: grow * fade * (0.3 + 0.7 * rq), x };
    }
    if (t >= s3.reader2 && t < s3.barge) return { html: LAB('Reading · kitchenledger.co'), alpha: grow, x };
    if (t >= s3.barge && t < s4.open + 0.4) return { html: FLORA + STATE('listening'), alpha: grow * K.p(t, s3.barge + 0.1, s3.barge + 0.4), x };
    // scenes 4–5: FLORA + state; the spoken command streams in the body
    if (t >= s4.open + 0.4 && t < s5.close + 0.1) {
      const m = Orbit.modeAt(t).mode;
      return { html: FLORA + STATE(m === 'think' ? 'working' : 'listening'), alpha: K.p(t, s4.open + 0.45, s4.open + 0.75) * (1 - K.p(t, s5.close, s5.close + 0.2)), x };
    }
    // scene 6: REC + clock
    if (t >= s6.c0 && t < s7.summary + 0.1) { const el = Math.max(0, t - s6.c0); const m = Math.floor(el / 60), s = Math.floor(el % 60); return { html: `<span class="rec">REC</span><span class="time">${m}:${String(s).padStart(2, '0')}</span>`, alpha: grow * (1 - K.p(t, s7.summary, s7.summary + 0.2)), x }; }
    if (t >= s7.summary && t < s7.sheet + 0.2) return { html: SUMM, alpha: K.win(t, s7.summary + 0.15, s7.sheet + 0.2, 0.3, 0.2), x };
    if (t >= s7.sheet && t < s7.copy + 0.2) return { html: LAB('Capture · Google Chrome'), alpha: grow * K.win(t, s7.sheet + 0.2, s7.copy + 0.2, 0.3, 0.2), x };
    if (t >= s7.receipt[0] - 0.1 && t < s7.receipt[1] + 0.25) return { html: RCPT2, alpha: K.win(t, s7.receipt[0], s7.receipt[1] + 0.25, 0.25, 0.25), x };
    return null;
  }
  function bandRightState(t, w) {
    const grow = K.clamp((w - 190) / 120);
    const ctl = `<span>1.1×</span><span class="pause"><i></i><i></i></span>`;
    if (t >= s3.morph + 0.2 && t < s3.fold) return { html: ctl, alpha: grow * K.win(t, s3.morph + 0.2, s3.fold, 0.3, 0.2) };
    if (t >= s3.reader2 + 0.1 && t < s3.barge + 0.3) return { html: ctl, alpha: grow * K.win(t, s3.reader2 + 0.1, s3.barge + 0.3, 0.3, 0.25) };
    return null;
  }

  // ================= reader / think / rec / payload =================
  function readerState(t) {
    if (t >= s3.morph + 0.15 && t < s3.fold + 0.3) return { t, prog: 'reply', timeline: s3.read, p: Island.readerPos(s3.read, t, s3.morph + 0.1), alpha: K.p(t, s3.morph + 0.1, s3.morph + 0.45, 'out') * (1 - K.p(t, s3.fold, s3.fold + 0.25)) };
    if (t >= s3.reader2 + 0.1 && t < s3.barge + 0.3) return { t, prog: 'article', timeline: s3.read2, p: Island.readerPos(s3.read2, t, s3.reader2 + 0.1), alpha: K.p(t, s3.reader2 + 0.1, s3.reader2 + 0.45, 'out') * (1 - K.p(t, s3.barge, s3.barge + 0.25)), stopped: t >= s3.barge ? s3.barge : null };
    return null;
  }
  function thinkState(t) {
    if (t >= s3.thinkLine && t < s3.morph + 0.25) return { html: `<span class="fg">◌</span>${esc(D.flora.thinking)}`, alpha: K.win(t, s3.thinkLine, s3.morph + 0.25, 0.3, 0.2) };
    return null;
  }
  function recState(t) {
    if (t >= s6.c0 + 0.15 && t < s7.summary + 0.2) return { t, alpha: K.p(t, s6.c0 + 0.15, s6.c0 + 0.45, 'out') * (1 - K.p(t, s7.summary, s7.summary + 0.2)), avail: 348 - 36 };
    return null;
  }
  function payloadState(t) {
    if (t >= s7.sheet && t < s7.copy + 0.35) return { alpha: K.p(t, s7.sheet + 0.12, s7.sheet + 0.42) * (1 - K.p(t, s7.copy, s7.copy + 0.22)), fan: K.p(t, s7.sheet + 0.25, s7.sheet + 0.9, 'out') };
    return null;
  }

  // ================= drop-down + thumbnails =================
  function dropState(t) {
    if (t < s2.click2 || t > s2.click3 + 0.45) return null;
    const a = K.p(t, s2.click2, s2.click2 + 0.3, 'out') * (1 - K.p(t, s2.click3 + 0.15, s2.click3 + 0.42));
    return { x: M.dropX, top: 92, w: 190, rows: D.dictation.misheard.alternatives, cur: t >= s2.click3 ? 0 : 1, hover: t >= s2.ptr3 + 0.45 && t < s2.click3 ? 0 : -1, alpha: a };
  }
  const SHOTS = [s6.shot1, s6.shot2, s6.shot3, s6.shot4];
  const REC_W = 348;
  function tdropState(t) {
    for (let k = 0; k < 4; k++) {
      const at = SHOTS[k]; if (t < at || t > at + 1.95) continue;
      const drop = K.p(t, at, at + 0.4, 'out'), shrink = K.p(t, at + 1.5, at + 1.9, 'inOut');
      // the 120 px thumbnail drops out right-aligned under the pips, then shrinks (about its top-right corner) into pip k
      const x0 = 960 + REC_W / 2 - 18 - 120, y0 = K.lerp(64 - 72, 64 + 8, drop);
      const px = Cap.pipX0 + k * (Cap.PIP.w + Cap.PIP.gap) + Cap.PIP.w - 120, py = Cap.PIP.y;
      return { k, x: K.lerp(x0, px, shrink), y: K.lerp(y0, py, shrink), scale: K.lerp(1, Cap.PIP.w / 120, shrink), alpha: 1 - K.p(t, at + 1.84, at + 1.92), tagAlpha: 1 - K.p(t, at + 1.45, at + 1.6), front: shrink > 0 };
    }
    return null;
  }
  function pipsState(t) {
    if (t < s6.c0 || t > s7.summary + 0.1) return { n: 0 };
    let n = 0; const pop = [];
    for (let k = 0; k < 4; k++) { const at = SHOTS[k] + 1.85; if (t >= at) { n = k + 1; pop[k] = K.p(t, at, at + 0.3, 'pop'); } }
    return { n, pop, right: 18, alpha: 1 - K.p(t, s7.summary, s7.summary + 0.2) };
  }

  // ================= desktop state =================
  const front = t => t < s3.front ? 'notion' : t < s6.front1 ? 'chrome' : t < s6.front2 ? 'notion' : t < s7.front ? 'chrome' : 'term';
  const SWITCHES = [s3.front, s6.front1, s6.front2, s7.front];
  const tab = t => t < s3.front - 0.1 ? 'plan' : t < s6.clickTab + 0.05 ? 'article' : 'plan';
  function scroll(t) { if (t < s6.scroll1[0]) return 0; if (t < s6.scroll2[0]) return 200 * K.p(t, s6.scroll1[0], s6.scroll1[1], 'inOut'); return 200 * (1 - K.p(t, s6.scroll2[0], s6.scroll2[1], 'inOut')); }
  const sel = t => t < s3.drag[0] || t >= s4.open ? 0 : K.ease.inOut(K.clamp((t - s3.drag[0]) / (s3.drag[1] - s3.drag[0])));
  const notionLen = t => t < s2.land[0] ? 0 : Math.round(D.dictation.final.length * K.p(t, s2.land[0], s2.land[1], 'linear'));
  const notionText = t => D.dictation.final.slice(0, notionLen(t));

  // ================= paths =================
  const { Path } = Orbit;
  const geoS = p => Cap.toScreen(p);
  const tueS = (() => { const r = Cap.geo.tue; return { x: r.x + G.CHROME.x, y: r.y + G.CHROME.y + G.CHROME_HEAD, w: r.w, h: r.h }; })();
  const labelS = geoS(Cap.geo.label), strikeS = geoS(Cap.geo.strike.a), arrowBS = geoS(Cap.geo.arrow.b), arrowAS = geoS(Cap.geo.arrow.a);
  const SEG = {};
  const PTR = new Path([
    { t: 0, x: 1180, y: 700, dur: 0 },
    { t: s2.ptr, x: M.caret.x + 60, y: M.caret.cy + 2, dur: 0.9 },
    SEG.tok = { t: s2.ptr2, x: 960, y: 70, dur: 0.9 },       // up to the misheard word in the island (patched after measuring)
    SEG.row = { t: s2.ptr3, x: 960, y: 120, dur: 0.6 },      // the Pantrella row
    { t: s2.click3 + 0.8, x: M.caret.x + 700, y: M.caret.cy + 230, dur: 1.0 },
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
    { t: s7.sheet + 1.2, x: 1120, y: 800, dur: 1.0 },
  ]);
  // --- the triad's targets ---
  const home = tt => Island.shoulder(geom(tt).w);                                    // its shoulder in the island / notch
  const caretAt = tt => { const c = M.CARET[notionLen(tt)]; return [c.x + 14, c.cy]; };  // 14 px right of the Notion caret, riding it as text lands
  const ptrFollow = tt => { const [x, y] = Orbit.lagged(PTR, tt); return [x + 24, y - 14]; };   // ~28 px up-right of the pointer tip, soft lag
  const TRI = new Path([
    { t: 0, dur: 0, follow: home },
    { t: s2.mic, dur: 0.6, bend: 0.22, follow: caretAt },
    { t: s2.triadHome, dur: 0.5, bend: 0.15, follow: home },
    { t: s3.mic, dur: 0.6, bend: 0.22, follow: caretAt },
    { t: s3.morph, dur: 0.5, bend: 0.15, follow: home },
    { t: s3.barge, dur: 0.6, bend: 0.2, follow: ptrFollow },
    { t: s4.open, x: CC.TRIAD[0], y: CC.TRIAD[1], dur: 0.8, bend: 0.2 },
    { t: s5.route, x: CC.CENTER[0], y: CC.CENTER[1], dur: 1.0 },
    { t: s5.close + 0.5, dur: 0.8, bend: 0.15, follow: home },
    { t: s6.c0, dur: 0.6, bend: 0.2, follow: ptrFollow },
    { t: s6.triadLabel, x: labelS[0] - 26, y: labelS[1] + 10, dur: 0.6 },
    { t: s6.triadBack3, dur: 0.6, follow: ptrFollow },
    { t: s6.triadStrike, x: strikeS[0] - 26, y: strikeS[1] - 2, dur: 0.5 },
    { t: s6.triadBack4, dur: 0.6, follow: ptrFollow },
    { t: s7.stop, dur: 0.5, bend: 0.15, follow: home },
  ]);
  Orbit.path = TRI;
  // how far out in the world the triad is: 0 at its shoulder in the notch, 1 once it has travelled ~150 px
  Orbit.awayAt = t => { const [x, y] = Orbit.pos(t), [hx, hy] = home(t); return K.clamp((Math.hypot(x - hx, y - hy) - 10) / 140); };
  Orbit.modes = [[0, 'rest'], [s2.mic, 'listen'], [s2.deliver, 'rest'], [s3.mic, 'listen'], [s3.think, 'think'], [s3.morph + 0.5, 'speak'], [s3.readEnd + 0.4, 'rest'],
    [s3.reader2, 'speak'], [s3.barge, 'listen'], [s3.show.end + 0.1, 'think'], [s4.open + 0.8, 'listen'],
    [s4.regroup.end + 0.1, 'think'], [s4.regroupAnim + 0.9, 'listen'], [s4.resolve.end + 0.1, 'think'], [s4.resolveAnim + 1.2, 'listen'],
    [s5.say.end + 0.1, 'think'], [s5.fAccess + 0.3, 'listen'], [s5.close, 'rest'], [s6.c0, 'record'], [s7.stop, 'rest']];
  Orbit.pulses = [s3.read, s3.read2];
  Orbit.unreadUntil = s4.approved; Orbit.unreadFrom = T.title.b;
  Orbit.init();
  const CLICKS = [s2.click, s2.click2, s2.click3, s4.clickRes, s4.clickWb, s4.clickP1, s6.clickTab];

  // ================= furniture =================
  const HUD = [
    [s2.hud, ['fn', 'fn'], 'talk', 1.4], [s2.hudDone, ['fn', 'fn'], 'done', 1.4], [s3.hud, ['fn', 'fn'], 'talk', 1.4],
    [s3.hudTab, ['⌘', '⇥'], '', 1.0], [s3.hudF8, ['F8'], 'read aloud', 1.4], [s3.hud3, ['fn', 'fn'], 'talk', 1.4],
    [s5.hudEsc, ['esc'], '', 1.0], [s6.hud, ['fn', 'fn'], 'talk + mark', 1.6],
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
    const [t0, keys, label, dur] = cur; const a = K.win(t, t0, t0 + dur + 0.3, 0.2, 0.3);
    const on = t >= t0 + 0.15 && t < t0 + 0.55;
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
    E.tParts.forEach((el, i) => { const a = K.p(t, 0.5 + i * 0.45, 1.1 + i * 0.45, 'out'); css(el, { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 8).toFixed(1)}px)` }); });
  }
  function renderEnd(t) {
    const a = K.p(t, s8.fade, s8.fade + 0.7);
    if (a <= 0) { css(E.end, { visibility: 'hidden' }); return; }
    css(E.end, { visibility: 'visible', opacity: a.toFixed(3) });
    E.eLines.forEach((el, i) => { const p = K.p(t, s8.lines + i * 0.45, s8.lines + i * 0.45 + 0.45, 'out'); css(el, { opacity: p.toFixed(3), transform: `translateY(${((1 - p) * 8).toFixed(1)}px)` }); });
    const p = K.p(t, s8.name, s8.name + 0.5, 'out'); css(E.eFoot, { opacity: p.toFixed(3) });
  }

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
    // the island
    const g = geom(t);
    Island.render({ w: g.w, h: g.h, r: g.r, sheet: g.sh, left: bandLeftState(t, g.w), right: bandRightState(t, g.w), pips: pipsState(t) });
    Island.dict(dictState(t)); Island.think(thinkState(t)); Island.reader(readerState(t)); Island.rec(recState(t));
    Payload.render(payloadState(t));
    Island.drop(dropState(t)); Island.tdrop(tdropState(t));
    // effects canvas
    Orbit.clear();
    if (t >= s2.deliver && t < s2.deliver + 0.8) Orbit.comet([960, 40], [M.caret.x + 6, M.caret.cy], K.p(t, s2.deliver, s2.deliver + 0.75, 'linear') * 1.5, [92, 225, 230], 30, 1, 0.16);
    if (t >= s6.c0 && t < s7.stop + 1) for (const b of Cap.beads(t, tri, sc)) Orbit.bead(b.x, b.y, b.r, b.a);
    if (t >= s7.copy + 0.45 && t < s7.beadArrive + 0.5) {
      const u = K.p(t, s7.copy + 0.5, s7.beadArrive, 'inOut'), [x, y] = Orbit.curve([960, 30], M.termCaret, u, 0.2, 1);
      const a = 1 - K.p(t, s7.beadArrive, s7.beadArrive + 0.4); Orbit.bead(x, y, 6 * (0.6 + 0.4 * a), a);
      if (u < 1) Orbit.comet([960, 30], M.termCaret, u, [200, 245, 250], 14, 1);
    }
    Orbit.drawTriad(t, 1);
    renderCursor(t); renderHud(t); renderCaption(t); renderTitle(t); renderEnd(t);
  };

  // ================= measure the moving targets, then patch the pointer path =================
  window.renderAt(s2.click2 - 0.05);
  { const r = Island.tokenRect('c3'); SEG.tok.x = r.x + r.w * 0.5; SEG.tok.y = r.y + r.h * 0.55; M.dropX = Math.round(r.x - 14); }
  window.renderAt(s2.ptr3 + 0.1);
  { const r = Island.dropRowRect(0); SEG.row.x = r.x + r.w * 0.4; SEG.row.y = r.y + r.h / 2; }
  window.renderAt(0);
  window.FILM = { T, M, PTR, TRI, geom, CMD };
})();
