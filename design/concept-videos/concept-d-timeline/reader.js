// The reader slip: a horizontal word ticker. The word being spoken sits at a fixed point
// ~40% from the left; spoken words stream left and fade, upcoming words wait on the right.
// Row 2 shows the next sentence in full. Continuous, word-accurate motion.
(function () {
  const K = window.K, css = K.css, text = K.text;
  const INK = '#1C1A17', INK2 = '#57524A', INK3 = '#736D63', RED = '#D6442C', BLUE = '#2E56C9';
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const CLIPW = 520 - 14 - 32, FIX = Math.round(CLIPW * 0.4);
  const Reader = {}; const R = {};
  // programmes: {name: {sentences: [{words:[{w, at}]}]}}
  Reader.build = function (programmes) {
    const root = document.getElementById('v-reader');
    root.innerHTML = `<div class="r-head"><span class="r-tag"></span><span class="r-ctl"><span class="spd">1.1×</span><span class="pz"><i></i><i></i></span></span></div>
      <div class="r-clip"></div><div class="r-next"></div>`;
    R.root = root; R.tag = root.querySelector('.r-tag'); R.clip = root.querySelector('.r-clip'); R.next = root.querySelector('.r-next');
    R.progs = {};
    for (const name in programmes) {
      const prog = programmes[name];
      const flow = document.createElement('div'); flow.className = 'r-flow';
      const words = [];
      prog.sentences.forEach((s, si) => {
        if (si) { const g = document.createElement('span'); g.className = 'gap'; flow.appendChild(g); }
        s.words.forEach(w => { const sp = document.createElement('span'); sp.className = 'rw'; sp.textContent = w.w; flow.appendChild(sp); words.push({ el: sp, at: w.at, si }); });
      });
      R.clip.appendChild(flow);
      // measure static word offsets
      flow.style.visibility = 'hidden'; flow.style.display = 'block';
      words.forEach(w => { w.x = w.el.offsetLeft; w.w = w.el.offsetWidth; });
      flow.style.display = 'none'; flow.style.visibility = '';
      R.progs[name] = { flow, words, sentences: prog.sentences.map(s => s.words.map(w => w.w).join(' ')) };
    }
  };
  // st: {t, prog, tag, tagColor, introAt}
  Reader.render = function (st) {
    if (!st) { for (const n in R.progs) css(R.progs[n].flow, { display: 'none' }); return; }
    const P = R.progs[st.prog], t = st.t, W = P.words;
    for (const n in R.progs) css(R.progs[n].flow, { display: n === st.prog ? 'block' : 'none' });
    text(R.tag, st.tag); css(R.tag, { color: st.tagColor || BLUE });
    // current word index and continuous offset
    let cur = -1; for (let i = 0; i < W.length; i++) if (t >= W[i].at) cur = i; else break;
    let offset;
    if (cur < 0) { const u = K.p(t, st.introAt, W[0].at, 'out'); offset = K.lerp(W[0].x - 90, W[0].x, u); }
    else if (cur >= W.length - 1) offset = W[cur].x;
    else { const a = W[cur].at, b = W[cur + 1].at, u = K.clamp((t - a) / (b - a)); const f = 0.45 * u + 0.55 * K.ease.inOut(u); offset = K.lerp(W[cur].x, W[cur + 1].x, f); }
    css(P.flow, { transform: `translateX(${(FIX - offset).toFixed(2)}px)` });
    // colours: spoken → tertiary, current → red, upcoming → secondary
    for (let i = 0; i < W.length; i++) {
      const w = W[i]; let color;
      if (i > cur) color = INK2;
      else if (i === cur) { const br = K.p(t, w.at, w.at + 0.14, 'out'); color = K.mix(INK2, RED, br); }
      else { const nxt = W[i + 1].at, d = K.p(t, nxt, nxt + 0.2, 'out'); color = K.mix(RED, INK3, d); }
      // keep only words near the viewport styled (others are masked away anyway)
      if (Math.abs(w.x - offset) > CLIPW + 200) continue;
      css(w.el, { color });
    }
    // next sentence in full; fades out just before the boundary, fades in after it
    const si = cur < 0 ? 0 : W[cur].si;
    const sentStart = k => W.find(w => w.si === k);
    const nextStart = sentStart(si + 1);
    let na = 1;
    if (nextStart && t >= nextStart.at - 0.3) na = 1 - K.p(t, nextStart.at - 0.3, nextStart.at);
    else if (cur >= 0 && si > 0) { const s0 = sentStart(si); na = K.p(t, s0.at, s0.at + 0.35, 'out'); }
    text(R.next, nextStart ? P.sentences[si + 1] : '');
    css(R.next, { opacity: na.toFixed(3) });
  };
  window.Reader = Reader;
})();
