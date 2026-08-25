# Menu bar UI implementation contract

HoRNDIS Status uses one native AppKit menu implementation on every supported
system from macOS 11 onward. This architecture intentionally replaces the
former SwiftUI `MenuBarExtra(.window)`/`NSPopover` presentation and its
liquid-glass switches.

## Apple framework choices

- Create the status item with `NSStatusBar` and attach a standard `NSMenu`.
- Build every row from `NSMenuItem`; never attach a custom `view` to a menu
  item and never draw a replacement menu background, highlight, corner, icon,
  checkmark, or submenu arrow.
- Represent **USB Tethering** and **Launch at Login** with ordinary actionable
  `NSMenuItem` instances. Set `state` to `.on` or `.off` so AppKit supplies the
  standard menu checkmark and accessibility state. Do not use `Toggle`,
  `NSSwitch`, a hosted SwiftUI view, or a hand-drawn control.
- Represent **Details** with a standard submenu. AppKit owns the side-opening
  direction, delay, animation, keyboard navigation, highlight, and dismissal.
  Do not restore an in-place disclosure or manually resize a menu/window.
- Use template SF Symbols and semantic system rendering for the status and
  device summary rows and for Details-submenu rows. In the traffic row, use an
  `arrow.up` image as the first upload marker, followed by the transmitted
  total and the explicit `↓` received marker in the title. Do not add a second
  inline upload arrow. If a symbol is absent on an older macOS version, use the
  existing system-symbol fallback.
- Place root-summary symbols in AppKit's state column with `offStateImage`
  while leaving each information item in the `.off` state. This aligns those
  symbols with the native checkmarks below and lets AppKit omit a separate root
  image column. Do not emulate the alignment with indentation, title padding,
  attributed-string offsets, or custom drawing. Details-submenu rows continue
  to use ordinary item images in their independent menu.
- Give each root action only one functional affordance: AppKit's checkmark for
  USB Tethering and Launch at Login, the submenu arrow for Details, and the
  key equivalent for Quit. The authorization warning row owns its shield; the
  adjacent Authorize and Install action must not repeat it. Do not add
  redundant leading images to those rows.
- On macOS 27 and later, request the public `NSMenuItem` image visibility value
  `visible`. The implementation invokes that availability-gated setter
  dynamically so the same source still builds with older SDKs and runs on
  macOS 11+.
- Keep `menu.autoenablesItems = false` and update enabled/state properties from
  the current service snapshot so an unavailable control remains visibly and
  accessibly unavailable.

This is the explicit product decision anticipated by the earlier UI contract:
exact Apple pull-down-menu geometry is more important than retaining the
window-style panel, draggable liquid-glass switches, or inline disclosure.

## Native geometry and appearance

`NSMenu` owns the exterior radius, material, shadow, edge padding, row height,
text baseline, state column, image column, submenu arrow, selected accent
color, light/dark appearance, reduced-transparency behavior, and high-contrast
rendering. HoRNDIS supplies only item titles, template images, state,
enabled/hidden status, actions, and shortcuts. Do not
set `minimumWidth`: AppKit must derive the horizontal margins and final width
from the localized item content, image/state columns, submenu arrows, and key
equivalents.

Because all rows are real menu items, HoRNDIS must not hard-code selection
insets or radii. AppKit reserves the same state and image columns throughout a
menu, including when only some items are checked. Keep each symbol's intrinsic
aspect ratio and never force dissimilar symbols into a common square image
size or apply per-symbol point-size corrections.

Keep the root summary to three information rows: current connection state;
device name and duration separated by a middle dot; and transmitted then
received totals. A valid authorization state is implicit and consumes no row.
Only a required authorization state adds its warning row and the native
Authorize and Install action. Every row remains a standard `NSMenuItem`; do
not replace this compact hierarchy with a custom summary view.

## State-item behavior

- Clicking **USB Tethering** requests the inverse of its current `state`.
  Pending state is displayed immediately and then reconciled with the service
  snapshot. The item is disabled when the unprivileged control socket is not
  available.
- Clicking **Launch at Login** requests the inverse of its current `state` and
  updates the checkmark after the LaunchAgent configuration operation.
- Normal reconnect, state refresh, and either state item never request
  administrator authorization. Only **Authorize and Install…** invokes the
  fixed privileged installation workflow.
- Do not reintroduce switch dragging tests: these rows are intentionally menu
  commands with checked state, not switches.

## Details submenu

The submenu preserves the current feature set:

- DHCP/IP address, selected feth interface, device MAC, service PID, last
  service detail, and current UI error;
- **Save Diagnostic Report…**;
- **Open Service Log**;
- **Report a Bug…**.

Create the submenu items once and update their existing titles, images, hidden
state, and enabled state. Do not rebuild the open submenu during the one-second
refresh cycle.

## Live status and persistence contract

- While the root menu is open, refresh service state, duration, and traffic
  totals once per second. The timer must run in both default and event-tracking
  run-loop modes.
- While connected and visible, send `observe\n` once per refresh to renew the
  three-second service observation lease. Closing the root menu releases the
  lease automatically.
- While closed, the app may read status every two seconds and the service may
  coalesce counter-only writes. Device attachment/removal, connection/error
  state, interface identity, authorization result, and explicit connect or
  disconnect commands must still publish immediately.
- Update the existing root and submenu items in place. Do not replace the
  `NSMenu` during tracking.

## Compatibility contract

- Minimum deployment target remains macOS 11.
- The same AppKit code path must compile for and run on Intel (`x86_64`) and
  Apple silicon (`arm64`).
- Do not add availability-dependent menu behavior unless the macOS 11 path has
  an equivalent native fallback.
- The menu must not activate HoRNDIS as the foreground application merely to
  force a color or control state.
- Keep the status item image templated so it remains visible on dark and
  full-screen menu bars.

## Required visual and interaction verification

Test the installed App rather than only a source probe:

1. Open the top-left Apple menu and HoRNDIS menu under the same appearance;
   verify their exterior corners, row rhythm, highlight geometry, material,
   state/image columns, compact three-row summary, and submenu behavior are
   system-consistent.
2. Verify checked and unchecked states for both commands, including disabled
   USB control state and immediate pending-state feedback. Confirm neither
   checked command adds a redundant image beside the checkmark.
3. Hover and keyboard-select all actionable rows. Confirm native accent color,
   Escape dismissal, arrow-key navigation, Return activation, `⌘Q`, and no
   stuck highlights.
4. Open Details repeatedly and verify the system side submenu contains all
   current rows/actions, updates without flashing, and never leaves an empty or
   oversized window.
5. Keep the root menu open and verify duration/traffic values refresh once per
   second; verify attach, detach, pause, resume, error, authorization, and
   language changes remain correct.
6. Verify light/dark mode, different system accents, increased contrast,
   reduced transparency, full-screen menu bars, all shipped localizations,
   Intel/macOS 11 compilation, VoiceOver state announcements, and that the
   previous foreground app stays frontmost.

## Primary Apple references

- [Human Interface Guidelines: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [NSMenu](https://developer.apple.com/documentation/appkit/nsmenu)
- [NSMenuItem](https://developer.apple.com/documentation/appkit/nsmenuitem)
- [NSMenuItem state](https://developer.apple.com/documentation/appkit/nsmenuitem/state)
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Human Interface Guidelines: Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [Human Interface Guidelines: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
