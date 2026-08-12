# Menu bar UI implementation contract

The HoRNDIS Status interface follows Apple's native macOS menu bar and control
behavior. The accepted functional baseline is commit `2c209a7` (identical UI
source to `49ebe55`), with the old root `containerShape` override removed.

## Apple framework choices

- On macOS 13 and later, use SwiftUI `MenuBarExtra` with the `.window` style.
  Apple describes this style as the menu bar presentation for complex or
  data-rich content containing standard controls.
- On macOS 11 and 12, use an AppKit `NSPopover` compatibility path. Let AppKit
  draw its exterior shape and material; never draw, mask, clip, or hard-code the
  popover's outer corner radius.
- Use a native SwiftUI `Toggle` with the `.switch` style and `.mini` control
  size. The switch must retain the system's click and drag interactions,
  animation, accent color, accessibility role, material, and active/inactive
  behavior. Do not replace it with a Button or a hand-drawn switch.
- Use `DisclosureGroup` and `DisclosureGroupStyle` for Details. Expansion and
  collapse must be one local SwiftUI transition in the existing window; do not
  replace or refresh the complete menu view and do not run a competing AppKit
  frame animation.
- Use SF Symbols, semantic system colors, and template rendering. Do not
  hard-code colors for light, dark, accent, or inactive appearances.

### Public framework boundary

Apple defines the `.window` style as a *popover-like window* whose controls are
laid out like controls in a normal window. It is not the pull-down `.menu`
style used by `NSMenu`. Neither `WindowMenuBarExtraStyle` nor `NSPopover`
exposes an exterior radius or shape property, and `NSWindow` has no public
window-corner radius property. A SwiftUI root `containerShape` describes the
content container but does not alter the compositor-owned window frame or
shadow.

On the current test system, Retina alpha-edge measurement gives approximately
14 pt for the native `.window` exterior and 10 pt for the top-left Apple menu.
Setting the root container shape to 10 pt produced an identical before/after
window alpha mask, confirming that it cannot change this frame. Therefore this
implementation matches the Apple menu's measurable row, icon, selection, and
edge-spacing geometry while leaving the `.window` exterior system-owned.

Pixel-identical `NSMenu` exterior corners would require a different product
architecture: a true `NSMenu` with menu-tracking constraints, a hand-drawn
panel, or unsupported private host access. Do not silently choose any of these
or reintroduce a no-op radius modifier; obtain an explicit product decision and
revalidate native switch dragging, inline disclosure animation, focus,
accessibility, dark mode, and older-system behavior.

## Shared geometry

Geometry is a component-level invariant, not a per-row approximation:

- content width: 286 pt;
- row height: 32 pt for summary, switch, Details, detail, action, and Quit rows;
- icon layout frame: 16 pt;
- normal content horizontal inset: 12 pt;
- interactive selection horizontal inset: 5 pt, matching the measured current
  Apple menu edge inset;
- interactive selection vertical inset: 4 pt, producing a 24 pt selection;
- interactive selection content inset: 7 pt. Together with the 5 pt outer
  selection inset, this preserves the shared 12 pt icon column.
- interactive selection radius: 8 pt, matching the current system menu
  selection curve in pixel comparison. On macOS 26 and later,
  `ConcentricRectangle` also resolves the curve relative to the system container.

The root adds 1 pt below the final 32 pt row. Combined with the selection's
4 pt vertical inset, this leaves the same measured 5 pt bottom edge as the
current Apple menu without changing row or selection height. Re-measure these
values when the system design changes; do not infer them from screenshots at a
different display scale.

Every row uses the same icon column, text start position, font, baseline,
trailing alignment, and vertical rhythm. Individual SF Symbol ink can have
different optical bounds; align symbols through the shared layout frame rather
than distorting glyphs to equal visible widths.

On systems that provide `ConcentricRectangle`, interactive selections next to
the window edge use concentric corners so the system derives the inner radius
from the actual container and inset. Older systems use a continuous rounded
rectangle with an 8 pt fallback radius. Never declare a guessed outer radius to
make the fallback appear concentric.

## Required visual and interaction verification

Test the installed app, not only an offscreen render or probe:

1. Compare collapsed HoRNDIS against commit `2c209a7` for native switch drag,
   Details interaction, typography, icon column, row height, and spacing.
2. Compare HoRNDIS with the Apple menu opened from the top-left Apple menu.
   Measure all four exterior corners and the bottom highlighted row's inset,
   height, and concentric relationship to the exterior edge.
3. Drag each switch both within its track and outside the window, release it,
   close, and reopen. There must be no duplicate/floating track or empty window.
4. Expand and collapse Details repeatedly and inspect a recording frame by
   frame. Content must not cross other rows, the window height must change
   continuously, and the complete page must not flash or be replaced.
5. Verify Detail, expanded actions, authorization, and Quit hover selections
   have identical height and horizontal geometry.
6. Verify light mode, dark mode, system accent colors, inactive appearance,
   full-screen menu bar backgrounds, one-second visible refresh, keyboard and
   VoiceOver behavior, and that the previous foreground app remains frontmost.

## Primary Apple references

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Window menu bar extra style](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window)
- [Human Interface Guidelines: Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)
- [Human Interface Guidelines: Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Human Interface Guidelines: Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers)
- [Human Interface Guidelines: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Human Interface Guidelines: Icons](https://developer.apple.com/design/human-interface-guidelines/icons)
- [Human Interface Guidelines: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- [ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle)
- [DisclosureGroupStyle](https://developer.apple.com/documentation/swiftui/disclosuregroupstyle)
- [Unifying your app's animations](https://developer.apple.com/documentation/swiftui/unifying-your-app-s-animations)
