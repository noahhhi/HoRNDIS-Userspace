# HoRNDIS Userspace Guide

## Requirements

- macOS 11 or later on Apple silicon or Intel.
- An Android device that exposes a supported RNDIS USB control/data pair.
- A data-capable USB cable.
- Administrator authorization once when installing or upgrading the network service.

HoRNDIS runs in user space rather than as a kernel extension, so users do not need to reduce boot security or disable SIP.

## Install

```sh
brew install --cask noahhhi/tap/horndis
```

Or install the package directly:

1. Download the universal `.pkg` from [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases).
2. Try to open the downloaded `.pkg`.
3. If macOS blocks it, open **System Settings → Privacy & Security**.
4. Click **Open Anyway** for the HoRNDIS package.
5. Enter an administrator password when prompted, then complete the installation.

> [!IMPORTANT]
> This project currently uses a free Apple Developer account, which cannot provide the paid Developer ID certificate required to sign and notarize the installer for public distribution. macOS may therefore block the first launch until you approve it with **Open Anyway**. You do not need to disable SIP or reduce system security.

Enable **USB tethering** in Android settings. The service will discover the RNDIS interfaces automatically while leaving a separate ADB interface available.

## Menu bar

The status item uses Apple SF Symbols and is deliberately compact by default:

- connected Android device name;
- received and transmitted bytes for the current USB session;
- current connection duration;
- persistent administrator authorization state;
- a USB Tethering switch at the right edge;
- a Launch at Login switch;
- a native Details submenu.

Opening Details shows the DHCP address, feth interface, device MAC, service process ID, last service detail, service-log access, a diagnostic-report save action, and a guided bug-report action in a native submenu.

The status item is a native macOS template symbol, and the menu uses dynamic system colors. Both follow the current light or dark appearance automatically, including menu bars whose appearance differs from the app appearance.

HoRNDIS uses AppKit's `NSStatusItem`, `NSMenu`, and `NSSwitch` on every supported macOS version. macOS therefore owns the menu frame, outer and highlighted-item corners, spacing, tracking, submenu animation, light/dark material, and selected system accent color. HoRNDIS does not draw or clip a popover-shaped replacement and does not become the foreground app while its menu is open.

**Authorization: Granted** means the root-owned network helper and its LaunchDaemon configuration are securely installed. If either is missing, incorrectly owned, writable by non-root users, or invalid, the menu reports **Authorization: Required** and adds **Authorize and Install…** directly below it. That action uses the standard macOS administrator authentication dialog to execute only the fixed `horndis service install` command bundled with the app. HoRNDIS never receives or stores the password. The equivalent terminal workflow is `horndis install`.

Turning the **USB Tethering** switch off pauses the RNDIS bridge but keeps the background service available. Turning it on resumes discovery and connects when Android USB tethering is enabled. It cannot turn on Android's tethering setting remotely.

The menu bar app reads `/var/run/horndis/status.json` every two seconds while closed and every second while its panel is visible. It updates the existing labels and native switches in place instead of rebuilding the open panel. It does not inspect packet contents or send telemetry. The runtime directory, status file, and control socket are accessible only to the current console user and root. Connection requests go to `/var/run/horndis/control.sock` and also receive a peer-UID check.

## Command-line status

```sh
horndis status
horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
horndis probe
scutil --nwi
tail -f /var/log/horndis.log
```

`horndis status` and menu Details show the selected macOS-facing interface. Use that name with `ifconfig` or `ipconfig getsummary`.

If the menu bar app has been quit, reopen it from Applications, Launchpad, or
Spotlight, or run `horndis start`. Use `horndis stop` to hide it without
disabling login startup, and `horndis restart` after troubleshooting. Run
`horndis help` or `man horndis` for the complete command reference.

The Network settings panel does not list the selected `feth<number>` interface. It is dynamically cloned and published in the live SystemConfiguration state rather than as a persistent Network Service. HoRNDIS prefers `feth99`/`feth98`, automatically skips the entire pair when either name already exists, and never adopts or removes another application's interface. `scutil --nwi`, `horndis status`, and the menu bar app show the effective connection.

## Stuck at Configuring DHCP

Current builds re-enable the selected macOS-facing feth interface and restart the DHCP client after every successful USB/RNDIS connection. This also covers reconnects after boot, login, sleep, cable changes, and Android tethering changes; no new administrator prompt is required.

If an older installed build remains at **Configuring DHCP** after the device name appears, its one-time boot DHCP setup may have been cleared by macOS before the phone connected. Restore that session with:

```sh
sudo ifconfig feth99 up
sudo ipconfig set feth99 DHCP
```

Then turn Android USB tethering off and on. Upgrade or reinstall HoRNDIS to obtain the automatic per-connection repair. If a current build still has no address, use the interface printed by `horndis status` with `ipconfig getsummary <interface>` and inspect `/var/log/horndis.log`; the menu should report a DHCP-refresh error rather than remain indefinitely in the configuring state when the privileged refresh itself fails.

## Upgrade

```sh
brew update
brew upgrade --cask horndis
```

Only reinstalling the privileged service requires administrator authorization. Normal boot, reconnect, menu-bar use, and login startup are silent. The resident root process is a minimal supervisor; USB and RNDIS processing runs under the current console user. See [Privilege model](PRIVILEGE_MODEL.md).

## Uninstall

```sh
horndis uninstall
brew uninstall --cask horndis
```

## Testing the phone path

When Wi-Fi or a VPN remains active on the Mac, bind diagnostics to the USB interface:

```sh
ping -b <interface> 8.8.8.8
```

Replace `<interface>` with the value printed by `horndis status`.

VPN applications using fake-IP DNS can return an address reachable only through their tunnel. A failed interface-bound request to that fake address does not indicate an RNDIS failure. Compare the system resolver with the Android DHCP DNS server when diagnosing this case.

For a bug report, reproduce the problem and immediately save a fresh diagnostic report from menu Details or with `horndis diagnostics FILE`. Review the file, then attach it to the required upload in the GitHub bug form. See [Reporting a bug](BUG_REPORTING.md) for the full workflow and privacy details, and [Known limitations](LIMITATIONS.md) before reporting a compatibility problem.
