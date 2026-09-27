// The dictation slip: streamed tokens with provisional → committed cross-fades, revisions,
// proofreader edits (red strike + collapse, red insert → ink), low-confidence wavy underline,
// the command line at the slip's top edge, and the alternatives picker.
(function () {
  const K = window.K, css = K.css, text = K.text, html = K.html;
  const INK = '#1C1A17', INK2 = '#57524A', INK3 = '#736D63', RED = '#D6442C';
  const LINE = 20;
  const Slip = {}; const S = {};
  const widths = new Map();
  function measure(txt, italic) {
    const key = (italic ? 'i:' : 'r:') + txt;
    if (widths.has(key)) return widths.get(key);
    S.meas.style.fontStyle = italic ? 'italic' : 'normal'; S.meas.textContent = txt;
    const w = S.meas.getBoundingClientRect().width; widths.set(key, w); return w;
  }
  Slip.build = function () {
    const root = document.getElementById('v-slip');
    root.innerHTML = `<div class="s-cmd"><span class="pre"></span><span class="cw"><span class="in"></span></span></div><div class="s-clip"><div class="s-flow"></div></div>`;
    S.root = root; S.cmd = root.querySelector('.s-cmd'); S.cmdPre = S.cmd.querySelector('.pre'); S.cmdWin = S.cmd.querySelector('.cw'); S.cmdIn = S.cmd.querySelector('.in'); S.clip = root.querySelector('.s-clip'); S.flow = root.querySelector('.s-flow');
    S.caret = document.createElement('i'); S.caret.className = 's-caret';
    S.meas = document.getElementById('measure');
    S.spans = new Map();
    S.picker = document.getElementById('picker'); S.picker.innerHTML = '<div></div><div></div><div></div>'; S.prows = [...S.picker.children];
  };
  // ---- token visuals ----
  // tok: {key, text, born, commit?, swap?:{at, from}, lowConf?, inserted?, struck?:{at, collapse}, tint?, dim?}
  function renderToken(sp, tok, t) {
    const c = sp.firstChild, o = sp.children[1], st = sp.children[2];
    const txt = tok.text + ' ';
    let curTxt = txt, oldTxt = null, q = 1;            // q: 1 = show current only
    let curItalic = false, oldItalic = false, curColor = INK, oldColor = INK3;
    // provisional → committed cross-fade
    if (tok.commit != null) {
      const cp = K.p(t, tok.commit, tok.commit + 0.35, 'inOut');
      if (cp < 1) { oldTxt = txt; oldItalic = true; oldColor = INK3; q = cp; }
    }
    // revision cross-fade (text swap)
    if (tok.swap && t >= tok.swap.at - 0.001) {
      const sq = K.p(t, tok.swap.at, tok.swap.at + 0.4, 'inOut');
      if (sq < 1) { oldTxt = tok.swap.from + ' '; oldItalic = t < (tok.commit || 0); oldColor = oldItalic ? INK3 : INK; q = sq; }
    }
    if (tok.tint) curColor = tok.tint;
    if (tok.dim) curColor = INK2;
    // inserted words: red, settling to ink; width unfolds
    let widthPx = null, alpha = 1, unfold = 1;
    if (tok.inserted != null) {
      unfold = K.p(t, tok.inserted, tok.inserted + 0.3, 'out');
      const g = 1 - K.p(t, tok.inserted + 0.6, tok.inserted + 1.6, 'inOut');
      curColor = K.mix(INK, RED, g);
    }
    // struck words: red line grows, then the word collapses
    let strikeW = 0;
    if (tok.struck) {
      strikeW = K.p(t, tok.struck.at, tok.struck.at + 0.25, 'out') * measure(tok.text, false);
      const col = K.p(t, tok.struck.collapse, tok.struck.collapse + 0.3, 'in');
      unfold = 1 - col; alpha = 1 - col;
    }
    if (tok.born != null) { const bp = K.p(t, tok.born, tok.born + 0.2, 'out'); alpha *= 0.15 + 0.85 * bp; }
    if (tok.alpha != null) alpha *= tok.alpha;
    const wCur = measure(curTxt, curItalic);
    if (oldTxt != null) { const wOld = measure(oldTxt, oldItalic); widthPx = K.lerp(wOld, wCur, q); }
    if (unfold < 1) widthPx = (widthPx == null ? wCur : widthPx) * unfold;
    text(c, curTxt);
    css(c, { color: curColor, fontStyle: curItalic ? 'italic' : 'normal', opacity: (q).toFixed(3), textDecoration: tok.lowConf ? 'underline wavy' : 'none', textDecorationColor: RED, textUnderlineOffset: '1px', textDecorationThickness: '1px' });
    if (oldTxt != null) { text(o, oldTxt); css(o, { display: 'inline-block', color: oldColor, fontStyle: oldItalic ? 'italic' : 'normal', opacity: (1 - q).toFixed(3) }); }
    else css(o, { display: 'none' });
    css(st, { width: strikeW.toFixed(1) + 'px' });
    css(sp, { display: 'inline-block', width: widthPx == null ? 'auto' : widthPx.toFixed(2) + 'px', opacity: alpha.toFixed(3), overflow: unfold < 1 ? 'hidden' : 'visible' });
  }
  function renderTokens(tokens, t, caret) {
    const seen = new Set(); let order = 0;
    for (const tok of tokens) {
      let sp = S.spans.get(tok.key);
      if (!sp) { sp = document.createElement('span'); sp.className = 'tok'; sp.innerHTML = '<span class="c"></span><span class="o"></span><i class="st"></i>'; S.spans.set(tok.key, sp); S.flow.appendChild(sp); }
      if (S.flow.children[order] !== sp) S.flow.insertBefore(sp, S.flow.children[order] || null);
      order++; seen.add(tok.key);
      renderToken(sp, tok, t);
    }
    for (const [key, sp] of S.spans) if (!seen.has(key)) css(sp, { display: 'none' });
    // caret at the end of the text
    if (caret) { if (S.flow.lastChild !== S.caret) S.flow.appendChild(S.caret); css(S.caret, { display: 'inline-block' }); }
    else css(S.caret, { display: 'none' });
  }
  Slip.lineOf = key => { const sp = S.spans.get(key); if (!sp || sp.style.display === 'none') return 0; return Math.round(sp.offsetTop / LINE); };
  Slip.lastLine = () => { let m = 0; for (const sp of S.flow.children) if (sp.style.display !== 'none') m = Math.max(m, Math.round(sp.offsetTop / LINE)); return m; };
  Slip.tokenScreenRect = key => { const sp = S.spans.get(key); const r = sp.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  Slip.pickerRowRect = i => { const r = S.prows[i].getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  // st: {t, tokens, caret, cmd:{html, alpha}, scroll(api)->line, exit (0..1 slide-out), picker}
  Slip.render = function (st) {
    if (!st) { css(S.picker, { visibility: 'hidden' }); return; }
    renderTokens(st.tokens || [], st.t, !!st.caret);
    const line = st.scroll ? st.scroll({ lineOf: Slip.lineOf, lastLine: Slip.lastLine }) : 0;
    const ex = st.exit || 0;
    css(S.flow, { transform: `translate(${(-34 * ex).toFixed(1)}px, ${(-line * LINE).toFixed(2)}px)`, opacity: (1 - ex).toFixed(3) });
    if (st.cmd) {
      html(S.cmdPre, st.cmd.pre || ''); html(S.cmdIn, st.cmd.html);
      const over = S.cmdIn.offsetWidth - S.cmdWin.clientWidth;   // long commands slide left under the fixed prefix so the newest words stay visible
      css(S.cmdIn, { transform: over > 0 ? `translateX(${(-over).toFixed(1)}px)` : 'none' });
      S.cmdWin.classList.toggle('over', over > 0);
      css(S.cmd, { opacity: (st.cmd.alpha == null ? 1 : st.cmd.alpha).toFixed(3), visibility: 'visible' });
    }
    else css(S.cmd, { visibility: 'hidden' });
    const pk = st.picker;
    if (pk) {
      pk.rows.forEach((r, i) => { text(S.prows[i], r); S.prows[i].classList.toggle('cur', i === pk.cur); });
      css(S.picker, { visibility: 'visible', left: pk.x.toFixed(1) + 'px', top: pk.y.toFixed(1) + 'px', opacity: pk.alpha.toFixed(3), transform: `translateY(${((1 - pk.alpha) * -4).toFixed(1)}px)` });
    } else css(S.picker, { visibility: 'hidden' });
  };
  window.Slip = Slip;
})();
