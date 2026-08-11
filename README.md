# HoRNDIS Userspace

Entitlement-free Android USB tethering for modern macOS. It keeps System Integrity Protection enabled and moves the entire RNDIS data path out of the kernel.

[English user guide](docs/USER_GUIDE.md) · [中文使用手册](docs/USER_GUIDE.zh-CN.md) · [Privilege model](docs/PRIVILEGE_MODEL.md) · [Known limitations](docs/LIMITATIONS.md)

> **Preview:** RNDIS is implemented and tested with a Pixel 4 XL. CDC-ECM and CDC-NCM devices are detected so future transports can be added without replacing the macOS network backend.

Current reference test: Apple Silicon Mac running macOS 27.0, Pixel 4 XL running Android 13, RNDIS interfaces 0/1 alongside ADB interface 2. USB initialization, DHCP, ARP, aggregated RNDIS frames, ICMP, and bidirectional TCP payloads are covered by local or device tests.

## Install

The recommended installation builds locally from source, so it needs neither a paid Apple Developer account nor a notarized download:

```sh
brew install noahhhi/tap/horndis
sudo horndis service install
horndis-status install
```

The last command starts the optional lightweight Swift/AppKit menu bar status app and enables it at login. It does not use `sudo`. The Homebrew formula builds and installs native code for the current Mac; release downloads contain both Apple Silicon and Intel slices.

Enable **USB tethering** on Android, then verify:

```sh
horndis probe
ifconfig feth99
curl https://ifconfig.me
```

The launch daemon waits when no phone is connected and reconnects automatically after USB hot-plug or tethering mode changes. Its log is `/var/log/horndis.log`.

The menu bar starts in a compact view showing the Android device, session RX/TX totals, connection duration, **USB Tethering**, and login-start switches. Visible values refresh every second. Open the system-animated **Details** submenu for the IP address, interface, device MAC, service PID, log, and copyable diagnostics. The switch talks only to a local Unix socket and never asks for an administrator password.

To remove it:

```sh
sudo horndis service uninstall
horndis-status uninstall
brew uninstall horndis
brew untap noahhhi/tap
```

Universal command-line builds are also attached to [GitHub releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases). Homebrew source builds are preferred because this personal project cannot currently provide Apple notarization.

## Why this exists

The original [HoRNDIS](https://github.com/jwise/HoRNDIS) is a kernel extension. Current macOS releases require reduced security or disabled SIP to load legacy, unnotarized kernel code. DriverKit is safer, but distributing a DriverKit/System Extension network driver requires Apple-granted entitlements that are unavailable to a free Personal Team.

HoRNDIS Userspace uses APIs already shipped by macOS:

```text
Android RNDIS control + bulk endpoints
             ↕
        IOUSBHost.framework
             ↕
     user-space RNDIS transport
             ↕
       BPF ↔ feth peer pair
             ↕
 SystemConfiguration / DHCP adapter
             ↕
       macOS TCP/IP stack

unprivileged data agent
             ↕
  read-only status + local control socket
             ↕
     Swift/AppKit menu bar status
```

- `IOUSBHost` claims only the RNDIS control and data interfaces. ADB stays on its separate USB interface.
- A paired `feth` device gives macOS a normal Ethernet interface while BPF exchanges raw frames with the daemon.
- The network adapter first uses public `SystemConfiguration`. Current macOS does not expose dynamically cloned feth devices there, so it falls back to the system `ipconfig` DHCP client and recreates that temporary service on every connection.
- No kext, dext, restricted entitlement, recovery-mode change, or SIP change is required.
- A small root supervisor performs only the operations macOS reserves for root: create/configure feth, start DHCP, and open one BPF descriptor. It passes that already-open descriptor as a capability to a permanently unprivileged child running as the current console user.
- USB discovery, RNDIS parsing, packet forwarding, runtime status, and menu control all execute in that unprivileged data agent. The root supervisor does not parse device-controlled traffic.
- The optional menu bar process is also unprivileged and isolated from the data path. Quitting it cannot disconnect the USB network.

Administrator authorization is required only to install or upgrade the root-owned LaunchDaemon. At each boot the privileged setup lasts only long enough to create the network capability; reboot, login, sleep/wake, USB reconnect, and menu use require no further authorization. See the [privilege model](docs/PRIVILEGE_MODEL.md).

## Commands

```text
horndis probe                 list RNDIS/CDC USB networking functions
horndis usb-test              initialize RNDIS without creating a network interface
sudo horndis run              run in the foreground
sudo horndis service install  install and start the launch daemon
sudo horndis service uninstall
horndis --version
horndis-status                 run the menu bar status app
horndis-status install         start now and at login (no root required)
horndis-status uninstall       remove the login item
```

The bridge defaults to `feth99` for macOS and `feth98` for the daemon. Root launch environments can override them with `HORNDIS_HOST_INTERFACE` and `HORNDIS_TRANSPORT_INTERFACE`; values are restricted to `feth<number>` names.

## Build

Requirements: macOS 11 or later, Xcode Command Line Tools or Xcode, and GNU Make. macOS 11–14 and Intel builds are best-effort compatibility targets; the current hardware validation is listed at the top of this document.

```sh
make
make test
./build/horndis probe
./build/horndis usb-test
sudo ./build/horndis run
```

To build a universal release binary with a recent Xcode:

```sh
make clean
make ARCH_FLAGS="-arch arm64 -arch x86_64" STATUS_ARCHS="arm64 x86_64"
```

## Compatibility and long-term design

The project deliberately separates four concerns: USB discovery, network protocol framing, the macOS Ethernet backend, and service installation. RNDIS framing has portable unit tests; USB access is isolated in `USBTransport.mm`; the feth/BPF backend is isolated in `VirtualEthernet.cpp`.

That boundary makes the likely future paths incremental:

1. Add CDC-NCM and CDC-ECM transports while retaining the same Ethernet backend.
2. Add a `utun` layer-3 backend if Apple ever removes the feth cloner; ARP/DHCP adaptation would live only in that backend.
3. Replace the current feth DHCP compatibility path with the `utun` backend or a small built-in DHCP adapter.
4. Add an optional libusb transport if IOUSBHost behavior diverges on a future macOS release.

RNDIS currently supports Android gadget layouts `e0/01/03`, `02/02/ff`, and `ef/04/01`, paired with a CDC data interface. Reports for other Android vendors are welcome.

## Troubleshooting

- `cannot claim ... interface`: stop another RNDIS driver or application that owns interfaces 0/1. ADB on interface 2 is compatible.
- No address on `feth99`: turn USB tethering off and on, then inspect `/var/log/horndis.log`.
- Service changes after an upgrade: rerun `sudo horndis service install` to copy the new binary into the privileged helper location.
- Menu bar changes after an upgrade: rerun `horndis-status install`; this is unprivileged and refreshes its LaunchAgent path.
- To keep Wi-Fi active while testing the phone path, bind the socket with `ping -b feth99 8.8.8.8`.
- Android VPN apps normally do not share their tunnel through native USB tethering. If the phone's underlying Wi-Fi cannot access a destination without its VPN, that destination will also be unavailable to the Mac.
- On rooted Android builds where DHCP and ICMP work but TCP stalls, inspect `dumpsys tethering` for conntrack/BPF errors. The Android BPF offload can be disabled for diagnosis with `device_config put connectivity override_tether_enable_bpf_offload false`; delete that property to restore the device default.

## License

GPL-3.0-or-later, matching the original HoRNDIS project. See `LICENSE`.
