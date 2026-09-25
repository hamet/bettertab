# bettertab

A Cmd+Tab replacement for macOS that switches between **windows**, not applications.

If the current app has several windows, Cmd+Tab walks through them first, and only
then moves on to the next application. Minimized windows and windows living on other
Spaces are included.

Single file of Swift, no dependencies, no Xcode project.

## Behaviour

* **Cmd+Tab** — next window, **Cmd+Shift+Tab** — previous.
* Hold Cmd, tap Tab as many times as needed, release Cmd to switch.
* **Esc** cancels, arrow keys move the selection, mouse hover + click works too.
* The panel is a vertical column docked to the **right edge** of the screen, not a
  horizontal strip in the middle. Each row: window title, application name, its icon.
* The window you are switching **from** (the one that has the focus right now) is
  marked with an accent dot and a faint plate; the current **selection** is the
  accent-filled row.
* Order: applications in most-recently-used order; inside each application, its own
  windows in most-recently-used order; minimized windows last within their app.
* The system Cmd+Tab switcher is suppressed while bettertab is running.

## Build

```sh
./build.sh              # compile, ad-hoc sign, install to /usr/local/bin
./build.sh --build-only # just compile into the current directory
```

Then grant Accessibility to the binary:

**System Settings → Privacy & Security → Accessibility → `+`** →
Cmd+Shift+G → `/usr/local/bin` → `bettertab`.

The binary is ad-hoc signed by `build.sh` so the grant survives rebuilds; if a rebuild
ever loses the permission anyway, remove the entry and add it again.

## Autostart

```sh
cp com.user.bettertab.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.bettertab.plist
```

A binary started by launchd has its own TCC context — if the switcher works when you
run `bettertab` from Terminal but not under launchd, re-add `/usr/local/bin/bettertab`
to the Accessibility list while it is running under launchd.

## Configuration

Optional, `~/Library/Application Support/bettertab.json`:

```json
{
  "modifier": "command",
  "includeMinimized": true,
  "maxVisibleRows": 14,
  "width": 380,
  "position": "right",
  "edgeMargin": 16
}
```

* `modifier` — `command`, `option` or `control`. Use `option` if you want to keep the
  system Cmd+Tab switcher intact.
* `includeMinimized` — show minimized windows in the list.
* `maxVisibleRows` — how many rows the panel shows before it starts scrolling.
* `position` — `right` (default), `left` or `center`. With `right` the row layout is
  mirrored: icon at the outer edge, text right-aligned next to it.
* `edgeMargin` — distance from the screen edge, in points.

Restart the agent after editing:
`launchctl kickstart -k gui/$UID/com.user.bettertab`

## How it works

* A head-inserted `CGEventTap` on the session tap intercepts Cmd+Tab before the Dock
  and swallows it.
* The window list is built through the Accessibility API (`AXWindows` of every regular
  application), which is what makes minimized and off-Space windows visible — the
  `CGWindowList` API would show neither.
* AX window elements are mapped to `CGWindowID` via the private
  `_AXUIElementGetWindow` SPI, so windows keep a stable identity for the MRU order.
  If the SPI ever disappears, the code falls back to a pid+title key.
* MRU order is maintained from `NSWorkspace` activation notifications and per-app
  `AXObserver` notifications (focused window changed, window created/destroyed,
  minimized/deminimized, title changed) — no polling.
* The window inventory is rescanned in the background, debounced, and pre-warmed the
  moment the modifier key goes down, so the first Tab press has no visible latency.

## Known limits

* While macOS **Secure Input** is active (a password field is focused), event taps are
  not delivered and the system Cmd+Tab takes over for that moment.
* A few applications do not expose off-Space windows through the Accessibility API;
  those windows appear only once their Space has been visited.
* No window thumbnails — that would require the Screen Recording permission. Icons and
  titles only.

## License

MIT.
