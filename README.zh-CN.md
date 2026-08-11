# HoRNDIS Userspace

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

面向现代 macOS 的 Android USB 网络共享工具，无需受限 entitlement。它保持系统完整性保护（SIP）开启，并把完整的 RNDIS 数据路径移出内核。

[English user guide](docs/USER_GUIDE.md) · [中文使用手册](docs/USER_GUIDE.zh-CN.md) · [权限模型](docs/PRIVILEGE_MODEL.md) · [已知限制](docs/LIMITATIONS.md)

> **预览版本：** RNDIS 已在 Pixel 4 XL 上实现并测试。工具也能识别 CDC-ECM 和 CDC-NCM 设备，以便未来在保留 macOS 网络后端的情况下增加新的传输协议。

当前参考测试环境：运行 macOS 27.0 的 Apple 芯片 Mac，以及运行 Android 13 的 Pixel 4 XL；RNDIS 使用接口 0/1，ADB 保留接口 2。USB 初始化、DHCP、ARP、聚合 RNDIS 帧、ICMP 和双向 TCP 负载均由本地或设备测试覆盖。

## 安装

推荐安装方式会在本机从源代码构建，因此既不需要付费 Apple Developer 账户，也不依赖经过公证的下载：

```sh
brew install noahhhi/tap/horndis && horndis-install
```

Formula 同时包含网络服务和轻量的 SwiftUI/AppKit 菜单栏应用。Homebrew 本身不使用管理员权限；随后运行的 `horndis-install` 只请求一次管理员授权，安装固定的 root 服务、启动当前用户的菜单栏应用，并启用登录时启动。管理员凭据不会被保存。

也可以从 [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases) 下载通用 `.pkg` 并打开。安装包会通过一次 Installer 授权安装和启用两个组件。个人项目没有付费 Developer ID，无法对下载内容进行公证，因此 macOS 可能要求在“隐私与安全性”中明确选择“仍要打开”。Homebrew 源代码安装仍是首选方式。

在 Android 上开启 **USB 网络共享**，然后验证：

```sh
horndis probe
ifconfig feth99
curl https://ifconfig.me
```

没有连接手机时，LaunchDaemon 会等待；USB 热插拔或共享模式变化后会自动重新连接。服务日志位于 `/var/log/horndis.log`。

菜单栏默认以紧凑模式显示 Android 设备、当前会话上下行总流量、连接时长、持久授权状态、**USB 网络共享**开关和登录时启动开关。若特权服务尚未安装，会额外显示“**授权并安装…**”，点击后由标准 macOS 管理员认证对话框执行固定的内置安装命令。菜单打开时可见数据每秒刷新一次。展开使用系统动画的“**详细信息**”可查看 IP 地址、接口、设备 MAC、服务 PID、日志和可复制诊断信息。正常使用开关只与本地 Unix socket 通信，不再要求管理员密码。

卸载：

```sh
sudo horndis service uninstall
horndis-status uninstall
brew uninstall horndis
brew untap noahhhi/tap
```

GitHub Releases 也提供适合高级用户的通用手动 ZIP 包。

## 项目缘由

原版 [HoRNDIS](https://github.com/jwise/HoRNDIS) 使用内核扩展。当前 macOS 必须降低安全策略或关闭 SIP 才能载入旧式、未公证的内核代码。DriverKit 更安全，但分发 DriverKit/System Extension 网络驱动需要 Apple 单独批准的 entitlement，免费 Personal Team 无法获得。

HoRNDIS Userspace 使用 macOS 已内置的接口：

```text
Android RNDIS 控制端点与批量传输端点
                 ↕
          IOUSBHost.framework
                 ↕
           用户态 RNDIS 传输
                 ↕
          BPF ↔ feth 对等接口
                 ↕
      SystemConfiguration / DHCP 适配器
                 ↕
            macOS TCP/IP 栈

非特权数据代理
       ↕
只读状态 + 本地控制 socket
       ↕
SwiftUI/AppKit 菜单栏状态应用
```

- `IOUSBHost` 只占用 RNDIS 的控制接口和数据接口，ADB 继续使用独立的 USB 接口。
- 一对 `feth` 设备为 macOS 提供普通以太网接口，BPF 则与守护进程交换原始帧。
- 网络适配器会先尝试公开的 `SystemConfiguration`。当前 macOS 不会在那里暴露动态克隆的 feth 设备，因此工具会回退到系统 `ipconfig` DHCP 客户端，并在每次连接时重建这个临时服务。
- 不需要 kext、dext、受限 entitlement、恢复模式设置或关闭 SIP。
- 小型 root 监控进程仅执行 macOS 限定 root 完成的操作：创建和配置 feth、启动 DHCP、打开一个 BPF 描述符。然后它把已经打开的描述符作为能力传递给以当前控制台用户身份永久运行的非特权子进程。
- USB 发现、RNDIS 解析、数据包转发、运行状态和菜单控制都在非特权数据代理中完成，root 监控进程不会解析设备控制的数据。
- 可选菜单栏进程同样不带特权，并与数据路径隔离；退出菜单栏不会断开 USB 网络。

管理员授权只在安装或升级 root 所有的 LaunchDaemon 时需要。可以在终端运行 `horndis-install`，也可以点击菜单栏中的“**授权并安装…**”。每次开机时，特权设置只持续到网络能力创建完毕；重启、登录、睡眠唤醒、USB 重连和日常菜单操作都不再需要授权。详见[权限模型](docs/PRIVILEGE_MODEL.md)。

## 命令

```text
horndis-install               授权一次并安装/启动两个组件
horndis probe                 列出 RNDIS/CDC USB 网络功能
horndis usb-test              初始化 RNDIS，但不创建网络接口
sudo horndis run              在前台运行
sudo horndis service install  安装并启动 LaunchDaemon
sudo horndis service uninstall
horndis --version
horndis-status                运行菜单栏状态应用
horndis-status install        立即启动并在登录时启动（无需 sudo）
horndis-status uninstall      移除登录项
```

桥接默认使用 `feth99` 作为 macOS 端接口，使用 `feth98` 作为守护进程端接口。root 启动环境可以通过 `HORNDIS_HOST_INTERFACE` 和 `HORNDIS_TRANSPORT_INTERFACE` 覆盖它们；取值仅允许 `feth<number>` 格式。

## 构建

要求：macOS 11 或更高版本、Xcode Command Line Tools 或 Xcode，以及 GNU Make。macOS 11–14 和 Intel 构建属于尽力兼容目标；当前经过硬件验证的环境列在本文开头。

```sh
make
make test
./build/horndis probe
./build/horndis usb-test
sudo ./build/horndis run
```

使用较新 Xcode 构建通用二进制：

```sh
make clean
make ARCH_FLAGS="-arch arm64 -arch x86_64" STATUS_ARCHS="arm64 x86_64"
```

## 兼容性与长期设计

项目刻意分离四项职责：USB 发现、网络协议组帧、macOS 以太网后端和服务安装。RNDIS 组帧具有可移植的单元测试；USB 访问隔离在 `USBTransport.mm`，feth/BPF 后端隔离在 `VirtualEthernet.cpp`。

这项边界设计让未来的演进可以保持增量：

1. 增加 CDC-NCM 和 CDC-ECM 传输，同时保留相同的以太网后端。
2. 如果 Apple 将来移除 feth 克隆接口，增加 `utun` 三层后端；ARP/DHCP 适配仅存在于该后端。
3. 用 `utun` 后端或小型内置 DHCP 适配器替换当前 feth DHCP 兼容路径。
4. 如果未来 macOS 的 IOUSBHost 行为出现差异，增加可选 libusb 传输。

RNDIS 目前支持与 CDC 数据接口配对的 Android gadget 布局 `e0/01/03`、`02/02/ff` 和 `ef/04/01`，欢迎反馈其他 Android 厂商的设备情况。

## 故障排查

- `cannot claim ... interface`：停止占用接口 0/1 的其他 RNDIS 驱动或应用。接口 2 上的 ADB 可以共存。
- `feth99` 没有地址：关闭再开启 USB 网络共享，然后检查 `/var/log/horndis.log`。
- Homebrew 升级后，重新运行 `horndis-install`，一次更新特权辅助程序并刷新菜单 LaunchAgent。
- 测试手机路径时如需保持 Wi-Fi 活跃，可运行 `ping -b feth99 8.8.8.8` 绑定接口。
- Android VPN 应用通常不会通过原生 USB 网络共享转发其隧道。如果手机底层 Wi-Fi 在不使用 VPN 时无法访问某个目标，Mac 通常也无法通过共享访问该目标。
- 在已 root 的 Android 系统中，如果 DHCP 和 ICMP 正常但 TCP 停滞，请检查 `dumpsys tethering` 中的 conntrack/BPF 错误。诊断时可以运行 `device_config put connectivity override_tether_enable_bpf_offload false` 关闭 Android BPF offload；删除该属性即可恢复设备默认设置。

## 许可证

采用 GPL-3.0-or-later，与原版 HoRNDIS 一致。参见 `LICENSE`。
