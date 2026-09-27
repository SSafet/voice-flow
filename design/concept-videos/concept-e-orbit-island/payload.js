// payload.js — the capture payload as a sheet welded under the island (C size, ≤ 900 × 340) carrying
// Orbit's fanned 3-D screenshot stack on the left and the markdown on the right. Header row: capture
// title · 0:42 · 4 marks · 4 shots · quiet actions `Copy for any agent ⌘C · Send to…`.
(function () {
  const D = window.VF, K = window.K, css = K.css;
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const Payload = {}; const E = {};
  const SHOT_W = 216, SHOT_H = 122, FAN = [14, 18, -30];      // per-layer offsets x, y, z
  Payload.H = 32 + 32 + 10 + 200 + 12;                        // band + header + pad + body + pad = 286
  Payload.SHOT = { w: SHOT_W, h: SHOT_H };

  Payload.build = function () {
    const root = Island.sheetEl();
    root.innerHTML = `<div id="pay" class="view">
      <div class="sh-head"><span class="p-title">${esc(D.capture.title)}</span><span class="p-meta">${D.capture.length} · ${D.capture.marks} marks · ${D.capture.shots} shots</span>
        <span class="p-acts"><span class="a">Copy for any agent <kbd>⌘C</kbd></span><span class="sep">·</span><span class="b">Send to…</span></span></div>
      <div class="sh-body"><div class="stack" id="p-stack"></div><div class="p-cap">${D.capture.shots} screenshots</div><div class="p-md">${D.payloadMarkdown.map(md).join('')}</div></div></div>`;
    E.pay = root.querySelector('#pay'); E.stack = root.querySelector('#p-stack'); E.shots = [];
  };
  function md(line) {
    const m = line.match(/^(.*?)\s*(shot-\d\.png)$/), body = m ? m[1] : line, file = m ? m[2] : '';
    const cls = body.startsWith('## ') ? 'h' : body.startsWith('[') ? 'q' : 'm';
    return `<div class="ln"><span class="${cls}">${esc(body) || ' '}</span>${file ? `<span class="f">${file}</span>` : ''}</div>`;
  }
  // nodes: 4 thumbnail miniatures (shot-1 … shot-4); shot-1 sits on top, the others fan down-right behind it.
  // No filename tags on the shots — the markdown's aligned column names them; one caption under the stack counts them.
  Payload.thumbs = function (nodes) {
    [3, 2, 1, 0].forEach(i => {
      const sh = document.createElement('div'); sh.className = 'shot'; sh.appendChild(nodes[i]);
      E.stack.appendChild(sh); E.shots[i] = sh;
    });
  };
  // st: { alpha, fan (0..1: stacked → fanned) }
  Payload.render = function (st) {
    if (!st || st.alpha <= 0.004) { css(Island.sheetEl(), { display: 'none' }); return; }
    css(Island.sheetEl(), { display: 'block' });
    css(E.pay, { opacity: st.alpha.toFixed(3) });
    const f = st.fan == null ? 1 : st.fan;
    E.shots.forEach((sh, i) => css(sh, { transform: `translate3d(${(i * FAN[0] * f).toFixed(1)}px, ${(i * FAN[1] * f).toFixed(1)}px, ${(i * FAN[2] * f).toFixed(1)}px) rotateY(${(-12 * f).toFixed(1)}deg)` }));
  };
  window.Payload = Payload;
})();
