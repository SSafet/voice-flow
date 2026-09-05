# VF-65: workspace focus handoff

Run `./scripts/test-panel-focus.sh` from an unlocked macOS desktop session.
It compiles the real app support sources with a small AppKit test entry point
and isolates storage in a temporary `VOICE_FLOW_CONFIG_ROOT`. It does not start
the app delegate, backend, agent runtimes, or synthesize input.

The regression checks passive display without keyboard focus, explicit open
with keyboard focus, synchronous dismissal and focus release, capture routing
after dismissal, and immediate explicit/passive reopening. AppKit events must
be dispatched while settling; running only the foundation run loop does not
process window activation events.

For physical click-away QA, open Voice Flow from the pill, click an exposed
text field in another app once, and type. That app should receive the typing
and the workspace should disappear. Repeat after using the workspace search
or composer, then reopen Voice Flow and verify typing and paste there. Also
check a right-click outside and a rapid close/reopen.

The computer-use smoke check can verify typing in both apps, but its targeted
app events do not exercise Voice Flow's global outside-click monitor. The
physical click sequence remains part of Safet's ticket QA.
