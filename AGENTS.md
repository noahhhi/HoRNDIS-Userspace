# HoRNDIS Userspace project guide

## Project mission

HoRNDIS Userspace lets an Android phone provide USB tethering to macOS. It is a userspace successor to the abandoned HoRNDIS kernel-extension project and must not require disabling System Integrity Protection.

The product consists of:

- a privileged background service that handles USB RNDIS and the virtual Ethernet interface; and
- a lightweight menu bar app that shows status and controls the service.

Prefer native Apple frameworks and native SwiftUI/AppKit controls. Do not replace system controls, materials, menus, switches, animation, accent colors, dark mode behavior, or accessibility behavior with hand-drawn approximations when a supported native API exists.

## Supported systems

- Minimum deployment target: macOS 11.
- Architectures: Intel (`x86_64`) and Apple silicon (`arm64`).
- Keep the privileged service and menu bar app compatible with both architectures.
- Use availability checks for APIs newer than macOS 11 and provide a supported fallback.

## Product requirements

- Android's native USB tethering must work without a kernel extension and without disabling SIP.
- Normal reconnect, disconnect, status, and login-start operations must not repeatedly request administrator authorization.
- Request administrator authorization only for installing or repairing the fixed privileged service.
- The menu bar app must remain lightweight, refresh visible status once per second, follow the system appearance and selected accent color, and support per-app language selection in System Settings.
- Prefer standard macOS menu geometry, selection geometry, SF Symbols, spacing, keyboard behavior, and accessibility semantics.
- Treat menu geometry as a shared invariant: every row uses the same icon column, icon size, text baseline/start position, row height, and vertical rhythm. Every interactive row—including authorization, Details, expanded actions, and Quit—uses the same selection inset, height, and corner geometry. Implement these values through shared metrics/components so one row cannot silently diverge.
- Preserve the native system switch material and animation.
- Details should expand and collapse smoothly using native SwiftUI/AppKit animation APIs.
- Follow `docs/MENU_UI_GUIDELINES.md` as the implementation and acceptance
  contract for the menu bar UI. Treat commit `2c209a7` as the functional UI
  baseline, but do not restore its root `containerShape` corner override.
- Keep the public-framework boundary explicit: SwiftUI documents `.window` as
  a popover-like window, not an `NSMenu`. Its compositor-owned outer curve
  cannot be changed by a root `containerShape`, and AppKit exposes no radius
  property for `MenuBarExtra` or `NSPopover`. Never claim pixel-identical
  `NSMenu` exterior corners while retaining `.window`. If exact `NSMenu`
  exterior geometry becomes mandatory, pause for an explicit architecture
  decision because switching to `NSMenu`, drawing a custom panel, or using
  private host APIs changes other product requirements.

## Distribution

Changes are maintained on GitHub. Supported distribution paths are:

- one downloadable installer package in GitHub Releases; and
- Homebrew installation through the project's tap.

Release artifacts must contain the background service, menu bar app, CLI, uninstall support, and manual page as applicable. Homebrew and GitHub installers must install prebuilt universal artifacts; end users should not need Xcode or Command Line Tools merely to install the release.

Do not commit secrets, administrator passwords, local authorization artifacts, generated agent transcripts, personal paths, signing credentials, or other sensitive machine-specific data.

## Build and verification

- Follow the repository Makefile and scripts instead of introducing an unrelated build system.
- For CPU-heavy local builds and tests, follow the workspace Apple-silicon performance policy and use `$HOME/.codex/bin/codex-performance-exec` when available.
- Default heavy parallel work to the performance-core count, not all logical cores.
- Verify both `arm64` and `x86_64` outputs when changing shipped code.
- Test the actual installed menu bar app, including the inactive-menu accent state, icon alignment, light/dark appearance, disclosure animation, and one-second visible refresh. An offscreen control render alone is insufficient.
- Before publishing, build the installer, inspect its payload, install it locally, and verify CLI help/man output plus service and menu bar behavior.
- Do not publish, push, tag, create a Release, or update the Homebrew tap until the user has accepted the local test build.
