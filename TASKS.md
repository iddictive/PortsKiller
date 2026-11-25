# PortsKiller tasks

## Correct the 0.5.0 workspace and menu bar regressions

Agents, Dev and Ports must expose safe actions in a stable trailing column.
Agent Details must leave the list in place. Make the workspace search prompt
readable, keep the header on the same material as the list, and avoid awkward
scroll-edge fading.

Find local Codex and Claude Code work without mistaking runtimes and services
for stoppable commands. Show verified repository folders, resource use, and
command identity. On menu-bar right-click, provide Apps and Processes with
separate searches, process categories, and confirmed close/stop for verified
targets; do not limit process search to heavy activity.

Local verification uses the current native views at minimum width and an
observed SIGTERM on a disposable child only. Verify the real right-click
popover once the user's GUI session is available; offscreen rendering does
not prove the interaction. A public release is separate.

Workspace chrome: keep the native close/minimize/zoom buttons over the navigation
rail and the title/search on the same full-height material. Check on a native
window capture that the first 28pt use the same backdrop as the content; this
seam is not visible in a SwiftUI-only screenshot. At minimum and ordinary width,
switch routes and scroll: the search stays anchored and its prompt fits.

Search: the empty prompt must be more subdued than input but readable on both
light and dark glass. A click outside releases focus without deleting the query
or consuming the clicked control's action. Check both workspace and quick search.

Footer: show time since the selected view's last completed scan. Pause freezes
automatic workspace scans, not the results or their age; manual refresh remains
available and resume refreshes immediately. The menu-bar system meter is separate.
