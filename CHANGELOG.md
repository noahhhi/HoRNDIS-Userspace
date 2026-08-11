# Changelog

## 0.2.2 - 2026-08-12

- Avoid SwiftUI's external `@State` macro for action-row hover tracking so source builds work with the standalone macOS 27 Command Line Tools as well as full Xcode.
- Validate the complete Homebrew source build, application bundle installation, and Formula test path against the published release archive.

## 0.2.1 - 2026-08-12

- Menu controls now use the system accent color and Apple SF Symbol icon columns consistently.
- Replaced nested tracking areas with `NSMenuItem.isHighlighted` to prevent stuck hover states.
- Replaced unsupported AppKit menu resizing with a native SwiftUI Details disclosure.
- Refresh traffic, duration, and connection controls every second while the menu is open.
- Restored the native system switch appearance while retaining the selected accent color.
- Preserve stable Homebrew executable symlinks in the login LaunchAgent across upgrades.
- Added a complete macOS application icon and sealed it into the status app bundle.
- Added one-command Homebrew activation and a unified GitHub Release installer package.
- Let the native window-style menu bar scene render enabled switches with the selected system accent color.
- Let macOS render the menu bar symbol as a template image for automatic light and dark contrast.
- Show persistent authorization state and offer a standard macOS administrator install action when required.
- Bundle the fixed network installer tool inside the menu bar app for Homebrew and Release packages.
- Replaced manual menu tracking with the native window-style `MenuBarExtra`, preserving foreground-app focus while macOS handles status-item alignment and accent-colored switches.
- Replaced the separate Details submenu with a native `DisclosureGroup` using Apple's smooth spring animation on macOS 14 and later.
- Prepopulate the menu model before its first presentation so opening no longer triggers a second size/layout pass.
- Realign highlighted action rows with summary and switch rows, and use shield status symbols for persistent authorization.
- Add matching English and Simplified Chinese GitHub landing pages with an in-page language switch.
- Exclude local agent instructions, agent state, and Finder metadata from published source archives.

## 0.2.0 - 2026-08-11

- Lightweight Swift/AppKit menu bar status app with English and Chinese labels.
- Compact device, session traffic, duration, login-start, and native USB Tethering switch controls.
- Expandable IP, interface, device MAC, service PID, log, project, and diagnostics details.
- Atomic runtime status publication and a console-user-authenticated local control socket.
- Privilege separation: root performs fixed network setup while the current console user handles all USB, RNDIS, status, and control processing.
- Best-effort deployment target lowered to macOS 11.
- Universal Apple Silicon and Intel menu bar release builds.
- English and Chinese user guides plus a dedicated limitations reference.

## 0.1.0 - 2026-08-11

- First entitlement-free macOS user-space RNDIS implementation.
- IOUSBHost discovery and exclusive ownership of only the RNDIS control/data interfaces.
- RNDIS initialize, query, packet filter, aggregated packet RX, and bulk TX/RX.
- feth/BPF virtual Ethernet bridge with DHCP configuration.
- Root LaunchDaemon installer with automatic USB reconnect.
- Pixel 4 XL end-to-end validation while retaining ADB connectivity.
- Homebrew tap and universal-release automation.
