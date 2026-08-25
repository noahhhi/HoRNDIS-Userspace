# Known Limitations

## Platform and distribution

- macOS 11 is the minimum deployment target. The current end-to-end reference machine is Apple Silicon on macOS 27; older macOS and Intel builds are produced and compile-checked but cannot all be hardware-tested for every release.
- Homebrew installs the prebuilt universal `.pkg` through a Cask; the Cask itself does not compile on the target Mac and can be installed without developer tools. Homebrew still lists Xcode Command Line Tools or Xcode as a requirement for a fully supported Homebrew installation. The release `.pkg` has no such requirement.
- GitHub Releases contain a universal arm64/x86_64 ZIP and the same unified `.pkg` used by the Cask. This personal project cannot sign and notarize the package without a paid Developer ID.

## USB protocols and devices

- RNDIS is implemented. CDC-ECM and CDC-NCM functions are detected but their data backends are not implemented yet.
- Android gadget layouts `e0/01/03`, `02/02/ff`, and `ef/04/01` paired with a CDC data interface are recognized. Vendor-specific layouts may need a descriptor report and code update.
- The RNDIS interfaces are claimed exclusively. ADB remains available only when Android exposes it as a separate USB interface.

## macOS networking

- The selected `feth<number>` interface is dynamic and does not appear in the macOS Network settings panel. It remains visible to `ifconfig`, `scutil --nwi`, DHCP, and the menu bar app. HoRNDIS prefers `feth99`/`feth98` but automatically chooses another unused pair when either name is already occupied.
- A minimal root supervisor remains resident because BPF access and system DHCP/interface configuration are privileged. It does not process USB or RNDIS data; the inherited-BPF data agent runs as the current console user and can only request the fixed per-session DHCP refresh over a private channel.
- The feth/BPF backend is not a promised long-term Apple ABI. The code keeps this backend isolated so a future utun or other public backend can replace it.
- VPN route priority, fake-IP DNS, endpoint security products, and other network extensions can change which path a normal application uses. Interface-bound tests are required to prove the USB path independently. A global TUN VPN can also intercept traffic explicitly bound to the feth interface before it reaches the bridge; exclude the tether subnet in the VPN client if the Mac must reach phone-side addresses directly.
- A VPN transition or other network reordering can remove the feth interface's IPv4 address while the bridge keeps forwarding. HoRNDIS detects this during a connected session and automatically requests a fresh DHCP lease after a short grace period.

## Android tethering

- The phone controls upstream selection and NAT. Android VPNs do not necessarily share their tunnel through native USB tethering.
- Some rooted or modified Android builds have broken tethering BPF/conntrack offload. If DHCP and ICMP work while TCP stalls, temporarily disabling Android tether offload can distinguish that device problem from the macOS bridge. Restore the property after diagnosis if the device works with its default.
- The checked USB Tethering menu command resumes or pauses HoRNDIS discovery; it cannot enable Android USB tethering or unlock the phone.

## Menu bar status

- The status UI is a standard AppKit pull-down `NSMenu` on every supported macOS version. USB Tethering and Launch at Login are checked menu commands rather than draggable switches, and Details opens a native side submenu rather than expanding in place. AppKit owns the menu geometry and animation. See [MENU_UI_GUIDELINES.md](MENU_UI_GUIDELINES.md) for the full framework contract.
- The root summary uses three native information rows. A valid authorization state is intentionally omitted; the authorization warning and install action appear only when repair is required. The traffic row uses its leading image as the upload arrow and begins its title with the transmitted total; other summary rows retain their semantic images.
- The menu bar app includes English, Simplified Chinese, Traditional Chinese, Japanese, Korean, French, German, Spanish, Brazilian Portuguese, Italian, and Russian bundle localizations. Other system languages use the English development language.
- Traffic totals are Ethernet frame bytes for the current connection, not carrier-billing counters. They reset after disconnect, service restart, or a new USB session.
- Status refreshes every two seconds while the menu is closed and every second while it is visible, so very short transitions can still be missed.
- The status file contains the device product name, RNDIS MAC, interface name, counters, and daemon PID. It is local, restricted to the current console user and root, and never uploaded by this project.
- Diagnostic reports are generated locally and are never uploaded automatically. Account/full names, host/device names, USB serial values and location IDs, MAC/IP addresses, hardware serial numbers, hardware UUIDs, packet contents, and credentials are not collected into the report. Users are labeled `user`; devices receive stable first-seen `device N` aliases across reconnects for the lifetime of the unprivileged data process. The in-memory alias map is not persisted or sent to root, so numbering restarts with that process. Older service-log lines are sanitized during copying; service events and errors remain for diagnosis, so users must still review the file before attaching it to a public issue.
- Quitting or crashing the menu bar process does not stop tethering. Reopen it from `/Applications` or run `horndis start`. A missing or invalid privileged installation can be repaired with the menu's one-time **Authorize and Install…** action or `horndis install`; both still require normal macOS administrator authentication.
