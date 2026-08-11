# Changelog

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
