# 反馈 Bug

有效的 HoRNDIS Bug 反馈必须包含问题发生在同一次会话中的证据。请不要逐条手动收集命令输出，也不要只附截图。

## 生成诊断报告

1. 连接 Android 设备，开启 USB 网络共享，并复现问题。
2. 立即打开“**HoRNDIS → 详细信息 → 保存诊断报告…**”。也可以运行：

   ```sh
   horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
   ```

3. 分享前检查生成的文本文件。

此过程不需要管理员认证，也不会自动上传任何内容。诊断报告包括：

- HoRNDIS 与 macOS 版本、Mac 型号、CPU 架构和 SIP 状态；
- 不含身份信息的运行字段、LaunchDaemon 状态，以及安装文件和运行时文件的所有者与权限；
- USB 协议、VID/PID、接口配对及支持状态；只对匿名 USB 功能编号，不包含设备身份；
- 实际选择的 feth 接口、链路标志、MTU，以及是否已配置 IPv4/IPv6，但不包含地址值；
- 是否安装了可能冲突的旧版 HoRNDIS 内核扩展；
- 最近最多 1,000 行、最大 512 KiB 的后台服务日志。

报告不会采集账户名、用户全名、主机名/设备名、USB 序列号与位置 ID、MAC/IP 地址、硬件序列号、硬件 UUID、网络数据包内容或凭据。用户统一写成 `user`；检测到的设备按 `device 1`、`device 2` 依次编号。非特权数据进程只在内存中保存别名映射，因此同一次服务运行期间，同一台设备断线重连后仍使用相同编号；映射不会落盘，也不会发送给 root 监督器，数据进程重启后会重新编号。旧版本已经写入的服务日志行会在复制时先清理。定位问题所需的服务事件与错误文本会保留，提交前仍请检查文件。

## 提交 GitHub Issue

打开[新建 Bug 报告](https://github.com/noahhhi/HoRNDIS-Userspace/issues/new?template=bug_report.yml)，或选择“**HoRNDIS → 详细信息 → 报告 Bug…**”；后者会先生成新报告，再打开同一个表单。

请说明实际现象、预期结果和准确复现步骤。GitHub 表单中的文件上传为必填项，只接受 `.txt`、`.log` 或 `.zip`；请附上刚生成的 `HoRNDIS-Diagnostics-*.txt`。仓库已关闭外部空白 Issue。截图或单独的 `/var/log/horndis.log` 不能代替诊断报告，因为它们不包含 USB 描述符、DHCP 状态、文件权限和服务状态。

每个不同的问题都应在复现后重新生成报告。请勿使用故障发生前或其他 Mac/手机会话中生成的旧报告。
