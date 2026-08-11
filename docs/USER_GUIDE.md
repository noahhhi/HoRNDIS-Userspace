# HoRNDIS Userspace Guide

## Requirements

- macOS 11 or later. Apple Silicon and Intel are supported by the build and release process.
- An Android device that exposes a supported RNDIS USB control/data pair.
- A data-capable USB cable.
- Administrator authorization once when installing or upgrading the network service.

No paid Apple Developer account, DriverKit entitlement, reduced-security boot mode, or SIP change is needed.

## Install

```sh
brew install noahhhi/tap/horndis && horndis-install
```

The Homebrew Formula installs both the network binary and menu bar app. `horndis-install` asks for administrator authorization once, copies the network daemon to `/Library/PrivilegedHelperTools`, starts its LaunchDaemon, and installs the current user's menu bar LaunchAgent. The password is handled only by macOS `sudo` and is never stored.

The universal `.pkg` attached to GitHub Releases is a one-package alternative. Opening it installs and activates both components with one Installer authorization. The package is not notarized because this personal project has no paid Developer ID, so macOS may require **Open Anyway** in Privacy & Security; the Homebrew source build is preferred.

Enable **USB tethering** in Android settings. The service will discover the RNDIS interfaces automatically while leaving a separate ADB interface available.

## Menu bar

The status item uses Apple SF Symbols and is deliberately compact by default:

- connected Android device name;
- received and transmitted bytes for the current USB session;
- current connection duration;
- persistent administrator authorization state;
- a USB Tethering switch at the right edge;
- a Launch at Login switch;
- the system-animated Details disclosure.

Expanding Details adds the DHCP address, feth interface, device MAC, service process ID, last service detail, log access, project link, and copyable diagnostics in the same panel.

The status item is a native macOS template symbol, and the menu uses dynamic system colors. Both follow the current light or dark appearance automatically, including menu bars whose appearance differs from the app appearance.

On macOS 13 and later, HoRNDIS uses SwiftUI's native window-style `MenuBarExtra`. macOS aligns the panel to the status item and renders its switches with the selected system accent color without making HoRNDIS the foreground app. Details uses the native `DisclosureGroup` animation; macOS 14 and later uses Apple's preset smooth spring. macOS 11 and 12 use an equivalent `NSPopover` fallback.

**Authorization: Granted** means the root-owned network helper and its LaunchDaemon configuration are securely installed. If either is missing, incorrectly owned, writable by non-root users, or invalid, the menu reports **Authorization: Required** and adds **Authorize and Install…** directly below it. That action uses the standard macOS administrator authentication dialog to execute only the fixed `horndis service install` command bundled with the app. HoRNDIS never receives or stores the password. The equivalent terminal workflow remains `horndis-install`.

Turning the **USB Tethering** switch off pauses the RNDIS bridge but keeps the background service available. Turning it on resumes discovery and connects when Android USB tethering is enabled. It cannot turn on Android's tethering setting remotely.

The menu bar app reads `/var/run/horndis/status.json` every two seconds while closed and every second while its panel is visible. It updates the existing labels and native switches in place instead of rebuilding the open panel. It does not inspect packet contents or send telemetry. The runtime directory, status file, and control socket are accessible only to the current console user and root. Connection requests go to `/var/run/horndis/control.sock` and also receive a peer-UID check.

## Command-line status

```sh
horndis probe
ifconfig feth99
scutil --nwi
ipconfig getsummary feth99
tail -f /var/log/horndis.log
```

The Network settings panel does not list `feth99`. It is a dynamically cloned Ethernet interface and is published in the live SystemConfiguration state rather than as a persistent Network Service. `scutil --nwi` and the menu bar app show the effective connection.

## Upgrade

```sh
brew update
brew upgrade horndis
horndis-install
```

Only reinstalling the privileged service requires administrator authorization. Normal boot, reconnect, menu-bar use, and login startup are silent. The resident root process is a minimal supervisor; USB and RNDIS processing runs under the current console user. See [Privilege model](PRIVILEGE_MODEL.md).

## Uninstall

```sh
horndis-status uninstall
sudo horndis service uninstall
brew uninstall horndis
```

## Testing the phone path

When Wi-Fi or a VPN remains active on the Mac, bind diagnostics to the USB interface:

```sh
ping -b feth99 8.8.8.8
```

VPN applications using fake-IP DNS can return an address reachable only through their tunnel. A failed interface-bound request to that fake address does not indicate an RNDIS failure. Compare the system resolver with the Android DHCP DNS server when diagnosing this case.

See [Known limitations](LIMITATIONS.md) before reporting a compatibility problem.
