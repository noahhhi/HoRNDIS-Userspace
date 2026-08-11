# HoRNDIS Userspace 中文使用手册

## 系统要求

- macOS 11 或更高版本；构建及发布流程同时支持 Apple Silicon 与 Intel。
- Android 设备能够提供 RNDIS USB 控制和数据接口。
- 支持数据传输的 USB 线缆。
- 安装或升级后台网络服务时进行一次管理员认证。

不需要付费 Apple Developer 账户、DriverKit 特殊权限、降低启动安全性或关闭 SIP。

## 安装

```sh
brew install noahhhi/tap/horndis
sudo horndis service install
horndis-status install
```

第二条命令把网络服务安装到 `/Library/PrivilegedHelperTools` 并启动 LaunchDaemon。第三条命令安装可选的当前用户菜单栏 LaunchAgent，不使用 `sudo`。

在 Android 设置中打开 **USB 网络共享**。服务会自动发现 RNDIS 接口；如果手机还提供独立的 ADB 接口，ADB 可以同时使用。

## 菜单栏

菜单默认保持精简，并使用 Apple SF Symbols 显示：

- 当前 Android 设备名称；
- 本次连接累计接收和发送流量；
- 连接时长；
- 最右侧的“USB 网络共享”滑块；
- 登录时启动滑块；
- 使用系统动画的“详细信息”子菜单。

打开“详细信息”子菜单后可以查看 DHCP 地址、feth 接口、设备 MAC、服务 PID、后台状态、日志入口、项目主页及可复制的诊断信息。

关闭 **USB 网络共享** 滑块只会暂停 RNDIS 桥接，后台服务仍保持运行；打开滑块会恢复设备扫描。菜单栏不能代替用户在 Android 上打开 USB 网络共享。

菜单关闭时每两秒读取一次 `/var/run/horndis/status.json`，菜单显示期间则每秒刷新一次；打开菜单时只原位更新现有文字和原生开关，不会反复重建菜单。程序不会读取网络数据内容，也没有遥测。运行目录、状态文件和控制 socket 只允许当前控制台用户及 root 访问；连接控制通过 `/var/run/horndis/control.sock` 完成，并额外校验请求方 UID。

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
sudo horndis service install
horndis-status install
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
