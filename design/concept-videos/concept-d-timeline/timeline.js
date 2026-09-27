// Timeline for Concept D — Timeline (paper). Every anchor is derived from the speech
// timelines so a change in one utterance shifts everything after it. Exposes window.T.
(function () {
  const D = window.VF, K = window.K;
  const WPS = 2.8;
  const spk = (s, at, wps = WPS, seed = 1) => { const words = K.speechTimeline(s, at, wps, seed); return { words, start: at, end: K.endOf(words), text: s }; };
  // sentences read by the TTS reader: [{words, start, end}], sequential with a gap
  function reader(sentences, at, wps, seed) {
    let t = at; const out = [];
    sentences.forEach((s, i) => { const u = spk(s, t, wps, seed + i); out.push(u); t = u.end + 0.3; });
    return { sentences: out, start: at, end: out[out.length - 1].end };
  }
  const T = {};
  T.title = { a: 0, b: 4.0 };
  T.rest = { a: 4.0, cap: 4.3 };

  // ---- Scene 2: dictation ----
  const s2 = T.s2 = {};
  s2.cap = 9.6; s2.ptr = 10.0; s2.click = 11.0;
  s2.hold = 11.9; s2.open = s2.hold;                       // fn pressed (held until release)
  s2.u1 = spk(D.dictation.utter1, s2.hold + 0.75, WPS, 1);
  s2.rev1 = s2.u1.words[2].at + 0.3;                      // 'on boarding' → 'onboarding'
  s2.rev2 = s2.u1.words[9].at + 0.25;                     // 'describe a desk' → 'describe a task'
  s2.e1 = spk(D.dictation.edit1.said, s2.u1.end + 0.9, WPS, 2);
  s2.e1Apply = s2.e1.end + 0.3;                           // 'ask' inserted
  s2.e1Hide = s2.e1Apply + 1.5;                           // EDIT line fades
  s2.u3 = spk(D.dictation.utter3Heard, s2.e1Apply + 1.4, WPS, 3);
  s2.ptr2 = s2.u3.end + 0.3; s2.click2 = s2.ptr2 + 0.85;  // click 'pantry la'
  s2.ptr3 = s2.click2 + 0.6; s2.click3 = s2.ptr3 + 0.55;  // click 'Pantrella'
  s2.swap = s2.click3 + 0.15;
  s2.learnt = [s2.click3 + 0.45, s2.click3 + 2.7];
  s2.e2 = spk(D.dictation.edit2.said, s2.click3 + 2.1, WPS, 4);
  s2.e2Scroll = s2.e2.end + 0.2;                          // slip scrolls back to line 1
  s2.e2Strike = s2.e2Scroll + 0.6;                        // 'onboarding' struck
  s2.e2Collapse = s2.e2Strike + 0.4;
  s2.e2Insert = s2.e2Collapse + 0.3;                      // 'first-run' appears
  s2.e2Return = s2.e2Insert + 1.2;                        // scroll back to the end
  s2.e2Hide = s2.e2Insert + 1.3;
  s2.release = s2.e2Return + 1.3;                         // fn released → delivery
  s2.deliver = s2.release + 0.05;
  s2.receipt = [s2.deliver + 0.75, s2.deliver + 3.0];
  s2.end = s2.receipt[1] + 0.5;

  // ---- Scene 3: FLORA + reader ----
  const s3 = T.s3 = {};
  s3.cap = s2.end; s3.hold = s3.cap + 0.6;
  s3.ask = spk(D.flora.ask, s3.hold + 0.7, WPS, 5);
  s3.route = s3.ask.words[1].at + 0.15;
  s3.release = s3.ask.end + 0.2; s3.think = s3.release; s3.thinkLine = s3.think + 0.3;
  s3.morph = s3.think + 2.4;                              // slip → reader
  s3.read = reader(D.flora.reply, s3.morph + 0.8, 3.15, 6);
  s3.fold = s3.read.end + 1.3;                            // reader retracts
  s3.cap2 = s3.fold + 0.2; s3.hudTab = s3.cap2 + 0.3; s3.front = s3.hudTab + 0.15;   // Chrome (article)
  s3.ptrA = s3.front + 0.4; s3.drag = [s3.ptrA + 0.8, s3.ptrA + 2.1];
  s3.hudF8 = s3.drag[1] + 0.5; s3.read2At = s3.hudF8 + 0.25;
  s3.read2 = reader(D.flora.anyText.sentences, s3.read2At + 0.7, 3.15, 7);
  s3.barge = s3.read2.sentences[1].words[4].at + 0.25;    // fn during sentence 2 → barge-in
  s3.hold3 = s3.barge;
  s3.show = spk(D.flora.followUp, s3.barge + 0.6, WPS, 8);
  s3.release3 = s3.show.end + 0.25;
  s3.end = s3.release3;

  // ---- Scene 4: control center (day timeline) ----
  const s4 = T.s4 = {};
  s4.open = s3.end + 0.1; s4.cap = s4.open + 0.3; s4.rowsIn = s4.open + 0.45;
  s4.hold1 = s4.open + 3.8; s4.regroup = spk(D.controlCommands.regroup, s4.hold1 + 0.6, WPS, 9); s4.release1 = s4.regroup.end + 0.2;
  s4.regroupAnim = s4.release1 + 0.3; s4.regroupDur = 1.0;
  s4.hold2 = s4.regroupAnim + s4.regroupDur + 1.4; s4.resolve = spk(D.controlCommands.resolve, s4.hold2 + 0.6, WPS, 10); s4.release2 = s4.resolve.end + 0.2;
  s4.resolveAnim = s4.release2 + 0.3; s4.resolveDur = 1.1;
  s4.ptrRes = s4.resolveAnim + s4.resolveDur + 1.3; s4.clickRes = s4.ptrRes + 0.8;
  s4.ptrWb = s4.clickRes + 2.3; s4.clickWb = s4.ptrWb + 0.6;
  s4.ptrP1 = s4.clickWb + 0.6; s4.clickP1 = s4.ptrP1 + 0.9;
  s4.hold3 = s4.clickP1 + 1.9; s4.approve = spk(D.controlCommands.approve, s4.hold3 + 0.5, WPS, 11); s4.release3 = s4.approve.end + 0.2;
  s4.approved = s4.release3 + 0.3;
  s4.end = s4.approved + 2.3;

  // ---- Scene 5: automations ----
  const s5 = T.s5 = {};
  s5.cap = s4.end; s5.hold = s5.cap + 0.3;
  s5.say = spk(D.automation.said, s5.hold + 0.6, WPS, 12);
  s5.route = s5.say.words[1].at + 0.15; s5.view = s5.route + 0.1;
  s5.fSchedule = s5.say.words[4].at + 0.55;               // 'eight-thirty,'
  s5.fStreams = s5.say.words[13].at + 0.45;               // 'plans,'
  s5.fName = s5.fStreams + 0.6;
  s5.release = s5.say.end + 0.2; s5.fDeliver = s5.release + 0.25; s5.fAccess = s5.fDeliver + 0.5;
  s5.hold2 = s5.fAccess + 1.0; s5.stripe = spk(D.automation.addStripe, s5.hold2 + 0.5, WPS, 13); s5.release2 = s5.stripe.end + 0.2; s5.stripeOn = s5.release2 + 0.3;
  s5.hold3 = s5.stripeOn + 1.6; s5.enable = spk(D.automation.enable, s5.hold3 + 0.5, WPS, 14); s5.release3 = s5.enable.end + 0.2; s5.active = s5.release3 + 0.3;
  s5.hudEsc = s5.active + 3.8; s5.close = s5.hudEsc + 0.15;
  s5.end = s5.close + 1.2;

  // ---- Scene 6: talk + mark (capture length must equal data.capture.length = 0:42) ----
  const s6 = T.s6 = {};
  s6.cap = s5.end; s6.hudTab = s6.cap + 0.2; s6.front = s6.hudTab + 0.15;      // Chrome front (article tab)
  s6.ptrTab = s6.front + 0.3; s6.clickTab = s6.ptrTab + 0.85;                  // plan tab
  s6.hud = s6.clickTab + 0.9; s6.c0 = s6.hud + 0.3;
  const c0 = s6.c0;
  s6.a1 = spk(D.annotations[0].said, c0 + 1.6, WPS, 15);
  s6.ptrCard = c0 + 0.9; s6.circle = [c0 + 2.2, c0 + 3.4]; s6.snap1 = c0 + 3.5; s6.frame1 = s6.snap1 + 0.45;
  s6.a2 = spk(D.annotations[1].said, c0 + 6.4, WPS, 16);
  s6.ptrArrow = c0 + 5.6; s6.arrow = [c0 + 6.6, c0 + 7.5]; s6.snap2 = c0 + 7.6; s6.frame2 = s6.snap2 + 0.45;
  s6.a3 = spk(D.annotations[2].said, c0 + 8.7, WPS, 17);
  s6.label = [s6.a3.words[5].at + 0.5, s6.a3.words[5].at + 1.7]; s6.snap3 = s6.label[1] + 0.05; s6.frame3 = s6.snap3 + 0.45;
  s6.a4 = spk(D.annotations[3].said, c0 + 15.3, WPS, 18);
  s6.strike = [s6.a4.end - 0.1, s6.a4.end + 0.4]; s6.snap4 = s6.strike[1] + 0.05; s6.frame4 = s6.snap4 + 0.45;
  s6.cap2 = c0 + 19.6; s6.ptrMid = c0 + 19.4; s6.scroll1 = [c0 + 20.8, c0 + 22.2];
  s6.hudTab1 = c0 + 25.2; s6.front1 = s6.hudTab1 + 0.15; s6.hudTab2 = c0 + 28.6; s6.front2 = s6.hudTab2 + 0.15;
  s6.scroll2 = [c0 + 31.0, c0 + 32.4];
  s6.ptrLabel = c0 + 33.6; s6.ptrCard2 = c0 + 36.6; s6.ptrAway = c0 + 39.4;
  s6.hudStop = c0 + 41.3; s6.stop = c0 + 42.0; s6.end = s6.stop;

  // ---- Scene 7: payload ----
  const s7 = T.s7 = {};
  // read the receipt, bring the terminal forward, then ⌘C tears the receipt off into the visible prompt, ⌘V pastes
  s7.stop = s6.stop; s7.receipt = s7.stop + 0.25; s7.cap = s7.stop + 0.5;
  s7.hudTab = s7.receipt + 4.4; s7.front = s7.hudTab + 0.15;
  s7.hudCopy = s7.front + 1.1; s7.copy = s7.hudCopy + 0.2; s7.tearDur = 0.8;
  s7.chip = [s7.copy + 0.9, s7.copy + 3.2];
  s7.hudPaste = s7.copy + 1.0; s7.paste = s7.hudPaste + 0.2;
  s7.end = s7.paste + 3.2;

  // ---- Scene 8: end card ----
  const s8 = T.s8 = {};
  s8.fade = s7.end; s8.lines = s8.fade + 0.9; s8.name = s8.lines + 5 * 0.45 + 1.0; s8.end = s8.name + 3.4;
  T.end = s8.end;

  // every user utterance (drives the ink trace); every reader programme (drives the speaking ticks)
  window.SPEECH = [s2.u1, s2.e1, s2.u3, s2.e2, s3.ask, s3.show, s4.regroup, s4.resolve, s4.approve, s5.say, s5.stripe, s5.enable, s6.a1, s6.a2, s6.a3, s6.a4];
  window.READS = [s3.read, s3.read2];
  // key holds: [press, release]
  T.holds = [[s2.hold, s2.release], [s3.hold, s3.release], [s3.hold3, s3.release3], [s4.hold1, s4.release1], [s4.hold2, s4.release2], [s4.hold3, s4.release3], [s5.hold, s5.release], [s5.hold2, s5.release2], [s5.hold3, s5.release3]];
  window.T = T;
})();
