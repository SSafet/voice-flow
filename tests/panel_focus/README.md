# VF-65 / VF-66: workspace focus and sizing

Run `./scripts/test-panel-focus.sh` from an unlocked macOS desktop session.
It compiles the real app support sources with a small AppKit test entry point
and isolates storage in a temporary `VOICE_FLOW_CONFIG_ROOT`. It does not start
the app delegate, backend, agent runtimes, or synthesize input.

The regression checks passive display without keyboard focus, explicit open
with keyboard focus, synchronous dismissal and focus release, capture routing
after dismissal, and immediate explicit/passive reopening. AppKit events must
be dispatched while settling; running only the foundation run loop does not
process window activation events.

It also attaches a long label in a hidden pane, reveals that pane, and reopens
on a simulated smaller display. The actual window frame must stay at the
positioned size in each case. Before VF-66, even a hidden label enlarged the
window; a live workspace was measured at 21,204 points wide and macOS reported
capture stream failures when the user tried to screenshot it.

For physical click-away QA, open Voice Flow from the pill, click an exposed
text field in another app once, and type. That app should receive the typing
and the workspace should disappear. Repeat after using the workspace search
or composer, then reopen Voice Flow and verify typing and paste there. Also
check a right-click outside and a rapid close/reopen.

The computer-use smoke check can verify typing in both apps, but its targeted
app events do not exercise Voice Flow's global outside-click monitor. The
physical click sequence remains part of Safet's ticket QA.
