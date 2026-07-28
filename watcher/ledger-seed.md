---
last-reviewed: never
---

# Observations ledger

Maintained by the nightly review (see ANALYZE.md). One entry per recurring
behavior. Statuses: watching → confirmed → suggested → adopted | rejected.

This file is the review's memory between runs, and it is the only thing in the
watcher directory that cannot be rebuilt — day folders expire, reviews are
written fresh, but everything the reviewer has *learned* lives here. It is
seeded once by `install.sh` and never overwritten afterwards.

`last-reviewed: never` means no day has been reviewed yet: on the first run,
review every day directory present (subject to the usual "fewer than 100
activity lines → do nothing" rule) and replace this value with the newest day
reviewed.

No observations recorded yet.
