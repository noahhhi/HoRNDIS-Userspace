# Known Limitations

## Platform and distribution

- macOS 11 is the minimum deployment target. The current end-to-end reference machine is Apple Silicon on macOS 27; older macOS and Intel builds are produced and compile-checked but cannot all be hardware-tested for every release.
- Homebrew builds native binaries for the installing Mac. GitHub release archives contain universal arm64/x86_64 binaries.
- This personal project is not notarized. Homebrew source installation is preferred. It does not require a paid developer account on the user's Mac.

## USB protocols and devices

- RNDIS is implemented. CDC-ECM and CDC-NCM functions are detected but their data backends are not implemented yet.
- Android gadget layouts `e0/01/03`, `02/02/ff`, and `ef/04/01` paired with a CDC data interface are recognized. Vendor-specific layouts may need a descriptor report and code update.
- The RNDIS interfaces are claimed exclusively. ADB remains available only when Android exposes it as a separate USB interface.

## macOS networking

- `feth99` is dynamic and does not appear in the macOS Network settings panel. It remains visible to `ifconfig`, `scutil --nwi`, DHCP, and the menu bar app.
- A minimal root supervisor remains resident because BPF access and system DHCP/interface configuration are privileged. It does not process USB or RNDIS data; the inherited-BPF data agent runs as the current console user.
- The feth/BPF backend is not a promised long-term Apple ABI. The code keeps this backend isolated so a future utun or other public backend can replace it.
- VPN route priority, fake-IP DNS, endpoint security products, and other network extensions can change which path a normal application uses. Interface-bound tests are required to prove the USB path independently.

## Android tethering

- The phone controls upstream selection and NAT. Android VPNs do not necessarily share their tunnel through native USB tethering.
- Some rooted or modified Android builds have broken tethering BPF/conntrack offload. If DHCP and ICMP work while TCP stalls, temporarily disabling Android tether offload can distinguish that device problem from the macOS bridge. Restore the property after diagnosis if the device works with its default.
- The menu bar USB Tethering switch resumes or pauses HoRNDIS discovery; it cannot enable Android USB tethering or unlock the phone.

## Menu bar status

- Details use a native submenu rather than in-place expansion because Apple does not support resizing a custom menu-item view during menu tracking. This preserves the system's open/close animation and highlight behavior; see [Views in Menu Items](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MenuList/Articles/ViewsInMenuItems.html).
- Traffic totals are Ethernet frame bytes for the current connection, not carrier-billing counters. They reset after disconnect, service restart, or a new USB session.
- Status refreshes every two seconds, so very short state transitions may not be visible.
- The status file contains the device product name, RNDIS MAC, interface name, counters, and daemon PID. It is local, restricted to the current console user and root, and never uploaded by this project.
- Quitting or crashing the menu bar process does not stop tethering. Conversely, the status UI cannot repair a stopped or uninstalled privileged service without the normal one-time administrator-authorized installation.
