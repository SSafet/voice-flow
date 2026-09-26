// Shared scenario data for both concept films. Both films must show exactly this content
// so the two design directions are comparable. Load with <script src="../shared/data.js"></script>.
window.VF = {
  clock: 'Mon 28 Sep  09:41',

  // ---- Scene 2: streaming dictation + voice editing --------------------------------------
  dictation: {
    target: { app: 'Notion', page: 'Pantrella · Tickets', ticket: 'PT-141  First-run chat', field: 'Description' },
    // Streamed utterances. `revisions` are partial hypotheses the recogniser shows before
    // committing (streaming STT): the `from` text is shown first, then corrected to `to`.
    utter1: 'The onboarding chat should let people describe a task or a question before we show the weekly plan.',
    utter1Revisions: [{ from: 'on boarding', to: 'onboarding' }, { from: 'describe a desk', to: 'describe a task' }],
    // Spoken edit command #1 — never inserted as text; it edits the text.
    edit1: { said: 'No, no — I meant describe a task or ask a question.', find: 'describe a task or a question', replace: 'describe a task or ask a question', inserted: 'ask' },
    utter3Heard: 'And keep the pantry la shopping list one tap away.',   // "Pantrella" misheard
    misheard: { heard: 'pantry la', alternatives: ['Pantrella', 'pantry la', 'Pan Trella'], chosen: 'Pantrella', learnt: 'Added “Pantrella” to your vocabulary' },
    // Spoken edit command #2 — edits the START of the text, then returns the caret to the end.
    edit2: { said: 'Actually, at the start — make it “the first-run chat”, not “the onboarding chat”.', find: 'The onboarding chat', replace: 'The first-run chat' },
    final: 'The first-run chat should let people describe a task or ask a question before we show the weekly plan. And keep the Pantrella shopping list one tap away.',
    receipt: 'Sent to Notion · PT-141 Description',
  },

  // ---- Scene 3: talking to FLORA + karaoke reader -----------------------------------------
  flora: {
    ask: 'Flora, look at all the agents I’ve been running today, and tell me if there’s something I should look at first.',
    thinking: 'Reading 20 sessions · Codex 8 · Claude Code 6 · Cloud 6',
    reply: [
      'Twenty agents ran today across four projects. Three need you.',
      'Pantrella checkout is blocked — it wants approval to run a migration on staging.',
      'The Voice Flow release build failed twice on signing.',
      'And the Atika sync finished, but it touched forty files — review it before merging.',
      'Everything else is running or done. Want me to clear the finished ones?',
    ],
    followUp: 'Show me.',
    // Scene 3b: the same reader for ANY text on screen (select + F8)
    anyText: {
      source: 'Article in the browser — “Why weekly meal plans fail”',
      sentences: [
        'Most weekly plans fail on Wednesday, not Monday.',
        'By midweek the fridge no longer matches the plan, and nobody re-plans.',
        'The fix is a plan that bends: swap one dinner, and the shopping list follows.',
      ],
    },
  },

  // ---- Scene 4: control center ------------------------------------------------------------
  // status: needs | failed | review | running | idle | done
  // runtime: Codex | Claude Code | Cloud
  projects: ['Pantrella', 'Voice Flow', 'Atika', 'Origenum'],
  components: ['Front-end', 'Back-end', 'Infrastructure'],
  sessions: [
    { id: 1,  title: 'Checkout: cart items table',       project: 'Pantrella',  component: 'Back-end',       runtime: 'Codex',       status: 'needs',   age: '4 min',  line: 'Asks: run migration 0042 on staging?', priority: 1 },
    { id: 2,  title: 'Weekly plan card redesign',        project: 'Pantrella',  component: 'Front-end',      runtime: 'Claude Code', status: 'running', age: '12 min', line: 'Editing PlanCard.tsx' },
    { id: 3,  title: 'Cooking-mode instruction scroll',  project: 'Pantrella',  component: 'Front-end',      runtime: 'Codex',       status: 'done',    age: '1 h',    line: 'Fixed · 3 files · pushed' },
    { id: 4,  title: 'Trace regressions to tickets',     project: 'Pantrella',  component: 'Back-end',       runtime: 'Codex',       status: 'done',    age: '2 h',    line: '2,790 tests passed' },
    { id: 5,  title: 'Ingredient checks PT-130',         project: 'Pantrella',  component: 'Back-end',       runtime: 'Cloud',       status: 'done',    age: '3 h',    line: 'Validated on 212 recipes' },
    { id: 6,  title: 'ebag cart filler reliability',     project: 'Pantrella',  component: 'Back-end',       runtime: 'Cloud',       status: 'running', age: '26 min', line: 'Run 14 of 30 · 0 failures' },
    { id: 7,  title: 'Staging deploy review',            project: 'Pantrella',  component: 'Infrastructure', runtime: 'Codex',       status: 'done',    age: '5 h',    line: 'Deployed · healthy' },
    { id: 8,  title: 'Onboarding copy (BG)',             project: 'Pantrella',  component: 'Front-end',      runtime: 'Claude Code', status: 'idle',    age: '40 min', line: 'Waiting for next step' },
    { id: 19, title: 'Landing page localisation',        project: 'Pantrella',  component: 'Front-end',      runtime: 'Codex',       status: 'done',    age: '6 h',    line: 'Merged' },
    { id: 9,  title: 'Release build — signing',          project: 'Voice Flow', component: 'Infrastructure', runtime: 'Cloud',       status: 'failed',  age: '9 min',  line: 'Failed twice: notarisation timeout', priority: 2 },
    { id: 10, title: 'Streaming speech-to-text',         project: 'Voice Flow', component: 'Back-end',       runtime: 'Claude Code', status: 'running', age: '18 min', line: 'Benchmarking partial results' },
    { id: 11, title: 'Annotation anchoring',             project: 'Voice Flow', component: 'Front-end',      runtime: 'Codex',       status: 'running', age: '7 min',  line: 'Tracking elements through scroll' },
    { id: 12, title: 'New signature shape',              project: 'Voice Flow', component: 'Front-end',      runtime: 'Claude Code', status: 'done',    age: '2 h',    line: 'Mock approved' },
    { id: 13, title: 'OpenCode runtime update',          project: 'Voice Flow', component: 'Infrastructure', runtime: 'Codex',       status: 'done',    age: '4 h',    line: 'Staged 1.14.2 · sealed' },
    { id: 20, title: 'Nightly screen review',            project: 'Voice Flow', component: 'Infrastructure', runtime: 'Cloud',       status: 'done',    age: '12 h',   line: '2 suggestions filed' },
    { id: 14, title: 'Cloud sync: projection scheduler', project: 'Atika',      component: 'Back-end',       runtime: 'Codex',       status: 'review',  age: '31 min', line: 'Done · 40 files changed — review before merge', priority: 3 },
    { id: 15, title: 'Sync readiness report',            project: 'Atika',      component: 'Infrastructure', runtime: 'Cloud',       status: 'done',    age: '3 h',    line: 'Report written' },
    { id: 16, title: 'Mobile pairing flow',              project: 'Atika',      component: 'Front-end',      runtime: 'Claude Code', status: 'idle',    age: '1 h',    line: 'Waiting for next step' },
    { id: 17, title: 'Memory compaction experiment',     project: 'Origenum',   component: 'Back-end',       runtime: 'Claude Code', status: 'running', age: '44 min', line: 'Epoch 3 of 5' },
    { id: 18, title: 'Recall eval harness',              project: 'Origenum',   component: 'Back-end',       runtime: 'Cloud',       status: 'done',    age: '5 h',    line: '96 cases · 88% recall' },
  ],
  // counts: needs 1 · failed 1 · review 1 · running 5 · idle 2 · done 10  = 20
  // runtimes: Codex 8 · Claude Code 6 · Cloud 6 = 20
  controlCommands: {
    regroup: 'Group them by front-end, back-end and infrastructure.',
    resolve: 'Resolve everything that’s finished, except the Atika sync.',   // resolves the 10 `done` sessions
    approve: 'Approve it.',
  },
  checkoutAsk: {
    title: 'Run migration 0042_cart_items on staging?',
    body: 'Adds one table and backfills 1,204 rows. Rollback script is ready. Staging only.',
    approvedLine: 'Approved by voice · migrating staging',
  },

  // ---- Scene 5: automations + data streams -------------------------------------------------
  automation: {
    said: 'Flora, every weekday at eight-thirty, check last night’s Pantrella signups and failed meal plans, and brief me when I sit down.',
    addStripe: 'Also include Stripe payouts.',
    enable: 'Turn it on.',
    draft: {
      name: 'Morning Pantrella brief',
      schedule: 'Weekdays · 08:30',
      deliver: 'When you’re back at your desk',
      access: 'Read only — no actions',
      nextRun: 'Tue 08:30',
    },
    streams: [
      { name: 'Pantrella production', detail: 'read-only replica',    fresh: 'updated 2 min ago',  on: true },
      { name: 'Sentry · pantrella-web', detail: 'errors',             fresh: '3 new issues',        on: true },
      { name: 'help@pantrella.com', detail: 'inbox export',           fresh: '12 new',              on: true },
      { name: 'Stripe', detail: 'payouts',                            fresh: 'not connected yet',   on: false }, // turned on by voice
    ],
    otherStreams: [
      { name: 'GitHub · pantria', fresh: '4 commits today' },
      { name: 'Screen watcher', fresh: 'today · 3 h 12 min' },
      { name: 'Notion · tickets', fresh: '38 open' },
    ],
    existing: [
      { name: 'Nightly screen review', schedule: 'Daily · 21:37', on: true },
      { name: 'Release QA', schedule: 'On push to main', on: true },
    ],
  },

  // ---- Scene 6/7: anchored annotations while talking ----------------------------------------
  pantrella: {
    url: 'app.pantrella.com/plan',
    nav: ['Plan', 'Shopping list', 'Recipes', 'Pantry'],
    week: 'This week · 28 Sep – 4 Oct',
    days: [
      { day: 'Mon', dish: 'Chicken with roasted peppers & rice', meta: '35 min · 612 kcal' },
      { day: 'Tue', dish: 'Shopska salad & grilled halloumi',    meta: '20 min · 480 kcal' },
      { day: 'Wed', dish: 'Light moussaka',                      meta: '55 min · 540 kcal' },
      { day: 'Thu', dish: 'Lentil soup with spinach',            meta: '40 min · 410 kcal' },
      { day: 'Fri', dish: 'Baked trout, potatoes & lemon',       meta: '45 min · 590 kcal' },
      { day: 'Sat', dish: 'Stuffed peppers with yoghurt',        meta: '60 min · 520 kcal' },
    ],
    cta: ['Shopping list · 23 items', 'Fill ebag cart'],
  },
  annotations: [
    // t is relative to the start of the capture (seconds). kind: circle | arrow | label | strike
    { t: 3.0,  kind: 'circle', target: 'Tue meal card',               said: 'This plan card is way too tall on mobile —',          how: 'drawn with the mouse' },
    { t: 7.5,  kind: 'arrow',  target: 'Shopping list button',        said: '— and this button —',                                    how: 'drawn with the mouse' },
    { t: 11.0, kind: 'label',  target: 'under Shopping list button',  said: 'Write under the shopping list button: move this above the fold.', how: 'by voice', text: 'move this above the fold' },
    { t: 17.0, kind: 'strike', target: 'Wed calories “540 kcal”',     said: 'Cross out the calories on Wednesday.',                  how: 'by voice' },
  ],
  capture: { title: 'Pantrella — weekly plan feedback', length: '0:42', marks: 4, shots: 4 },
  payloadMarkdown: [
    '## Pantrella — weekly plan feedback  (0:42 · 4 marks)',
    'Window: Chrome — app.pantrella.com/plan',
    '',
    '[0:03] “This plan card is way too tall on mobile —”',
    '       circle → article.meal-card (Tue · Shopska salad)   shot-1.png',
    '[0:07] “— and this button —”',
    '       arrow → button “Shopping list · 23 items”          shot-2.png',
    '[0:11] label under button: “move this above the fold”     shot-3.png',
    '[0:17] strike → “540 kcal” (Wed · Light moussaka)          shot-4.png',
  ],
  handoff: { copied: 'Copied for any agent — text + 4 screenshots', pastedInto: 'Claude Code · pantria', pastedLine: '[Capture: Pantrella — weekly plan feedback · 4 images · 1,180 chars]' },

  endCard: [
    'Hands-free first — see every word while you speak',
    'Fix anything by saying it',
    'Every agent, one place — and a clean workbench',
    'Marks that stay on the thing you mean',
    'One payload, any agent',
  ],
};
