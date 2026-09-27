// Desktop furniture for the Horizon film: wallpaper, menu bar, Notion, Chrome (Pantrella plan + article), terminal.
// Built once at load; film.js drives everything from renderAt(t).
window.Desk = (function () {
  const V = window.VF;
  const G = {
    notion: { x: 72, y: 128, w: 1200, h: 860 },
    chrome: { x: 600, y: 96, w: 1300, h: 900 },
    term: { x: 1180, y: 640, w: 700, h: 400 },
  };
  const CHROME_HEAD = 88; // tab strip 40 + address bar 48

  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  function menubar() {
    const wifi = `<svg width="16" height="12" viewBox="0 0 16 12"><path d="M1 4.2a10 10 0 0 1 14 0M3.3 6.6a6.6 6.6 0 0 1 9.4 0M5.7 9a3.2 3.2 0 0 1 4.6 0" fill="none" stroke="#F2F2F2" stroke-width="1.5" stroke-linecap="round"/><circle cx="8" cy="11" r="1" fill="#F2F2F2"/></svg>`;
    const batt = `<svg width="26" height="12" viewBox="0 0 26 12"><rect x=".75" y=".75" width="21.5" height="10.5" rx="2.5" fill="none" stroke="#F2F2F2" stroke-opacity=".6" stroke-width="1.2"/><rect x="2.5" y="2.5" width="14" height="7" rx="1.2" fill="#F2F2F2"/><path d="M24 4.5v3a1.5 1.5 0 0 0 0-3z" fill="#F2F2F2" fill-opacity=".6"/></svg>`;
    const dots = `<svg width="20" height="8" viewBox="0 0 20 8"><circle cx="3" cy="4" r="2" fill="#F2F2F2"/><circle cx="10" cy="4" r="2" fill="#F2F2F2"/><circle cx="17" cy="4" r="2" fill="#F2F2F2"/></svg>`;
    return `<div id="menubar"><span class="mb-apple"></span><div class="mb-app"><span id="mb-app-a">Notion</span><span id="mb-app-b">Google Chrome</span><span id="mb-app-c">Terminal</span></div>
      <span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span>
      <div class="mb-right">${dots}<span style="opacity:.8">A</span>${wifi}${batt}<span id="mb-clock">${V.clock}</span></div></div>`;
  }

  function notion() {
    const d = V.dictation.target;
    const side = [
      ['⌕', 'Search'], ['⌂', 'Home'], ['✉', 'Inbox', '3'],
    ];
    const fav = [['◫', 'Pantrella · Tickets', true], ['◷', 'Roadmap 2026'], ['≡', 'Weekly review']];
    const priv = [['▤', 'Meeting notes'], ['◉', 'Knowledge base'], ['▶', 'Marketing · Video'], ['♨', 'Recipes DB'], ['✎', 'Investor updates'], ['☰', 'Reading list'], ['◔', 'Sprint S-38'], ['▣', 'Archive']];
    const item = ([ic, label, cur, badge]) => `<div class="n-item${cur === true ? ' cur' : ''}"><span class="ic">${ic}</span>${label}${typeof cur === 'string' ? `<span style="margin-left:auto;color:#91908C;font-size:12px">${cur}</span>` : ''}</div>`;
    return `<div class="win notion" id="win-notion" style="left:${G.notion.x}px;top:${G.notion.y}px;width:${G.notion.w}px;height:${G.notion.h}px">
      <div class="n-side">
        <div class="n-ws"><div class="lights"><i></i><i></i><i></i></div><span class="n-avatar">S</span>Safet's Notion <span style="color:#91908C;font-weight:400">⌄</span></div>
        ${side.map(item).join('')}
        <div class="n-sec">Favorites</div>${fav.map(item).join('')}
        <div class="n-sec">Private</div>${priv.map(item).join('')}
        <div class="n-bottom"><div class="n-item"><span class="ic">＋</span>New page</div><div class="n-item"><span class="ic">🗑</span>Trash</div></div>
      </div>
      <div class="n-main">
        <div class="n-top"><span>${d.page}</span><span class="n-sep">/</span><span>${d.ticket}</span><span class="n-right"><span>Edited 2h ago</span><span>Share</span><span>☆</span><span>⋯</span></span></div>
        <div class="n-page">
          <div class="n-icon">◫</div>
          <h1>${d.ticket}</h1>
          <div class="n-prop"><span class="n-pn"><span class="ic">◔</span>Status</span><span class="n-pv"><span class="n-tag blue">Next</span></span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">↑</span>Priority</span><span class="n-pv"><span class="n-tag red">High</span></span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">◫</span>Project</span><span class="n-pv"><span class="n-tag green">Pantrella</span></span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">⊞</span>Area</span><span class="n-pv"><span class="n-tag yellow">Onboarding</span></span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">☺</span>Assignee</span><span class="n-pv"><span class="n-person"><i>S</i>Safet</span></span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">◷</span>Estimate</span><span class="n-pv">3 d</span></div>
          <div class="n-prop"><span class="n-pn"><span class="ic">▤</span>Created</span><span class="n-pv">September 26, 2026 · 18:12</span></div>
          <div class="n-prop n-desc"><span class="n-pn"><span class="ic">≡</span>${d.field}</span><span class="n-pv" id="n-desc"><span class="n-focus"></span><span class="n-caret"></span><span class="n-empty">Empty</span><span class="n-text" id="n-desc-text">${esc(V.dictation.final)}</span></span></div>
          <div class="n-add">＋ Add a property</div>
          <div class="n-comments">◌ Add a comment…</div>
          <h3>Acceptance</h3>
          <div class="n-todo"><span class="n-box"></span>First-run chat opens before the weekly plan</div>
          <div class="n-todo"><span class="n-box"></span>Free-text task or question accepted</div>
          <div class="n-todo"><span class="n-box"></span>Shopping list reachable in one tap</div>
          <h3>Related</h3>
          <p class="n-p"><span class="n-link">PT-130 Ingredient checks</span> · <span class="n-link">PT-118 Onboarding copy (BG)</span></p>
        </div>
      </div></div>`;
  }

  function chrome() {
    const P = V.pantrella;
    const photos = ['linear-gradient(135deg,#E9B98A,#B9642E)', 'linear-gradient(135deg,#DCE7B6,#6F9A4F)', 'linear-gradient(135deg,#E7C39A,#8C4D2E)', 'linear-gradient(135deg,#E3CFA0,#A0692C)', 'linear-gradient(135deg,#F0D9B8,#C58B4E)', 'linear-gradient(135deg,#E6B0A0,#B04B3E)'];
    const cards = P.days.map((d, i) => {
      const [mins, kcal] = d.meta.split(' · ');
      return `<div class="meal-card" id="card-${d.day}"><div class="photo" style="background:${photos[i]}"></div><div class="txt"><div class="day">${d.day}</div><div class="dish">${d.dish}</div><div class="meta">${mins} · <span class="k" id="kcal-${d.day}">${kcal}</span></div></div></div>`;
    }).join('');
    const art = V.flora.anyText.sentences;
    const wrapWords = (s, si) => s.split(' ').map((w, wi, arr) => `<span class="aw" data-s="${si}" data-w="${wi}">${w}${wi < arr.length - 1 ? ' ' : ''}</span>`).join('');
    return `<div class="win chrome" id="win-chrome" style="left:${G.chrome.x}px;top:${G.chrome.y}px;width:${G.chrome.w}px;height:${G.chrome.h}px">
      <div class="c-tabs"><div class="lights"><i></i><i></i><i></i></div>
        <div class="c-tab" id="c-tab-plan"><span class="fav g"></span>Pantrella — This week<span class="cl">×</span></div>
        <div class="c-tab" id="c-tab-art"><span class="fav"></span>Why weekly meal plans fail<span class="cl">×</span></div>
        <div class="c-newtab">＋</div></div>
      <div class="c-bar"><span class="c-nav">‹›↻</span><div class="c-url"><span id="c-url-a">🔒 ${P.url}</span><span id="c-url-b">🔒 pantrella.com/journal/why-weekly-meal-plans-fail</span></div><span class="c-right">☆⋮</span></div>
      <div class="c-content">
        <div class="page pl" id="page-plan"><div class="pl-scroll" id="pl-scroll">
          <div class="pl-head"><div class="pl-logo"><i></i>Pantrella</div>${P.nav.map((n, i) => `<span class="pl-nav${i === 0 ? ' cur' : ''}">${n}</span>`).join('')}<div class="pl-av">S</div></div>
          <div class="pl-body">
            <h1 class="pl-h1">${P.week}<span>6 dinners</span></h1>
            <div class="pl-grid">${cards}</div>
            <div class="pl-cta"><span class="pl-btn pri" id="btn-shop">${P.cta[0]}</span><span class="pl-btn sec" id="btn-ebag">${P.cta[1]}</span></div>
            <div class="pl-sec"><h2>Pantry</h2>
              <div class="pl-row"><span>Olive oil</span><span>running low</span></div>
              <div class="pl-row"><span>Rice · 1.2 kg</span><span>fine</span></div>
              <div class="pl-row"><span>Feta</span><span>until Thu</span></div>
              <div class="pl-row"><span>Yoghurt</span><span>until Sat</span></div>
              <div class="pl-row"><span>Lentils · 500 g</span><span>fine</span></div>
            </div>
          </div>
          <svg id="marks" width="1300" height="1400"></svg>
        </div></div>
        <div class="page art" id="page-art"><div class="art-in">
          <div class="art-kicker">Pantrella journal</div>
          <h1>Why weekly meal plans fail</h1>
          <div class="by">Pantrella · 4 min read</div>
          <p>Every January a few million people print a seven-day plan, pin it to the fridge, and feel organised for about forty-eight hours. Then real life shows up: a late meeting, a child who suddenly hates courgettes, a friend who drops by with wine.</p>
          <p id="art-p2">${art.map(wrapWords).join('<span class="aw-gap"> </span>')}</p>
          <p>That is the difference between a schedule and a system. A schedule tells you what should happen; a system tells you what to do when it does not. The list should be a consequence of the plan, never a separate chore.</p>
          <p>We built the week view around that idea. Change Wednesday and the shopping list changes with it, quietly, without asking you to start over.</p>
        </div></div>
      </div></div>`;
  }

  function terminal() {
    return `<div class="win term" id="win-term" style="left:${G.term.x}px;top:${G.term.y}px;width:${G.term.w}px;height:${G.term.h}px">
      <div class="t-bar"><div class="lights"><i></i><i></i><i></i></div><span>safet — claude · ~/repos/pantria — 96×28</span></div>
      <pre class="t-body"><span class="t-amber">✻</span> Welcome to <b>Claude Code</b>
<span class="t-dim">  cwd: ~/repos/pantria · model: claude-fable-5-1 · session resumed</span>

<span class="t-dim">›</span> <span class="t-green">✔</span> Read <span style="color:#E8A047">apps/web/src/plan/PlanCard.tsx</span>
<span class="t-dim">›</span> Waiting for the weekly-plan feedback capture.
</pre>
      <div class="t-box"><span class="pr">&gt;</span><span id="t-paste"></span><span class="t-cursor"></span></div>
      <div class="t-body" style="padding-top:0;color:#7A7A7E">  ? for shortcuts</div>
    </div>`;
  }

  function build() {
    const stage = document.getElementById('stage');
    stage.insertAdjacentHTML('beforeend', `<div id="wall"></div>${menubar()}<div id="windows">${terminal()}${chrome()}${notion()}</div>`);
  }

  // rect helpers — screen coordinates, measured once after build (layout is static; scroll is applied by film.js)
  const R = {};
  function measure() {
    const rect = (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; };
    R.desc = rect(document.getElementById('n-desc'));
    R.tabPlan = rect(document.getElementById('c-tab-plan'));
    R.tabArt = rect(document.getElementById('c-tab-art'));
    const scrollEl = document.getElementById('pl-scroll');
    const s0 = rect(scrollEl);
    // content-space rects (relative to the scroll content origin)
    const crel = (el) => { const r = rect(el); return { x: r.x - s0.x, y: r.y - s0.y, w: r.w, h: r.h }; };
    R.scrollOrigin = { x: s0.x, y: s0.y };
    R.cardTue = crel(document.getElementById('card-Tue'));
    R.cardWed = crel(document.getElementById('card-Wed'));
    R.btnShop = crel(document.getElementById('btn-shop'));
    R.kcalWed = crel(document.getElementById('kcal-Wed'));
    R.chromeContent = rect(document.querySelector('.c-content'));
    R.artWords = [...document.querySelectorAll('#art-p2 .aw')].map(rect);
    R.termBox = rect(document.querySelector('.t-box'));
    R.termStrip = { x: 1500, y: 1018 };
    return R;
  }

  return { G, CHROME_HEAD, build, measure, R };
})();
