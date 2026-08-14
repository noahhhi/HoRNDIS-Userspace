# Contributing

Bug reports must follow the [bug-reporting workflow](docs/BUG_REPORTING.md). Reproduce the problem, create a fresh report with **HoRNDIS → Details → Save Diagnostic Report…** or `horndis diagnostics FILE`, review it, and attach it to the required upload field in the GitHub bug form. Blank external issues are disabled. A screenshot or raw `/var/log/horndis.log` alone is not sufficient.

Before opening a pull request:

```sh
make clean
make
make test
```

Keep USB protocol parsing independent from Objective-C frameworks where practical, include parser tests for malformed lengths and offsets, and do not add restricted Apple entitlements or kernel extensions.

Keep the Swift/AppKit status process optional and unprivileged. It must not become part of the packet data path, and menu actions must not introduce recurring administrator prompts. Use system frameworks and SF Symbols instead of third-party UI dependencies.

CDC-NCM/ECM contributions should implement a transport boundary rather than add protocol-specific branches to the feth/BPF backend.
