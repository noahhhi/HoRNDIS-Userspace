# HoRNDIS Userspace 中文使用手册

## 系统要求

- macOS 11 或更高版本，支持 Apple 芯片与 Intel Mac。
- Android 设备能够提供 RNDIS USB 控制和数据接口。
- 支持数据传输的 USB 线缆。
- 安装或升级后台网络服务时进行一次管理员认证。

HoRNDIS 运行在用户态，而不是作为内核扩展运行，因此用户无需降低启动安全性或关闭 SIP。

## 安装

```sh
brew install --cask noahhhi/tap/horndis
```

或直接安装 PKG：

1. 从 [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases) 下载通用 `.pkg` 安装包。
2. 先尝试打开下载的 `.pkg`。
3. 如果 macOS 阻止打开，进入“**系统设置 → 隐私与安全性**”。
4. 找到 HoRNDIS 安装包的提示，点击“**仍要打开**”。
5. 根据提示输入管理员密码，然后完成安装。

> [!IMPORTANT]
> 本项目目前使用免费 Apple Developer 账户，无法获得公开分发安装包所需的付费 Developer ID 证书，因此不能对安装包进行签名和公证。macOS 可能会阻止首次打开，需要按上述步骤点击“**仍要打开**”。此过程不需要关闭 SIP 或降低系统安全级别。

如果系统缺少 `/Library/PrivilegedHelperTools`，安装程序会先按标准的 root
所有权和权限重新创建该目录，再安装 helper；用户无需手动准备目录。

在 Android 设置中打开 **USB 网络共享**。服务会自动发现 RNDIS 接口；如果手机还提供独立的 ADB 接口，ADB 可以同时使用。

## 菜单栏

App 使用 macOS 标准 Bundle 本地化，并跟随系统语言或 App 单独语言设置。内置英语、简体中文、繁体中文、日语、韩语、法语、德语、西班牙语、巴西葡萄牙语、意大利语和俄语。可前往“**系统设置 → 通用 → 语言与地区 → 应用程序**”为 HoRNDIS 状态栏选择语言，然后重新打开 App。

菜单默认保持精简，并使用 Apple SF Symbols 显示：

- 连接状态；
- 合并在同一行的 Android 设备名称与连接时长；
- 本次连接累计发送和接收流量；
- 仅在需要安装或修复时显示的管理员授权状态；
- 带勾选状态的“USB 网络共享”菜单项；
- 带勾选状态的“登录时启动”菜单项；
- 从侧边打开系统子菜单的“详细信息”菜单项。

打开“详细信息”后，系统会在侧边展开原生子菜单，显示 DHCP 地址、feth 接口、设备 MAC、服务 PID、后台状态和服务日志，并可保存诊断报告或进入引导式 Bug 反馈流程。

状态栏使用 macOS 原生模板图标，菜单使用动态系统颜色；两者会自动跟随浅色或深色外观，即使菜单栏外观与 App 外观不同也能保持正确对比度。

从 macOS 11 起的所有受支持系统统一使用 AppKit 原生 `NSStatusItem`、`NSMenu` 和 `NSMenuItem`。菜单外框、材质、阴影、间距、选区强调色、勾选状态、键盘操作、辅助功能、深浅色外观以及“详细信息”子菜单动画均由系统负责。HoRNDIS 不会自行绘制或裁剪替代菜单，菜单打开时也不会抢占前台应用焦点。

授权有效时，精简摘要不会显示授权行。如果 root 所有的网络 helper 或 LaunchDaemon 配置缺失、所有者错误、可被非 root 用户写入或配置无效，菜单会用盾牌显示“授权状态：需要授权”，并在其正下方增加不重复该图标的纯文字“授权并安装…”操作。点击后由 macOS 标准管理员认证对话框执行 App 内置且固定的 `horndis service install` 命令；HoRNDIS 不会接触或保存密码。命令行可以使用 `horndis install` 完成同一操作。

两个勾选命令只依靠 AppKit 系统勾选，不叠加第二个左侧图标；“详细信息”依靠原生子菜单箭头，退出项依靠 `⌘Q` 快捷键。根菜单摘要的 SF Symbols 使用 AppKit 的关闭状态图片槽，因此会与下方系统勾选对齐，同时信息行仍保持非勾选语义，也不会再创建独立图片列。“详细信息”子菜单在自己的独立菜单中继续使用普通语义图标。流量行的首个符号直接作为上传箭头，标题从上传量开始并保留后面的 `↓` 下载标记。

取消勾选 **USB 网络共享** 只会暂停 RNDIS 桥接，后台服务仍保持运行；再次选择该菜单项会恢复勾选状态和设备扫描。菜单栏不能代替用户在 Android 上打开 USB 网络共享。

设备连接期间，HoRNDIS 还会监测桥接接口的 IPv4 地址。如果 macOS 移除了该地址——例如 VPN 连接或断开后重排网络配置——HoRNDIS 会在大约十五秒内自动重新获取 DHCP 地址，无需手动重启。

菜单关闭时每两秒读取一次 `/var/run/horndis/status.json`，菜单显示期间则每秒刷新一次；打开菜单时只原位更新现有菜单项文字、可用状态、勾选状态和子菜单内容，不会反复重建菜单。程序不会读取网络数据内容，也没有遥测。运行目录、状态文件和控制 socket 只允许当前控制台用户及 root 访问；连接控制通过 `/var/run/horndis/control.sock` 完成，并额外校验请求方 UID。

## 为什么系统“网络”设置中看不到

HoRNDIS 会在运行时动态创建一对 `feth<number>` 接口。它优先使用 `feth99`/`feth98`；如果任一名称已经存在，就自动跳过整对并继续向下选择，绝不会接管或删除其他应用的接口。新版 macOS 不会把动态接口加入持久的 Network Service 列表，所以系统设置不显示它，但系统网络栈和 DHCP 都能正常使用。

可以用以下命令或菜单栏确认状态：

```sh
horndis status
horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
scutil --nwi
tail -f /var/log/horndis.log
```

`horndis status` 和菜单“详细信息”会显示实际选择的 macOS 端接口；请把这个名称用于 `ifconfig` 或 `ipconfig getsummary`。

如果已经退出菜单栏 App，可以从“应用程序”、Launchpad 或 Spotlight 重新打开，
也可以运行 `horndis start`。`horndis stop` 会关闭菜单栏但保留登录时启动设置，
`horndis restart` 可用于排障后重启。完整命令请运行 `horndis help` 或
`man horndis`。

## 一直停在“正在配置 DHCP”

当前版本会在每次 USB/RNDIS 成功连接后重新启用实际选择的 macOS 端 feth 接口，并重启 DHCP 客户端。这同时覆盖开机、登录、睡眠、换线以及 Android 网络共享状态变化后的重连，不需要再次进行管理员认证。

如果旧版安装在显示设备名称后仍一直停在“正在配置 DHCP”，通常是 macOS 在手机连接前清除了开机时创建的一次性 DHCP 状态。可以用以下命令恢复当前会话：

```sh
sudo ifconfig feth99 up
sudo ipconfig set feth99 DHCP
```

然后在 Android 上关闭并重新打开 USB 网络共享。升级或重新安装 HoRNDIS 后，会自动在每次连接时完成这个修复。如果当前版本仍无法获得地址，请把 `horndis status` 显示的接口代入 `ipconfig getsummary <接口>`，并检查 `/var/log/horndis.log`；如果特权 DHCP 刷新失败，菜单应显示明确错误，而不是无限停留在配置状态。

## 升级

```sh
brew update
brew upgrade --cask horndis
```

只有重新安装后台网络服务需要管理员认证。开机启动、USB 重连和菜单栏操作都不会再次询问密码。常驻 root 进程只是最小监督器，USB 与 RNDIS 数据处理在当前登录用户权限下运行，详见[权限模型](PRIVILEGE_MODEL.md)。

## 卸载

```sh
horndis uninstall
brew uninstall --cask horndis
```

## 网络测试与 VPN

Mac 同时保留 Wi-Fi 或 VPN 时，可把测试绑定到 USB 接口：

```sh
ping -b <接口> 8.8.8.8
```

请把 `<接口>` 替换为 `horndis status` 显示的名称。

部分 VPN/代理使用 Fake-IP DNS，系统解析得到的地址可能只能通过对应的 VPN 隧道访问。绑定所选 feth 接口后访问该虚拟地址失败，不代表 USB 驱动异常；排障时应对比系统 DNS 与 Android DHCP 提供的 DNS 结果。

提交 Bug 时，请先复现问题，随后立即从菜单“详细信息”保存新诊断报告，或运行 `horndis diagnostics 文件`。检查文件后，把它上传到 GitHub Bug 表单中的必填附件栏。完整流程与隐私说明请参阅[反馈 Bug](BUG_REPORTING.zh-CN.md)；提交兼容性问题前也请先阅读[已知限制](LIMITATIONS.md)。
