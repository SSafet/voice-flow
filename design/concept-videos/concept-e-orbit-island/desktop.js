// Desktop furniture for Concept E — Orbit Island: a notched MacBook menu bar + three believable app
// windows (Notion, Chrome with Pantrella + article, Terminal). Taken from concept-c-island/desktop.js.
// Exposes window.GEO (fixed geometry) and window.Desktop (build + per-frame setters).
// Layout rule (brief): no window peeks out behind another as a dark block — the terminal (dark) sits
// fully inside both Chrome and Notion, and Chrome sits fully inside Notion.
(function () {
  const D = window.VF;
  const GEO = {
    W: 1920, H: 1080, MENU: 24,
    NOTCH: { w: 190, h: 32, r: 10 },
    NOTION: { x: 200, y: 130, w: 1520, h: 878 },
    CHROME: { x: 240, y: 130, w: 1440, h: 878 },
    TERM:   { x: 660, y: 300, w: 1000, h: 640 },
    CHROME_HEAD: 84,
  };
  window.GEO = GEO;

  const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  // ---------- menu bar (items stay clear of the notch: left block ends < 780, right block starts > 1140) ----------
  function buildMenubar(root) {
    const wifi = `<svg width="15" height="11" viewBox="0 0 16 12"><path d="M1 4.2a10 10 0 0 1 14 0M3.3 6.6a6.6 6.6 0 0 1 9.4 0M5.7 9a3.2 3.2 0 0 1 4.6 0" fill="none" stroke="#F2F2F5" stroke-width="1.5" stroke-linecap="round"/><circle cx="8" cy="11" r="1" fill="#F2F2F5"/></svg>`;
    const batt = `<svg width="25" height="11" viewBox="0 0 26 12"><rect x=".75" y=".75" width="21.5" height="10.5" rx="2.5" fill="none" stroke="#F2F2F5" stroke-opacity=".6" stroke-width="1.2"/><rect x="2.5" y="2.5" width="14" height="7" rx="1.2" fill="#F2F2F5"/><path d="M24 4.5v3a1.5 1.5 0 0 0 0-3z" fill="#F2F2F5" fill-opacity=".6"/></svg>`;
    const cc = `<svg width="14" height="11" viewBox="0 0 14 11"><rect x=".5" y=".5" width="13" height="4" rx="2" fill="none" stroke="#F2F2F5" stroke-width="1"/><circle cx="10.5" cy="2.5" r="1.5" fill="#F2F2F5"/><rect x=".5" y="6.5" width="13" height="4" rx="2" fill="none" stroke="#F2F2F5" stroke-width="1"/><circle cx="3.5" cy="8.5" r="1.5" fill="#F2F2F5"/></svg>`;
    root.innerHTML = `<div class="mb-left"><span class="apple"></span><span class="mb-app" id="mb-app">Notion</span><span id="mb-menus"></span></div>
      <div class="mb-right">${wifi}${batt}${cc}<span class="clock">${D.clock}</span></div>`;
  }
  const MENUS = {
    Notion: ['File', 'Edit', 'View', 'Insert', 'Format', 'Window', 'Help'],
    'Google Chrome': ['File', 'Edit', 'View', 'History', 'Bookmarks', 'Profiles', 'Tab', 'Window', 'Help'],
    Terminal: ['Shell', 'Edit', 'View', 'Window', 'Help'],
  };

  // ---------- Notion ----------
  function buildNotion() {
    const w = el('div', 'win', '');
    w.id = 'w-notion';
    Object.assign(w.style, { left: GEO.NOTION.x + 'px', top: GEO.NOTION.y + 'px', width: GEO.NOTION.w + 'px', height: GEO.NOTION.h + 'px' });
    const side = ['Roadmap', 'Tickets', 'Retention research', 'Cohort 2 notes', 'Meeting notes', 'Brand & studio', 'Finance', 'Recipes QA', 'Hiring (later)'];
    w.innerHTML = `
      <div class="n-side">
        <div class="lights"><i></i><i></i><i></i></div>
        <div class="n-ws"><i>P</i>Pantrella <span style="color:#91918E;font-weight:400">⌄</span></div>
        <div class="n-item"><i style="background:#CFCECA"></i>Search</div>
        <div class="n-item"><i style="background:#CFCECA"></i>Updates</div>
        <div class="n-item"><i style="background:#CFCECA"></i>Settings</div>
        <div class="n-sec">Favorites</div>
        <div class="n-item"><i></i>Sprint 14 board</div>
        <div class="n-item"><i></i>Retention dashboard</div>
        <div class="n-sec">Private</div>
        ${side.map((s, i) => `<div class="n-item${i === 1 ? ' sel' : ''}"><i></i>${s}</div>`).join('')}
        <div class="n-item sub">PT-141 First-run chat</div>
        <div class="n-item sub">PT-140 Cohort invite mail</div>
        <div class="n-item sub">PT-138 ebag cart timeout</div>
        <div class="n-sec">Teamspaces</div>
        <div class="n-item"><i></i>Pantrella HQ</div>
      </div>
      <div class="n-main">
        <div class="n-top"><span>Pantrella · Tickets</span><span class="crumb-sep">/</span><span>PT-141 First-run chat</span>
          <div class="n-actions"><span>Edited 12 min ago</span><span class="btn">Share</span><span>☆</span><span>⋯</span></div></div>
        <div class="n-page">
          <div class="n-icon"></div>
          <h1>First-run chat</h1>
          <div class="props">
            <div class="k"><i></i>Status</div><div><span class="pill blue">In progress</span></div>
            <div class="k"><i></i>Priority</div><div><span class="pill red">High</span></div>
            <div class="k"><i></i>Sprint</div><div><span class="pill gray">Sprint 14</span></div>
            <div class="k"><i></i>Owner</div><div><span class="avatar">S</span>Safet</div>
            <div class="k"><i></i>Area</div><div><span class="pill green">Onboarding</span></div>
            <div class="k"><i></i>ID</div><div>PT-141</div>
          </div>
          <h2>Description</h2>
          <p class="n-desc" id="n-desc"><span class="ph" id="n-ph">Empty. Click to add a description…</span><span id="n-text"></span><i class="caret" id="n-caret"></i></p>
          <h2>Acceptance</h2>
          <ul class="todo">
            <li><i class="on"></i>Chat opens on first launch, before the weekly plan</li>
            <li><i></i>Task or question captured and echoed back in one line</li>
            <li><i></i>Shopping list reachable from the chat in one tap</li>
            <li><i></i>Bulgarian copy reviewed</li>
          </ul>
          <div class="n-comments">
            <div class="n-comment"><span class="avatar">S</span><div><span class="who">Safet</span><span class="when">Yesterday 18:20</span><p>Cohort 2 feedback: three people did not understand what the chat was for. Let's write the description first, then the copy.</p></div></div>
            <div class="n-comment"><span class="avatar" style="background:#C9B27C">M</span><div><span class="who">Mila</span><span class="when">Today 09:12</span><p>Agreed — I'll draft the BG strings once the description lands.</p></div></div>
          </div>
        </div>
      </div>`;
    return w;
  }

  // ---------- Chrome ----------
  function planHTML() {
    const P = D.pantrella;
    const cards = P.days.map((d, i) => `<div class="card g${i + 1}" data-day="${d.day}"><div class="img"><span class="day">${d.day}</span></div>
      <div class="body"><div class="dish">${esc(d.dish)}</div><div class="meta">${d.meta.split(' · ').map((m, j) => `<span class="m${j}">${esc(m)}</span>`).join('')}</div></div>
      <div class="acts"><span>Swap</span><span>Cooked</span></div></div>`).join('');
    const rows = [['Shopska salad & grilled halloumi', 'Tue · swap for: Tarator & flatbread'], ['Light moussaka', 'Wed · swap for: Stuffed courgettes'],
      ['Lentil soup with spinach', 'Thu · swap for: Bean stew (bob chorba)'], ['Baked trout, potatoes & lemon', 'Fri · swap for: Grilled mackerel']]
      .map(r => `<div class="row"><i></i><div><div>${esc(r[0])}</div><div class="r2">${esc(r[1])}</div></div><span class="sw">Swap</span></div>`).join('');
    return `<div class="pn">
      <div class="pn-head"><div class="logo"><i></i>Pantrella</div><div class="pn-nav">${P.nav.map((n, i) => `<span class="${i === 0 ? 'on' : ''}">${n}</span>`).join('')}</div>
        <div class="pn-me"><span>Safet</span><i></i></div></div>
      <div class="pn-body">
        <div class="pn-week"><span class="arr">‹</span><h2>${P.week}</h2><span class="arr">›</span><span class="tag">6 dinners · 2 people · 3,152 kcal</span></div>
        <div class="grid">${cards}</div>
        <div class="cta"><span class="btn pri" id="pn-shop">${esc(P.cta[0])}</span><span class="btn sec">${esc(P.cta[1])}</span><span class="hint">Checkout stays with you.</span></div>
        <h3>Suggested swaps</h3>
        <div class="rows">${rows}</div>
      </div></div>`;
  }
  function articleHTML() {
    const A = D.flora.anyText;
    const sents = A.sentences.map((s, i) => `<span class="s${i}">${esc(s)}</span>`).join(' ');
    return `<div class="art"><div class="a-top"><b>The Kitchen Ledger</b><span>Essays</span><span>Recipes</span><span>Newsletter</span><span style="margin-left:auto">Sign in</span></div>
      <div class="a-col"><div class="kicker">Planning</div><h1>Why weekly meal plans fail</h1>
        <div class="by"><i></i><span>Dana Petrova · 6 min read · 22 Sep 2026</span></div>
        <p>Every January a few million people print a seven-day plan, buy the ingredients, and feel organised for about seventy-two hours. The plan is not the problem. The week is.</p>
        <p id="art-sel">${sents}</p>
        <p class="pull">A plan you cannot bend is a plan you will abandon — usually quietly, and usually on a Wednesday.</p>
        <p>The apps that survive this are the ones that treat the plan as a draft: one tap to swap a dinner, and the list, the budget and the leftovers all move with it. Everything else is a printed calendar with better fonts.</p>
        <p>What follows is what we learned from four hundred households who kept a plan for more than a month, and the small mechanics that made the difference.</p>
      </div></div>`;
  }
  function buildChrome() {
    const w = el('div', 'win');
    w.id = 'w-chrome';
    Object.assign(w.style, { left: GEO.CHROME.x + 'px', top: GEO.CHROME.y + 'px', width: GEO.CHROME.w + 'px', height: GEO.CHROME.h + 'px' });
    w.innerHTML = `
      <div class="c-tabs"><div class="lights"><i></i><i></i><i></i></div>
        <div class="c-tab" id="tab-plan"><span class="fav" style="background:#5E7A57"></span><span class="t">Pantrella — This week</span><span class="x">✕</span></div>
        <div class="c-tab" id="tab-art"><span class="fav" style="background:#6B7B5A"></span><span class="t">Why weekly meal plans fail — The Kitchen Ledger</span><span class="x">✕</span></div>
        <div class="c-new">+</div></div>
      <div class="c-bar"><div class="nav"><span>‹</span><span>›</span><span>⟳</span></div>
        <div class="omni"><span class="lock"></span><span id="omni"></span></div><span>☆</span><span>⋮</span></div>
      <div class="c-view">
        <div class="c-scroll" id="scr-plan">${planHTML()}<svg class="marks" id="marks" xmlns="http://www.w3.org/2000/svg"></svg><div id="mk-html" style="position:absolute;left:0;top:0;width:0;height:0"></div></div>
        <div class="c-scroll" id="scr-art">${articleHTML()}</div>
      </div>`;
    return w;
  }

  // ---------- Terminal ----------
  function buildTerm() {
    const w = el('div', 'win dark');
    w.id = 'w-term';
    Object.assign(w.style, { left: GEO.TERM.x + 'px', top: GEO.TERM.y + 'px', width: GEO.TERM.w + 'px', height: GEO.TERM.h + 'px' });
    w.innerHTML = `<div class="t-bar"><div class="lights"><i></i><i></i><i></i></div><span class="t-title">pantria — claude — 118×38</span></div>
<pre><span class="box"><span class="o">✻</span> Welcome to <b>Claude Code</b>!

  <span class="g">/help for help, /status for your current setup</span>

  <span class="g">cwd: /Users/safet/repos/pantria</span></span>
<span class="g">› Tips for getting started: run /init to create a CLAUDE.md file · use /memory to edit memory</span>

<span class="b">&gt;</span> summarise the open PT tickets touching the weekly plan

<span class="o">●</span> Four open tickets touch the weekly plan: <b>PT-141</b> First-run chat (in progress), <b>PT-138</b> ebag cart timeout,
  <b>PT-133</b> Plan card density on mobile, <b>PT-130</b> Ingredient checks (validated by cloud run, awaiting merge).
  PT-133 is the one without a concrete brief yet — it only has the title.

<span class="prompt"><span class="b">&gt;</span> <span id="t-paste"></span><span class="tcaret" id="t-caret"></span></span>
<span class="g">  ? for shortcuts                                                      ⏵⏵ accept edits on · claude-fable-5-1</span></pre>`;
    return w;
  }

  // ---------- public ----------
  const Desktop = { GEO };
  Desktop.build = function () {
    buildMenubar(document.getElementById('menubar'));
    const root = document.getElementById('windows');
    root.appendChild(buildTerm());
    root.appendChild(buildChrome());
    root.appendChild(buildNotion());
    Desktop.$ = {
      notion: document.getElementById('w-notion'), chrome: document.getElementById('w-chrome'), term: document.getElementById('w-term'),
      nText: document.getElementById('n-text'), nPh: document.getElementById('n-ph'), nCaret: document.getElementById('n-caret'), nDesc: document.getElementById('n-desc'),
      tabPlan: document.getElementById('tab-plan'), tabArt: document.getElementById('tab-art'), omni: document.getElementById('omni'),
      scrPlan: document.getElementById('scr-plan'), scrArt: document.getElementById('scr-art'),
      marks: document.getElementById('marks'), mkHtml: document.getElementById('mk-html'),
      tPaste: document.getElementById('t-paste'), tCaret: document.getElementById('t-caret'),
      mbApp: document.getElementById('mb-app'), mbMenus: document.getElementById('mb-menus'),
      artSel: document.getElementById('art-sel'),
    };
  };
  // z-order: array of ids back→front
  const ORDER = { notion: ['term', 'chrome', 'notion'], chrome: ['term', 'notion', 'chrome'], term: ['chrome', 'notion', 'term'] };
  const APPNAME = { notion: 'Notion', chrome: 'Google Chrome', term: 'Terminal' };
  Desktop.setFront = function (front) {
    const order = ORDER[front];
    order.forEach((id, i) => { const w = Desktop.$[id]; K.css(w, { zIndex: String(i + 1) }); const back = i < order.length - 1; if (w.__back !== back) { w.__back = back; w.classList.toggle('back', back); } });
    K.text(Desktop.$.mbApp, APPNAME[front]);
    K.html(Desktop.$.mbMenus, MENUS[APPNAME[front]].map(m => `<span style="margin-left:18px">${m}</span>`).join(''));
  };
  Desktop.setTab = function (tab) {
    const plan = tab === 'plan';
    if (Desktop.$.tabPlan.__on !== plan) { Desktop.$.tabPlan.__on = plan; Desktop.$.tabPlan.classList.toggle('on', plan); Desktop.$.tabArt.classList.toggle('on', !plan); }
    K.css(Desktop.$.scrPlan, { visibility: plan ? 'visible' : 'hidden' });
    K.css(Desktop.$.scrArt, { visibility: plan ? 'hidden' : 'visible' });
    K.html(Desktop.$.omni, plan ? `<span class="host">app.pantrella.com</span><span class="path">/plan</span>` : `<span class="host">kitchenledger.co</span><span class="path">/essays/why-weekly-meal-plans-fail</span>`);
  };
  Desktop.setPlanScroll = function (px) { K.css(Desktop.$.scrPlan, { transform: `translateY(${-px}px)` }); };
  // selection progress 0..1 across the three article sentences (character-wise)
  Desktop.setArticleSelection = function (p) {
    const spans = Desktop.$.artSel.querySelectorAll(':scope > span');
    const total = [...spans].reduce((a, s) => a + s.textContent.length, 0);
    let budget = Math.round(p * total);
    spans.forEach(s => {
      const n = s.textContent.length, take = Math.max(0, Math.min(n, budget)); budget -= n;
      if (s.__sel === take) return; s.__sel = take;
      const txt = s.textContent;
      s.innerHTML = take <= 0 ? esc(txt) : take >= n ? `<span class="sel">${esc(txt)}</span>` : `<span class="sel">${esc(txt.slice(0, take))}</span>${esc(txt.slice(take))}`;
    });
  };
  Desktop.setNotion = function (text, caretVisible, placeholder) {
    K.text(Desktop.$.nText, text);
    K.css(Desktop.$.nCaret, { visibility: caretVisible ? 'visible' : 'hidden' });
    K.css(Desktop.$.nPh, { visibility: placeholder ? 'visible' : 'hidden' });
  };
  Desktop.setTermPaste = function (text, caretOn) {
    K.html(Desktop.$.tPaste, text ? `<span class="paste">${esc(text)}</span> ` : '');
    K.css(Desktop.$.tCaret, { visibility: caretOn ? 'visible' : 'hidden' });
  };
  // rect of an element inside the plan scroller, in scroller (page) coordinates
  Desktop.planRect = function (sel) {
    const e = Desktop.$.scrPlan.querySelector(sel), r = e.getBoundingClientRect(), b = Desktop.$.scrPlan.getBoundingClientRect();
    return { x: r.left - b.left, y: r.top - b.top, w: r.width, h: r.height };
  };
  Desktop.screenRect = function (e) { const r = e.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };
  window.Desktop = Desktop;
})();
