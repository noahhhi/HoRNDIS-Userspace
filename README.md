# HoRNDIS Userspace

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

HoRNDIS runs the Android USB tethering data path in user space rather than the kernel, so it works on modern macOS without disabling System Integrity Protection (SIP).

[User guide](docs/USER_GUIDE.md) · [Report a bug](docs/BUG_REPORTING.md) · [Privilege model](docs/PRIVILEGE_MODEL.md) · [Known limitations](docs/LIMITATIONS.md) · [Menu UI contract](docs/MENU_UI_GUIDELINES.md)

> **Preview:** RNDIS is implemented and tested with a Pixel 4 XL. CDC-ECM and CDC-NCM devices are detected so future transports can be added without replacing the macOS network backend.

Current reference test: Apple Silicon Mac running macOS 27.0, Pixel 4 XL running Android 13, RNDIS interfaces 0/1 alongside ADB interface 2. USB initialization, DHCP, ARP, aggregated RNDIS frames, ICMP, and bidirectional TCP payloads are covered by local or device tests.

## Install

### Homebrew

```sh
brew install --cask noahhhi/tap/horndis
```

### Package installer

1. Download the universal `.pkg` from [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases).
2. Try to open the downloaded `.pkg`.
3. If macOS blocks it, open **System Settings → Privacy & Security**.
4. Click **Open Anyway** for the HoRNDIS package.
5. Enter an administrator password when prompted, then complete the installation.

> [!IMPORTANT]
> This project currently uses a free Apple Developer account, which cannot provide the paid Developer ID certificate required to sign and notarize the installer for public distribution. macOS may therefore block the first launch until you approve it with **Open Anyway**. You do not need to disable SIP or reduce system security.

Enable **USB tethering** on Android, then verify:

```sh
horndis probe
horndis status
curl https://ifconfig.me
```

The launch daemon waits when no phone is connected and reconnects automatically after USB hot-plug or tethering mode changes. Its log is `/var/log/horndis.log`.

The native menu shows the Android device, session RX/TX totals, connection duration, persistent authorization state, **USB Tethering**, and login-start switches. If the privileged service is missing, an **Authorize and Install…** row invokes the standard macOS administrator authentication dialog for the fixed bundled installer command. Visible values refresh every second. Expand **Details** for the IP address, interface, device MAC, service PID, service log, a privacy-preserving diagnostic-report generator, and the required-log bug-report flow. Normal switches talk only to a local Unix socket and never ask for an administrator password. The UI uses a native window-style `MenuBarExtra`, mini switches, disclosure animation, SF Symbols, dynamic colors, and shared row geometry; its implementation and visual acceptance rules are documented in the [menu UI contract](docs/MENU_UI_GUIDELINES.md).

To remove it:

```sh
horndis uninstall
brew uninstall --cask horndis
brew untap noahhhi/tap
```

Universal manual ZIP archives are also attached to GitHub Releases for advanced use.

## Why this exists

The original [HoRNDIS](https://github.com/jwise/HoRNDIS) is a kernel extension. Current macOS releases require reduced security or disabled SIP to load legacy, unnotarized kernel code. HoRNDIS Userspace instead keeps the RNDIS data path outside the kernel, so it can run on modern macOS without reducing boot security or disabling SIP.

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
- A paired `feth` device gives macOS a normal Ethernet interface while BPF exchanges raw frames with the daemon. HoRNDIS exclusively creates an unused pair, preferring `feth99`/`feth98` and scanning downward if another application already owns either name.
- The network adapter first uses public `SystemConfiguration`. Current macOS does not expose dynamically cloned feth devices there, so it falls back to the system `ipconfig` DHCP client and recreates that temporary service on every connection.
- The RNDIS implementation runs in user space rather than as a kernel extension, so no recovery-mode change or SIP change is required.
- A small root supervisor performs only the operations macOS reserves for root: create/configure feth, start DHCP, and open one BPF descriptor. It passes that already-open descriptor plus a fixed DHCP-refresh request channel to a permanently unprivileged child running as the current console user; the channel carries no packet data or command arguments.
- USB discovery, RNDIS parsing, packet forwarding, runtime status, and menu control all execute in that unprivileged data agent. The root supervisor does not parse device-controlled traffic.
- The optional menu bar process is also unprivileged and isolated from the data path. Quitting it cannot disconnect the USB network.

Administrator authorization is required only to install, upgrade, or remove the root-owned LaunchDaemon. It can be requested with `horndis install` in a terminal or from **Authorize and Install…** in the menu bar. At each boot the privileged setup lasts only long enough to create the network capability; reboot, login, sleep/wake, USB reconnect, and normal menu use require no further authorization. See the [privilege model](docs/PRIVILEGE_MODEL.md).

## Commands

```text
horndis install               authorize once and install/start both components
horndis uninstall             remove both persistent components
horndis start|stop|restart    control only the menu bar app
horndis status                show network, connection, and menu status
horndis diagnostics [FILE]    create a privacy-preserving diagnostic report
horndis probe                 list RNDIS/CDC USB networking functions
horndis usb-test              initialize RNDIS without creating a network interface
sudo horndis run              run in the foreground
sudo horndis service install  install and start the launch daemon
sudo horndis service uninstall
horndis --version
horndis help [command]
man horndis
```

The bridge automatically selects two absent `feth<number>` names, preferring `feth99` for macOS and `feth98` for the daemon, then `feth97`/`feth96`, and so on. It never adopts an existing interface. Root launch environments can override the pair with `HORNDIS_HOST_INTERFACE` and `HORNDIS_TRANSPORT_INTERFACE`; both variables must be set together to distinct names that do not already exist. `horndis status` and menu Details show the selected macOS-facing interface.

## Development

Requirements: macOS 11 or later, Xcode Command Line Tools or Xcode, and GNU Make. macOS 11–14 and Intel builds are best-effort compatibility targets; the current hardware validation is listed at the top of this document.

End-user Homebrew and Release installations use the prebuilt universal `.pkg`; the following commands are only for developing or testing the project from source.

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

Before opening a bug, reproduce it and create a fresh report with **HoRNDIS → Details → Save Diagnostic Report…** or `horndis diagnostics FILE`. The GitHub bug form requires that report as a `.txt`, `.log`, or `.zip` upload, and blank external issues are disabled. See [Reporting a bug](docs/BUG_REPORTING.md).

- `cannot claim ... interface`: stop another RNDIS driver or application that owns interfaces 0/1. ADB on interface 2 is compatible.
- Menu stuck at **Configuring DHCP** after the device appears: current builds automatically raise the selected feth interface and restart DHCP on every connection. With an older build, run `sudo ifconfig feth99 up` followed by `sudo ipconfig set feth99 DHCP`, toggle Android USB tethering off/on, then upgrade or reinstall HoRNDIS for the permanent fix. If a current build still fails, use the interface printed by `horndis status` with `ipconfig getsummary <interface>` and inspect `/var/log/horndis.log` for the explicit DHCP-refresh error.
- Another application already uses `feth98` or `feth99`: current builds skip the occupied pair automatically and report the selected interface in status/Details. HoRNDIS never reconfigures or removes the pre-existing interfaces.
- The Homebrew Cask and release `.pkg` update the privileged helper and menu LaunchAgent as part of package installation; no local compiler is used.
- To keep Wi-Fi active while testing the phone path, bind the socket with `ping -b <interface> 8.8.8.8`, replacing `<interface>` with the value printed by `horndis status`.
- Android VPN apps normally do not share their tunnel through native USB tethering. If the phone's underlying Wi-Fi cannot access a destination without its VPN, that destination will also be unavailable to the Mac.
- On rooted Android builds where DHCP and ICMP work but TCP stalls, inspect `dumpsys tethering` for conntrack/BPF errors. The Android BPF offload can be disabled for diagnosis with `device_config put connectivity override_tether_enable_bpf_offload false`; delete that property to restore the device default.

## License

GPL-3.0-or-later, matching the original HoRNDIS project. See `LICENSE`.
