# HoRNDIS Userspace

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

HoRNDIS 的 Android USB 网络共享数据路径运行在用户态而非内核态，因此可在现代 macOS 上运行，无需关闭系统完整性保护（SIP）。

[用户手册](docs/USER_GUIDE.zh-CN.md) · [反馈 Bug](docs/BUG_REPORTING.zh-CN.md) · [权限模型](docs/PRIVILEGE_MODEL.md) · [已知限制](docs/LIMITATIONS.md) · [菜单栏 UI 规范](docs/MENU_UI_GUIDELINES.md)

> **预览版本：** RNDIS 已在 Pixel 4 XL 上实现并测试。工具也能识别 CDC-ECM 和 CDC-NCM 设备，以便未来在保留 macOS 网络后端的情况下增加新的传输协议。

当前参考测试环境：运行 macOS 27.0 的 Apple 芯片 Mac，以及运行 Android 13 的 Pixel 4 XL；RNDIS 使用接口 0/1，ADB 保留接口 2。USB 初始化、DHCP、ARP、聚合 RNDIS 帧、ICMP 和双向 TCP 负载均由本地或设备测试覆盖。

## 安装

### Homebrew

```sh
brew install --cask noahhhi/tap/horndis
```

### PKG 安装包

1. 从 [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases) 下载通用 `.pkg` 安装包。
2. 先尝试打开下载的 `.pkg`。
3. 如果 macOS 阻止打开，进入“**系统设置 → 隐私与安全性**”。
4. 找到 HoRNDIS 安装包的提示，点击“**仍要打开**”。
5. 根据提示输入管理员密码，然后完成安装。

> [!IMPORTANT]
> 本项目目前使用免费 Apple Developer 账户，无法获得公开分发安装包所需的付费 Developer ID 证书，因此不能对安装包进行签名和公证。macOS 可能会阻止首次打开，需要按上述步骤点击“**仍要打开**”。此过程不需要关闭 SIP 或降低系统安全级别。

在 Android 上开启 **USB 网络共享**，然后验证：

```sh
horndis probe
horndis status
curl https://ifconfig.me
```

没有连接手机时，LaunchDaemon 会等待；USB 热插拔或共享模式变化后会自动重新连接。服务日志位于 `/var/log/horndis.log`。

原生菜单把顶部摘要压缩为三行：连接状态、Android 设备与连接时长、当前会话上下行流量。授权正常时不再长期占用一行，只有需要安装或修复时才显示警告。**USB 网络共享**和**登录时启动**只使用系统勾选，不再叠加第二个左侧图标；**详细信息**依靠系统子菜单箭头，退出项依靠快捷键。若特权服务尚未安装，会额外显示“**授权并安装…**”，点击后由标准 macOS 管理员认证对话框执行固定的内置安装命令。菜单打开时可见数据每秒刷新一次。系统原生“**详细信息**”侧边子菜单可查看 IP 地址、接口、设备 MAC、服务 PID、服务日志、不采集个人身份信息的诊断报告生成器及必须附日志的 Bug 反馈入口。正常勾选命令只与本地 Unix socket 通信，不再要求管理员密码。界面使用 AppKit `NSStatusItem`、`NSMenu`、`NSMenuItem.state`、原生子菜单、SF Symbols 和系统管理的几何及动态颜色；实现与视觉验收规则记录在[菜单栏 UI 规范](docs/MENU_UI_GUIDELINES.md)中。

菜单栏 App 通过标准 Bundle 本地化跟随 macOS 的系统语言或 App 单独语言设置，内置英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、巴西葡萄牙语、意大利语和俄语。在支持 App 单独语言设置的 macOS 版本中，可前往“**系统设置 → 通用 → 语言与地区 → 应用程序**”为 **HoRNDIS 状态栏**选择语言，然后重新打开 App。

流量行把最左侧 SF Symbol 直接作为上传箭头，标题从上传量开始并保留 `↓` 下载标记；这样会去掉重复的上传符号并让其余流量内容左移，不改变其他菜单行。

卸载：

```sh
horndis uninstall
brew uninstall --cask horndis
brew untap noahhhi/tap
```

GitHub Releases 也提供适合高级用户的通用手动 ZIP 包。

## 项目缘由

原版 [HoRNDIS](https://github.com/jwise/HoRNDIS) 使用内核扩展。当前 macOS 必须降低安全策略或关闭 SIP 才能载入旧式、未公证的内核代码。HoRNDIS Userspace 则把 RNDIS 数据路径放在内核之外的用户态运行，因此可在现代 macOS 上使用，无需降低启动安全性或关闭 SIP。

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
      AppKit 菜单栏状态应用
```

- `IOUSBHost` 只占用 RNDIS 的控制接口和数据接口，ADB 继续使用独立的 USB 接口。
- 一对 `feth` 设备为 macOS 提供普通以太网接口，BPF 则与守护进程交换原始帧。HoRNDIS 会独占创建一对未使用的接口，优先选择 `feth99`/`feth98`；如果任一名称已被其他应用占用，就继续向下扫描。
- 网络适配器会先尝试公开的 `SystemConfiguration`。当前 macOS 不会在那里暴露动态克隆的 feth 设备，因此工具会回退到系统 `ipconfig` DHCP 客户端，并在每次连接时重建这个临时服务。
- RNDIS 实现运行在用户态，而不是作为内核扩展运行，因此无需修改恢复模式设置或关闭 SIP。
- 小型 root 监控进程仅执行 macOS 限定 root 完成的操作：创建和配置 feth、启动 DHCP、打开一个 BPF 描述符。然后它把已经打开的描述符和一个固定的 DHCP 刷新请求通道传递给以当前控制台用户身份永久运行的非特权子进程；该通道不传输数据包或命令参数。
- USB 发现、RNDIS 解析、数据包转发、运行状态和菜单控制都在非特权数据代理中完成，root 监控进程不会解析设备控制的数据。
- 可选菜单栏进程同样不带特权，并与数据路径隔离；退出菜单栏不会断开 USB 网络。

管理员授权只在安装、升级或移除 root 所有的 LaunchDaemon 时需要。可以在终端运行 `horndis install`，也可以点击菜单栏中的“**授权并安装…**”。每次开机时，特权设置只持续到网络能力创建完毕；重启、登录、睡眠唤醒、USB 重连和日常菜单操作都不再需要授权。详见[权限模型](docs/PRIVILEGE_MODEL.md)。

## 命令

```text
horndis install               授权一次并安装/启动两个组件
horndis uninstall             移除两个持久组件
horndis start|stop|restart    仅控制菜单栏应用
horndis status                显示网络、连接和菜单状态
horndis diagnostics [文件]    创建不采集个人身份信息的诊断报告
horndis probe                 列出 RNDIS/CDC USB 网络功能
horndis usb-test              初始化 RNDIS，但不创建网络接口
sudo horndis run              在前台运行
sudo horndis service install  安装并启动 LaunchDaemon
sudo horndis service uninstall
horndis --version
horndis help [命令]
man horndis
```

桥接会自动选择两个尚不存在的 `feth<number>` 名称，优先使用 macOS 端 `feth99` 和守护进程端 `feth98`，随后尝试 `feth97`/`feth96`，依此类推。HoRNDIS 不会接管已有接口。root 启动环境仍可通过 `HORNDIS_HOST_INTERFACE` 和 `HORNDIS_TRANSPORT_INTERFACE` 成对覆盖；两个变量必须同时设置为不同且尚不存在的名称。`horndis status` 和菜单“详细信息”会显示实际选择的 macOS 端接口。

## 开发

要求：macOS 11 或更高版本、Xcode Command Line Tools 或 Xcode，以及 GNU Make。macOS 11–14 和 Intel 构建属于尽力兼容目标；当前经过硬件验证的环境列在本文开头。

普通用户通过 Homebrew 或 Release 安装时使用预先构建的通用 `.pkg`；以下命令仅用于从源码开发或测试项目。

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

提交 Bug 前，请先复现问题，然后使用“**HoRNDIS → 详细信息 → 保存诊断报告…**”或 `horndis diagnostics 文件` 生成新报告。GitHub Bug 表单强制上传 `.txt`、`.log` 或 `.zip` 报告，并已关闭外部空白 Issue。详见[反馈 Bug](docs/BUG_REPORTING.zh-CN.md)。

- `cannot claim ... interface`：停止占用接口 0/1 的其他 RNDIS 驱动或应用。接口 2 上的 ADB 可以共存。
- 菜单在显示设备后一直停在“正在配置 DHCP”：当前版本会在每次连接时自动启用实际选择的 feth 接口并重启 DHCP。旧版本可依次运行 `sudo ifconfig feth99 up` 和 `sudo ipconfig set feth99 DHCP`，在 Android 上关闭再打开 USB 网络共享，然后升级或重新安装 HoRNDIS 以获得永久修复。如果当前版本仍失败，请把 `horndis status` 输出的接口代入 `ipconfig getsummary <接口>`，并检查 `/var/log/horndis.log` 中明确的 DHCP 刷新错误。
- 其他应用已经占用 `feth98` 或 `feth99`：当前版本会自动跳过整对接口，并在状态/“详细信息”中显示实际选中的名称；HoRNDIS 不会重配或删除已有接口。
- Homebrew Cask 和 Release `.pkg` 会在安装包流程中更新特权辅助程序及菜单 LaunchAgent，不使用本地编译器。
- 测试手机路径时如需保持 Wi-Fi 活跃，可运行 `ping -b <接口> 8.8.8.8`，把 `<接口>` 替换为 `horndis status` 显示的名称。
- Android VPN 应用通常不会通过原生 USB 网络共享转发其隧道。如果手机底层 Wi-Fi 在不使用 VPN 时无法访问某个目标，Mac 通常也无法通过共享访问该目标。
- 在已 root 的 Android 系统中，如果 DHCP 和 ICMP 正常但 TCP 停滞，请检查 `dumpsys tethering` 中的 conntrack/BPF 错误。诊断时可以运行 `device_config put connectivity override_tether_enable_bpf_offload false` 关闭 Android BPF offload；删除该属性即可恢复设备默认设置。

## 许可证

采用 GPL-3.0-or-later，与原版 HoRNDIS 一致。参见 `LICENSE`。
