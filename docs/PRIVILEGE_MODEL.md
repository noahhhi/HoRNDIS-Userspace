# Privilege Model

HoRNDIS uses one administrator-authorized installation and does not persist an administrator password. Reboot, login, USB hot-plug, Android tethering changes, pause/resume, and menu-bar startup do not request authorization again.

## Why any root component remains

On macOS, `/dev/bpf*` is `root:wheel` with mode `0600`, and only the super-user may create or modify network interfaces. HoRNDIS needs both operations to connect a user-space USB implementation to the macOS TCP/IP stack.

Changing BPF device permissions, adding a broad passwordless sudo rule, or installing a setuid executable would widen access more than a fixed LaunchDaemon and is intentionally avoided.

## Process boundary

```text
root LaunchDaemon supervisor
  ├─ select and exclusively create an unused feth pair
  ├─ start system DHCP on the selected macOS-facing feth
  ├─ open and bind one BPF descriptor
  └─ fork + exec, pass that descriptor and a fixed DHCP-refresh channel
                    │
                    ▼
console-user data agent
  ├─ IOUSBHost discovery and interface ownership
  ├─ RNDIS initialization and parsing
  ├─ Ethernet frame forwarding through inherited BPF
  ├─ atomic runtime status
  └─ authenticated local pause/resume control

console-user Swift menu bar
  └─ read status and request pause/resume
```

The child permanently drops supplementary groups, group ID, and user ID before `exec`. It cannot reopen BPF devices, reconfigure interfaces, modify the installed helper, or regain root. After each successful RNDIS initialization, it sends one fixed `refresh DHCP` request and waits for a one-byte success/failure response before reporting the session as connected. The request carries no interface name, command arguments, packet content, or other device-controlled data. The root supervisor validates the fixed request, raises both prevalidated feth interfaces, restarts the macOS DHCP client, and then blocks on the channel again. It never receives or parses USB-controlled bytes.

This per-session handshake prevents a boot-order race in which macOS networking clears the temporary DHCP state after the LaunchDaemon's initial setup but before an Android device connects. If the privileged refresh fails, the data agent publishes an error and retries instead of leaving the menu indefinitely at **Configuring DHCP**.

Automatic selection prefers `feth99`/`feth98`, then scans downward in odd/even pairs. A pair is eligible only when both names are absent. HoRNDIS never adopts, reconfigures, or destroys an interface that already existed; it removes only the pair created by the current supervisor. Explicit environment overrides remain available but must name two absent, distinct `feth<number>` interfaces.

The runtime directory is assigned to the current console user after privileged setup with mode `0700`. Status and control endpoints use mode `0600`. The local control socket additionally validates the connecting peer against the current console user.

## Installation lifecycle

`horndis install` delegates exactly one operation to `sudo horndis service install`; the Homebrew Cask and GitHub Release package perform the same operation inside the administrator-authorized Installer process. That privileged step:

1. ensure `/Library/PrivilegedHelperTools` exists as `root:wheel` with the
   standard `01755` permissions, creating it when absent;
2. copy the exact executable to `/Library/PrivilegedHelperTools/io.github.noahhhi.horndis`;
3. set root ownership and non-writable executable permissions;
4. install the root-owned LaunchDaemon plist;
5. bootstrap the service.

The Homebrew command-line path's password is handled by `sudo`, while the package path uses macOS Installer authorization. The menu app provides a third entry point: it verifies that the helper and LaunchDaemon plist are root-owned, non-writable by ordinary users, and structurally valid; when they are not, **Authorize and Install…** asks the macOS Security Agent to run only the fixed bundled `horndis service install` command. HoRNDIS never reads or stores a credential in any path. The LaunchDaemon supplies persistence, so storing credentials in a script, Skill, Keychain lookup, environment variable, or sudoers exception is unnecessary. The menu LaunchAgent runs as the console user and needs no additional authorization.

## Remaining risk

The supervisor is still a root process and the feth/BPF backend depends on macOS behavior that Apple does not promise as a stable public ABI. Its input surface is deliberately small and fixed, but it is not equivalent to a formally sandboxed or Apple-entitled DriverKit component.

A future backend could replace BPF/feth with a suitable public unprivileged API if Apple provides one. The current source separates USB, RNDIS, Ethernet, service, control, and UI layers to keep that migration bounded.
