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

`sudo horndis service install` performs the only privileged installation step:

1. copy the exact executable to `/Library/PrivilegedHelperTools/io.github.noahhhi.horndis`;
2. set root ownership and non-writable executable permissions;
3. install the root-owned LaunchDaemon plist;
4. bootstrap the service.

The password is handled by `sudo`; HoRNDIS never reads or stores it. The LaunchDaemon supplies persistence, so storing credentials in a script, Skill, Keychain lookup, environment variable, or sudoers exception is unnecessary.

## Remaining risk

The supervisor is still a root process and the feth/BPF backend depends on macOS behavior that Apple does not promise as a stable public ABI. Its input surface is deliberately small and fixed, but it is not equivalent to a formally sandboxed or Apple-entitled DriverKit component.

A future backend could replace BPF/feth with a suitable public unprivileged API if Apple provides one. The current source separates USB, RNDIS, Ethernet, service, control, and UI layers to keep that migration bounded.
