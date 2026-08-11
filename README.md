# HoRNDIS Userspace

Entitlement-free Android USB tethering for modern macOS. It keeps System Integrity Protection enabled and moves the entire RNDIS data path out of the kernel.

> **Preview:** RNDIS is implemented and tested with a Pixel 4 XL. CDC-ECM and CDC-NCM devices are detected so future transports can be added without replacing the macOS network backend.

Current reference test: Apple Silicon Mac running macOS 27.0, Pixel 4 XL running Android 13, RNDIS interfaces 0/1 alongside ADB interface 2. USB initialization, DHCP, ARP, aggregated RNDIS frames, ICMP, and bidirectional TCP payloads are covered by local or device tests.

## Install

The recommended installation builds locally from source, so it needs neither a paid Apple Developer account nor a notarized download:

```sh
brew install noahhhi/tap/horndis
sudo horndis service install
```

Enable **USB tethering** on Android, then verify:

```sh
horndis probe
ifconfig feth99
curl https://ifconfig.me
```

The launch daemon waits when no phone is connected and reconnects automatically after USB hot-plug or tethering mode changes. Its log is `/var/log/horndis.log`.

To remove it:

```sh
sudo horndis service uninstall
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
```

- `IOUSBHost` claims only the RNDIS control and data interfaces. ADB stays on its separate USB interface.
- A paired `feth` device gives macOS a normal Ethernet interface while BPF exchanges raw frames with the daemon.
- The network adapter first uses public `SystemConfiguration`. Current macOS does not expose dynamically cloned feth devices there, so it falls back to the system `ipconfig` DHCP client and recreates that temporary service on every connection.
- No kext, dext, restricted entitlement, recovery-mode change, or SIP change is required.

The daemon runs as root because macOS restricts BPF devices and system network configuration. The USB and RNDIS parsing code still runs in a normal user-space process; a malformed device cannot execute code in the kernel through this project.

## Commands

```text
horndis probe                 list RNDIS/CDC USB networking functions
horndis usb-test              initialize RNDIS without creating a network interface
sudo horndis run              run in the foreground
sudo horndis service install  install and start the launch daemon
sudo horndis service uninstall
horndis --version
```

The bridge defaults to `feth99` for macOS and `feth98` for the daemon. Root launch environments can override them with `HORNDIS_HOST_INTERFACE` and `HORNDIS_TRANSPORT_INTERFACE`; values are restricted to `feth<number>` names.

## Build

Requirements: macOS 12 or later, Xcode Command Line Tools or Xcode, and GNU Make.

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
make ARCH_FLAGS="-arch arm64 -arch x86_64"
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
- To keep Wi-Fi active while testing the phone path, bind the socket with `ping -b feth99 8.8.8.8`.
- Android VPN apps normally do not share their tunnel through native USB tethering. If the phone's underlying Wi-Fi cannot access a destination without its VPN, that destination will also be unavailable to the Mac.
- On rooted Android builds where DHCP and ICMP work but TCP stalls, inspect `dumpsys tethering` for conntrack/BPF errors. The Android BPF offload can be disabled for diagnosis with `device_config put connectivity override_tether_enable_bpf_offload false`; delete that property to restore the device default.

## License

GPL-3.0-or-later, matching the original HoRNDIS project. See `LICENSE`.
