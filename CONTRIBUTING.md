# Contributing

Bug reports should include the macOS version, Mac architecture, Android model/version, `horndis probe`, the relevant section of `/var/log/horndis.log`, and the USB interface descriptors from `ioreg -r -c IOUSBHostInterface -l`.

Before opening a pull request:

```sh
make clean
make
make test
```

Keep USB protocol parsing independent from Objective-C frameworks where practical, include parser tests for malformed lengths and offsets, and do not add restricted Apple entitlements or kernel extensions.

CDC-NCM/ECM contributions should implement a transport boundary rather than add protocol-specific branches to the feth/BPF backend.
