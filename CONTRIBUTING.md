# Contributing

Bug reports should include the macOS version, Mac architecture, Android model/version, `horndis probe`, the relevant section of `/var/log/horndis.log`, and the USB interface descriptors from `ioreg -r -c IOUSBHostInterface -l`.

Before opening a pull request:

```sh
make clean
make
make test
```

Keep USB protocol parsing independent from Objective-C frameworks where practical, include parser tests for malformed lengths and offsets, and do not add restricted Apple entitlements or kernel extensions.

Keep the Swift/AppKit status process optional and unprivileged. It must not become part of the packet data path, and menu actions must not introduce recurring administrator prompts. Use system frameworks and SF Symbols instead of third-party UI dependencies.

CDC-NCM/ECM contributions should implement a transport boundary rather than add protocol-specific branches to the feth/BPF backend.
