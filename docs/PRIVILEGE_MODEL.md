# Privilege Model

HoRNDIS uses one administrator-authorized installation and does not persist an administrator password. Reboot, login, USB hot-plug, Android tethering changes, pause/resume, and menu-bar startup do not request authorization again.

## Why any root component remains

On macOS, `/dev/bpf*` is `root:wheel` with mode `0600`, and only the super-user may create or modify network interfaces. HoRNDIS needs both operations to connect a user-space USB implementation to the macOS TCP/IP stack.

Changing BPF device permissions, adding a broad passwordless sudo rule, or installing a setuid executable would widen access more than a fixed LaunchDaemon and is intentionally avoided.

## Process boundary

```text
root LaunchDaemon supervisor
  ├─ create/configure feth98 ↔ feth99
  ├─ start system DHCP on feth99
  ├─ open and bind one BPF descriptor
  └─ fork + exec, pass only that descriptor
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

The child permanently drops supplementary groups, group ID, and user ID before `exec`. It cannot reopen BPF devices, reconfigure interfaces, modify the installed helper, or regain root. The root supervisor waits for and restarts the child but does not receive or parse USB-controlled bytes.

The runtime directory is assigned to the current console user after privileged setup with mode `0700`. Status and control endpoints use mode `0600`. The local control socket additionally validates the connecting peer against the current console user.

## Installation lifecycle

`horndis-install` delegates exactly one operation to `sudo horndis service install`; the GitHub Release package performs the same operation inside the administrator-authorized Installer process. That privileged step:

1. copy the exact executable to `/Library/PrivilegedHelperTools/io.github.noahhhi.horndis`;
2. set root ownership and non-writable executable permissions;
3. install the root-owned LaunchDaemon plist;
4. bootstrap the service.

The Homebrew command-line path's password is handled by `sudo`, while the package path uses macOS Installer authorization. The menu app provides a third entry point: it verifies that the helper and LaunchDaemon plist are root-owned, non-writable by ordinary users, and structurally valid; when they are not, **Authorize and Install…** asks the macOS Security Agent to run only the fixed bundled `horndis service install` command. HoRNDIS never reads or stores a credential in any path. The LaunchDaemon supplies persistence, so storing credentials in a script, Skill, Keychain lookup, environment variable, or sudoers exception is unnecessary. The menu LaunchAgent runs as the console user and needs no additional authorization.

## Remaining risk

The supervisor is still a root process and the feth/BPF backend depends on macOS behavior that Apple does not promise as a stable public ABI. Its input surface is deliberately small and fixed, but it is not equivalent to a formally sandboxed or Apple-entitled DriverKit component.

A future backend could replace BPF/feth with a suitable public unprivileged API if Apple provides one. The current source separates USB, RNDIS, Ethernet, service, control, and UI layers to keep that migration bounded.
