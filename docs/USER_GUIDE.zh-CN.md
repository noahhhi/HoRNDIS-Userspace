# HoRNDIS Userspace 中文使用手册

## 系统要求

- macOS 11 或更高版本；构建及发布流程同时支持 Apple Silicon 与 Intel。
- Android 设备能够提供 RNDIS USB 控制和数据接口。
- 支持数据传输的 USB 线缆。
- 安装或升级后台网络服务时进行一次管理员认证。

不需要付费 Apple Developer 账户、DriverKit 特殊权限、降低启动安全性或关闭 SIP。

## 安装

```sh
brew install noahhhi/tap/horndis && horndis-install
```

Homebrew Formula 会同时安装网络程序和菜单栏 App。`horndis-install` 只请求一次管理员认证，把网络服务复制到 `/Library/PrivilegedHelperTools`、启动 LaunchDaemon，并为当前用户安装菜单栏 LaunchAgent。密码只由 macOS `sudo` 处理，程序不会保存密码。

GitHub Releases 中的通用 `.pkg` 是另一种一体化安装方式；双击后只需一次 Installer 管理员认证即可安装并启动两部分。由于免费开发者账户无法提供 Developer ID 公证，macOS 可能要求在“隐私与安全性”中明确选择“仍要打开”；因此仍优先推荐 Homebrew 源码安装。

在 Android 设置中打开 **USB 网络共享**。服务会自动发现 RNDIS 接口；如果手机还提供独立的 ADB 接口，ADB 可以同时使用。

## 菜单栏

菜单默认保持精简，并使用 Apple SF Symbols 显示：

- 当前 Android 设备名称；
- 本次连接累计接收和发送流量；
- 连接时长；
- 持久管理员授权状态；
- 最右侧的“USB 网络共享”滑块；
- 登录时启动滑块；
- 使用系统动画的“详细信息”展开项。

展开“详细信息”后，可以在同一面板中查看 DHCP 地址、feth 接口、设备 MAC、服务 PID、后台状态、日志入口、项目主页及可复制的诊断信息。

状态栏使用 macOS 原生模板图标，菜单使用动态系统颜色；两者会自动跟随浅色或深色外观，即使菜单栏外观与 App 外观不同也能保持正确对比度。

在 macOS 13 及以上版本中，HoRNDIS 使用 SwiftUI 原生窗口样式的 `MenuBarExtra`。系统负责把面板与状态栏图标对齐，并在不让 HoRNDIS 抢占前台焦点的情况下，以用户选择的系统强调色绘制原生滑块。“详细信息”使用原生 `DisclosureGroup`；macOS 14 及以上使用 Apple 预设的平滑弹簧动画。macOS 11 和 12 使用等价的 `NSPopover` 后备实现。

“授权状态：已授权”表示 root 所有的网络 helper 及其 LaunchDaemon 配置已经安全安装。如果文件缺失、所有者错误、可被非 root 用户写入或配置无效，菜单会显示“授权状态：需要授权”，并在其正下方增加“授权并安装…”。点击后由 macOS 标准管理员认证对话框执行 App 内置且固定的 `horndis service install` 命令；HoRNDIS 不会接触或保存密码。命令行仍可使用 `horndis-install` 完成同一操作。

关闭 **USB 网络共享** 滑块只会暂停 RNDIS 桥接，后台服务仍保持运行；打开滑块会恢复设备扫描。菜单栏不能代替用户在 Android 上打开 USB 网络共享。

面板关闭时每两秒读取一次 `/var/run/horndis/status.json`，面板显示期间则每秒刷新一次；打开面板时只原位更新现有文字和原生开关，不会反复重建界面。程序不会读取网络数据内容，也没有遥测。运行目录、状态文件和控制 socket 只允许当前控制台用户及 root 访问；连接控制通过 `/var/run/horndis/control.sock` 完成，并额外校验请求方 UID。

## 为什么系统“网络”设置中看不到

`feth99` 是运行时动态创建的以太网接口。新版 macOS 不会把它加入持久的 Network Service 列表，所以系统设置不显示它，但系统网络栈和 DHCP 都能正常使用。

可以用以下命令或菜单栏确认状态：

```sh
ifconfig feth99
scutil --nwi
ipconfig getsummary feth99
tail -f /var/log/horndis.log
```

## 升级

```sh
brew update
brew upgrade horndis
horndis-install
```

只有重新安装后台网络服务需要管理员认证。开机启动、USB 重连和菜单栏操作都不会再次询问密码。常驻 root 进程只是最小监督器，USB 与 RNDIS 数据处理在当前登录用户权限下运行，详见[权限模型](PRIVILEGE_MODEL.md)。

## 卸载

```sh
horndis-status uninstall
sudo horndis service uninstall
brew uninstall horndis
```

## 网络测试与 VPN

Mac 同时保留 Wi-Fi 或 VPN 时，可把测试绑定到 USB 接口：

```sh
ping -b feth99 8.8.8.8
```

部分 VPN/代理使用 Fake-IP DNS，系统解析得到的地址可能只能通过对应的 VPN 隧道访问。绑定 `feth99` 后访问该虚拟地址失败，不代表 USB 驱动异常；排障时应对比系统 DNS 与 Android DHCP 提供的 DNS 结果。

提交兼容性问题前请先阅读[已知限制](LIMITATIONS.md)。
