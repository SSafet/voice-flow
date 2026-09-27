// Timeline for Concept C — Island. Every anchor is derived from speech timelines so a change in
// one utterance shifts everything after it. Exposes window.T (times) and window.SPEECH.
(function () {
  const D = window.VF, K = window.K;
  const spk = (s, at, wps = 2.7, seed = 1) => { const words = K.speechTimeline(s, at, wps, seed); return { words, start: at, end: K.endOf(words), text: s }; };
  // sentences read by the TTS reader: [{words, start, end}], sequential with a gap
  function reader(sentences, at, wps, seed) {
    let t = at; const out = [];
    sentences.forEach((s, i) => { const u = spk(s, t, wps, seed + i); out.push(u); t = u.end + 0.4; });
    return { sentences: out, start: at, end: out[out.length - 1].end };
  }
  const T = {};
  T.title = { a: 0, b: 4.0 };
  T.rest = { a: 4.0, b: 9.6, cap: 4.3 };

  // ---- Scene 2: dictation ----
  const s2 = T.s2 = {};
  s2.cap = 9.6;
  s2.ptr = 10.1; s2.click = 11.0;
  s2.hud = 12.0; s2.mic = 12.2;                       // fn held → the island grows
  s2.u1 = spk(D.dictation.utter1, 12.9, 2.7, 1);
  s2.rev1 = { merge: s2.u1.words[2].at + 0.25 };      // "on boarding" → "onboarding"
  s2.rev2 = { fix: s2.u1.words[9].at + 0.3 };         // "desk" → "task"
  s2.e1 = spk(D.dictation.edit1.said, s2.u1.end + 1.0, 2.7, 2);
  s2.e1Swap = s2.e1.end + 0.4;                        // "ask" inserted
  s2.e1Fade = s2.e1Swap + 0.9;                        // EDIT line leaves the band
  s2.u3 = spk(D.dictation.utter3Heard, s2.e1Swap + 1.7, 2.7, 3);
  s2.ptr2 = s2.u3.end + 0.4; s2.click2 = s2.ptr2 + 0.9;        // click "pantry la" → alternatives
  s2.ptr3 = s2.click2 + 0.7; s2.click3 = s2.ptr3 + 0.7;        // pick Pantrella
  s2.swapWord = s2.click3 + 0.15;
  s2.learnt = [s2.click3 + 0.5, s2.click3 + 2.7];
  s2.e2 = spk(D.dictation.edit2.said, s2.click3 + 2.3, 2.7, 4);
  s2.e2Scroll = s2.e2.words[3].at + 0.45;             // "at the start" → window scrolls to the top
  s2.e2Swap = s2.e2.end + 0.4;                        // onboarding → first-run
  s2.e2Fade = s2.e2Swap + 0.9;
  s2.e2Return = s2.e2Swap + 1.5;                      // window scrolls back to the end
  s2.hudDone = s2.e2Return + 1.4; s2.deliver = s2.hudDone + 0.1;
  s2.arrive = s2.deliver + 0.85;                      // trail reaches the field
  s2.retract = s2.deliver + 0.12;
  s2.receipt = [s2.deliver + 1.35, s2.deliver + 3.6];
  s2.end = s2.receipt[1] + 0.5;

  // ---- Scene 3: FLORA + reader ----
  const s3 = T.s3 = {};
  s3.cap = s2.end; s3.hud = s3.cap + 0.5; s3.mic = s3.hud + 0.2;
  s3.ask = spk(D.flora.ask, s3.mic + 0.6, 2.7, 5);
  s3.route = s3.ask.words[1].at + 0.15;
  s3.hudDone = s3.ask.end + 0.3; s3.think = s3.ask.end + 0.4; s3.thinkLine = s3.think + 0.35;
  s3.morph = s3.think + 2.4;                          // island → reader
  s3.read = reader(D.flora.reply, s3.morph + 0.8, 3.05, 6);
  s3.readEnd = s3.read.end; s3.fold = s3.readEnd + 1.6;
  s3.cap2 = s3.fold + 0.1; s3.hudTab = s3.cap2 + 0.4; s3.front = s3.hudTab + 0.15;
  s3.ptrA = s3.front + 0.5; s3.drag = [s3.ptrA + 0.9, s3.ptrA + 2.3];
  s3.hudF8 = s3.drag[1] + 0.6; s3.reader2 = s3.hudF8 + 0.2;
  s3.read2 = reader(D.flora.anyText.sentences, s3.reader2 + 0.7, 3.05, 7);
  s3.barge = s3.read2.sentences[1].words[6].at + 0.2; // fn pressed mid-sentence: playback stops
  s3.hud3 = s3.barge - 0.2;
  s3.show = spk(D.flora.followUp, s3.barge + 0.7, 2.7, 8);
  s3.end = s3.show.end + 0.35;

  // ---- Scene 4: control center ----
  const s4 = T.s4 = {};
  s4.open = s3.end; s4.cap = s4.open + 0.2; s4.rows = s4.open + 0.35;
  s4.regroup = spk(D.controlCommands.regroup, s4.open + 3.9, 2.7, 9);
  s4.regroupAnim = s4.regroup.end + 0.4;
  s4.resolve = spk(D.controlCommands.resolve, s4.regroupAnim + 1.3 + 1.3, 2.7, 10);
  s4.resolveAnim = s4.resolve.end + 0.4;
  s4.ptrRes = s4.resolveAnim + 1.1 + 1.3; s4.clickRes = s4.ptrRes + 0.9;
  s4.ptrWb = s4.clickRes + 2.3; s4.clickWb = s4.ptrWb + 0.7;
  s4.ptrP1 = s4.clickWb + 0.6; s4.clickP1 = s4.ptrP1 + 1.0;
  s4.approve = spk(D.controlCommands.approve, s4.clickP1 + 2.3, 2.7, 11);
  s4.approved = s4.approve.end + 0.4;
  s4.end = s4.approved + 2.0;

  // ---- Scene 5: automations ----
  const s5 = T.s5 = {};
  s5.cap = s4.end;
  s5.say = spk(D.automation.said, s5.cap + 0.6, 2.7, 12);
  s5.route = s5.say.words[1].at + 0.15;               // sheet → Automations
  const w = s5.say.words;
  s5.fSchedule = w[4].at + 0.7; s5.fStreams = w[13].at + 0.5; s5.fName = s5.fStreams + 0.7;
  s5.fDeliver = s5.say.end + 0.3; s5.fAccess = s5.fDeliver + 0.5;
  s5.stripe = spk(D.automation.addStripe, s5.fAccess + 1.3, 2.7, 13);
  s5.stripeOn = s5.stripe.end + 0.35; s5.stripeConn = s5.stripeOn + 0.6;
  s5.enable = spk(D.automation.enable, s5.stripeOn + 1.7, 2.7, 14);
  s5.active = s5.enable.end + 0.35; s5.list = s5.active + 0.3;
  s5.ptrGl = s5.active + 1.7; s5.clickGl = s5.ptrGl + 0.8;   // "All data streams"
  s5.hudEsc = s5.clickGl + 3.0; s5.close = s5.hudEsc + 0.2;
  s5.end = s5.close + 1.2;

  // ---- Scene 6: talk + mark ----
  const s6 = T.s6 = {};
  s6.cap = s5.end; s6.hudTab = s6.cap + 0.3; s6.front = s6.hudTab + 0.15;
  s6.ptrTab = s6.front + 0.3; s6.clickTab = s6.ptrTab + 0.9;
  s6.hud = s6.clickTab + 0.8; s6.c0 = s6.hud + 0.4;
  const c0 = s6.c0;
  s6.a1 = spk(D.annotations[0].said, c0 + 2.6, 2.7, 15);
  s6.ptrCard = c0 + 1.4; s6.circle = [c0 + 3.0, c0 + 4.4]; s6.snap1 = c0 + 4.5; s6.shot1 = c0 + 4.7;
  s6.a2 = spk(D.annotations[1].said, c0 + 7.3, 2.7, 16);
  s6.ptrArrow = c0 + 6.6; s6.arrow = [c0 + 7.5, c0 + 8.6]; s6.snap2 = c0 + 8.7; s6.shot2 = c0 + 8.9;
  s6.a3 = spk(D.annotations[2].said, c0 + 10.5, 2.7, 17);
  s6.label = [s6.a3.words[6].at + 0.5, s6.a3.words[6].at + 1.8]; s6.snap3 = s6.label[1]; s6.shot3 = s6.label[1] + 0.2;
  s6.a4 = spk(D.annotations[3].said, c0 + 16.6, 2.7, 18);
  s6.strike = [s6.a4.end + 0.3, s6.a4.end + 0.8]; s6.snap4 = s6.strike[1]; s6.shot4 = s6.strike[1] + 0.2;
  s6.cap2 = c0 + 21.0; s6.ptrMid = c0 + 21.0; s6.scroll1 = [c0 + 22.0, c0 + 23.3];
  s6.hudTab1 = c0 + 25.6; s6.front1 = c0 + 25.8; s6.hudTab2 = c0 + 28.8; s6.front2 = c0 + 29.0;
  s6.scroll2 = [c0 + 31.4, c0 + 32.7];
  s6.ptrLabel = c0 + 33.8; s6.ptrCard2 = c0 + 37.0;
  s6.hudStop = c0 + 41.2; s6.stop = c0 + 42.0; s6.end = s6.stop;

  // ---- Scene 7: payload ----
  const s7 = T.s7 = {};
  s7.stop = s6.stop; s7.summary = s7.stop + 0.3; s7.sheet = s7.stop + 1.7; s7.cap = s7.stop + 0.5;
  s7.hudCopy = s7.sheet + 4.6; s7.copy = s7.hudCopy + 0.2;
  s7.receipt = [s7.copy + 0.7, s7.copy + 3.2];
  s7.hudTab = s7.copy + 1.1; s7.front = s7.hudTab + 0.2;
  s7.hudPaste = s7.front + 0.9; s7.paste = s7.hudPaste + 0.2;
  s7.end = s7.paste + 2.8;

  // ---- Scene 8: end card ----
  const s8 = T.s8 = {};
  s8.fade = s7.end; s8.lines = s8.fade + 0.9; s8.name = s8.lines + 5 * 0.45 + 1.0; s8.end = s8.name + 3.2;
  T.end = s8.end;

  // all user speech (for the level meter)
  window.SPEECH = [s2.u1, s2.e1, s2.u3, s2.e2, s3.ask, s3.show, s4.regroup, s4.resolve, s4.approve, s5.say, s5.stripe, s5.enable, s6.a1, s6.a2, s6.a3, s6.a4];
  window.T = T;
})();
