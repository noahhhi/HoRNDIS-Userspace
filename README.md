# HoRNDIS Userspace

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

Entitlement-free Android USB tethering for modern macOS. It keeps System Integrity Protection enabled and moves the entire RNDIS data path out of the kernel.

[English user guide](docs/USER_GUIDE.md) · [中文使用手册](docs/USER_GUIDE.zh-CN.md) · [Privilege model](docs/PRIVILEGE_MODEL.md) · [Known limitations](docs/LIMITATIONS.md)

> **Preview:** RNDIS is implemented and tested with a Pixel 4 XL. CDC-ECM and CDC-NCM devices are detected so future transports can be added without replacing the macOS network backend.

Current reference test: Apple Silicon Mac running macOS 27.0, Pixel 4 XL running Android 13, RNDIS interfaces 0/1 alongside ADB interface 2. USB initialization, DHCP, ARP, aggregated RNDIS frames, ICMP, and bidirectional TCP payloads are covered by local or device tests.

## Install

The recommended Homebrew installation downloads the prebuilt universal package; it does not compile on the target Mac and does not require Xcode or Command Line Tools:

```sh
brew install --cask noahhhi/tap/horndis
```

The Cask uses the same universal `.pkg` as GitHub Releases. One standard Installer authorization places **HoRNDIS Status.app** in `/Applications`, installs the CLI and manual pages, activates the fixed root service, starts the per-user menu app, and enables it at login. It never stores the administrator credential. If the menu app is quit, reopen it from Applications, Launchpad, or Spotlight, or run `horndis start`.

The HoRNDIS Cask itself can be installed without developer tools because it only downloads a prebuilt package. Homebrew still lists Xcode Command Line Tools or Xcode as a requirement for a fully supported Homebrew installation; use the release `.pkg` directly when Homebrew is not already installed.

Alternatively, download the identical universal `.pkg` from [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases) and open it. Neither installation path compiles locally. This personal project cannot notarize downloads without a paid Developer ID, so macOS may require an explicit **Open Anyway** confirmation in Privacy & Security.

Enable **USB tethering** on Android, then verify:

```sh
horndis probe
ifconfig feth99
curl https://ifconfig.me
```

The launch daemon waits when no phone is connected and reconnects automatically after USB hot-plug or tethering mode changes. Its log is `/var/log/horndis.log`.

The native menu shows the Android device, session RX/TX totals, connection duration, persistent authorization state, **USB Tethering**, and login-start switches. If the privileged service is missing, an **Authorize and Install…** row invokes the standard macOS administrator authentication dialog for the fixed bundled installer command. Visible values refresh every second. Open the native **Details** submenu for the IP address, interface, device MAC, service PID, log, and copyable diagnostics. Normal switches talk only to a local Unix socket and never ask for an administrator password.

To remove it:

```sh
horndis uninstall
brew uninstall --cask horndis
brew untap noahhhi/tap
```

Universal manual ZIP archives are also attached to GitHub Releases for advanced use.

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
      AppKit menu bar status
```

- `IOUSBHost` claims only the RNDIS control and data interfaces. ADB stays on its separate USB interface.
- A paired `feth` device gives macOS a normal Ethernet interface while BPF exchanges raw frames with the daemon.
- The network adapter first uses public `SystemConfiguration`. Current macOS does not expose dynamically cloned feth devices there, so it falls back to the system `ipconfig` DHCP client and recreates that temporary service on every connection.
- No kext, dext, restricted entitlement, recovery-mode change, or SIP change is required.
- A small root supervisor performs only the operations macOS reserves for root: create/configure feth, start DHCP, and open one BPF descriptor. It passes that already-open descriptor as a capability to a permanently unprivileged child running as the current console user.
- USB discovery, RNDIS parsing, packet forwarding, runtime status, and menu control all execute in that unprivileged data agent. The root supervisor does not parse device-controlled traffic.
- The optional menu bar process is also unprivileged and isolated from the data path. Quitting it cannot disconnect the USB network.

Administrator authorization is required only to install, upgrade, or remove the root-owned LaunchDaemon. It can be requested with `horndis install` in a terminal or from **Authorize and Install…** in the menu bar. At each boot the privileged setup lasts only long enough to create the network capability; reboot, login, sleep/wake, USB reconnect, and normal menu use require no further authorization. See the [privilege model](docs/PRIVILEGE_MODEL.md).

## Commands

```text
horndis install               authorize once and install/start both components
horndis uninstall             remove both persistent components
horndis start|stop|restart    control only the menu bar app
horndis status                show network, connection, and menu status
horndis probe                 list RNDIS/CDC USB networking functions
horndis usb-test              initialize RNDIS without creating a network interface
sudo horndis run              run in the foreground
sudo horndis service install  install and start the launch daemon
sudo horndis service uninstall
horndis --version
horndis help [command]
man horndis
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
- The Homebrew Cask and release `.pkg` update the privileged helper and menu LaunchAgent as part of package installation; no local compiler is used.
- To keep Wi-Fi active while testing the phone path, bind the socket with `ping -b feth99 8.8.8.8`.
- Android VPN apps normally do not share their tunnel through native USB tethering. If the phone's underlying Wi-Fi cannot access a destination without its VPN, that destination will also be unavailable to the Mac.
- On rooted Android builds where DHCP and ICMP work but TCP stalls, inspect `dumpsys tethering` for conntrack/BPF errors. The Android BPF offload can be disabled for diagnosis with `device_config put connectivity override_tether_enable_bpf_offload false`; delete that property to restore the device default.

## License

GPL-3.0-or-later, matching the original HoRNDIS project. See `LICENSE`.
