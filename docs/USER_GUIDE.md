# HoRNDIS Userspace Guide

## Requirements

- macOS 11 or later. Apple Silicon and Intel are supported by the build and release process.
- An Android device that exposes a supported RNDIS USB control/data pair.
- A data-capable USB cable.
- Administrator authorization once when installing or upgrading the network service.

No paid Apple Developer account, DriverKit entitlement, reduced-security boot mode, or SIP change is needed.

## Install

```sh
brew install noahhhi/tap/horndis
sudo horndis service install
horndis-status install
```

The second command copies the network daemon to `/Library/PrivilegedHelperTools` and starts its LaunchDaemon. The third command installs the optional per-user menu bar LaunchAgent and never needs administrator authorization.

Enable **USB tethering** in Android settings. The service will discover the RNDIS interfaces automatically while leaving a separate ADB interface available.

## Menu bar

The status item uses Apple SF Symbols and is deliberately compact by default:

- connected Android device name;
- received and transmitted bytes for the current USB session;
- current connection duration;
- a native USB Tethering switch at the right edge;
- Launch at Login;
- Show Details.

The detailed view adds the DHCP address, feth interface, device MAC, service process ID, last service detail, log access, project link, and copyable diagnostics.

Turning the **USB Tethering** switch off pauses the RNDIS bridge but keeps the background service available. Turning it on resumes discovery and connects when Android USB tethering is enabled. It cannot turn on Android's tethering setting remotely.

The menu bar app reads `/var/run/horndis/status.json` every two seconds. It does not inspect packet contents or send telemetry. The runtime directory, status file, and control socket are accessible only to the current console user and root. Connection requests go to `/var/run/horndis/control.sock` and also receive a peer-UID check.

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
sudo horndis service install
horndis-status install
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
