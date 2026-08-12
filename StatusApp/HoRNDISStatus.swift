// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation

private let horndisStatusVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "development"
private let statusPath = "/var/run/horndis/status.json"
private let controlPath = "/var/run/horndis/control.sock"
private let launchAgentLabel = "io.github.noahhhi.horndis.status"
private let privilegedHelperPath = "/Library/PrivilegedHelperTools/io.github.noahhhi.horndis"
private let launchDaemonPath = "/Library/LaunchDaemons/io.github.noahhhi.horndis.plist"
private let launchDaemonLabel = "io.github.noahhhi.horndis"
private let projectURL = URL(string: "https://github.com/noahhhi/HoRNDIS-Userspace")!

private func localized(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

private enum ServiceAuthorizationState: Equatable {
    case granted
    case required

    var title: String {
        switch self {
        case .granted:
            return localized("Authorization: Granted", "授权状态：已授权")
        case .required:
            return localized("Authorization: Required", "授权状态：需要授权")
        }
    }

    var symbol: String {
        switch self {
        case .granted:
            return "checkmark.shield"
        case .required:
            return "exclamationmark.shield"
        }
    }
}

private enum ServiceAuthorizationManager {
    static var state: ServiceAuthorizationState {
        guard secureRegularFile(at: privilegedHelperPath, mustBeExecutable: true),
              secureRegularFile(at: launchDaemonPath, mustBeExecutable: false),
              launchDaemonConfigurationIsValid() else {
            return .required
        }
        return .granted
    }

    private static func secureRegularFile(at path: String,
                                          mustBeExecutable: Bool) -> Bool {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0,
              information.st_uid == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              (information.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return !mustBeExecutable || (information.st_mode & S_IXUSR) != 0
    }

    private static func launchDaemonConfigurationIsValid() -> Bool {
        guard let data = FileManager.default.contents(atPath: launchDaemonPath),
              let object = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil),
              let configuration = object as? [String: Any],
              configuration["Label"] as? String == launchDaemonLabel,
              let arguments = configuration["ProgramArguments"] as? [String],
              arguments.first == privilegedHelperPath else {
            return false
        }
        return true
    }

    private static func sourceToolURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }
        let tool = resources.appendingPathComponent("horndis").standardizedFileURL
        var information = stat()
        if Darwin.lstat(tool.path, &information) == 0,
           (information.st_mode & S_IFMT) == S_IFREG,
           (information.st_mode & S_IXUSR) != 0,
           (information.st_mode & (S_IWGRP | S_IWOTH)) == 0 {
            return tool
        }
        return nil
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func requestInstallation() throws {
        guard let toolURL = sourceToolURL() else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(ENOENT),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("The bundled HoRNDIS network tool is missing or unsafe",
                                        "内置的 HoRNDIS 网络工具缺失或权限不安全")])
        }

        let source = """
        set networkTool to "\(appleScriptLiteral(toolURL.path))"
        do shell script (quoted form of networkTool & " service install") with administrator privileges
        """
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(EINVAL),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("Cannot prepare the administrator authorization request",
                                        "无法准备管理员授权请求")])
        }

        var errorInformation: NSDictionary?
        _ = script.executeAndReturnError(&errorInformation)
        if let errorInformation {
            let number = errorInformation[NSAppleScript.errorNumber] as? Int
            let fallback = errorInformation[NSAppleScript.errorMessage] as? String
            let message = number == -128
                ? localized("Administrator authorization was cancelled", "管理员授权已取消")
                : fallback ?? localized("Administrator authorization failed", "管理员授权失败")
            throw NSError(domain: "HoRNDISStatus",
                          code: number ?? Int(EPERM),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private struct RuntimeStatus: Decodable {
    let schemaVersion: Int
    let state: String
    let device: String
    let deviceAddress: String
    let hostInterface: String
    let detail: String
    let receivedBytes: UInt64
    let transmittedBytes: UInt64
    let connectedSince: UInt64
    let controlAvailable: Bool?
    let updatedAt: UInt64
    let processID: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case state
        case device
        case deviceAddress = "device_address"
        case hostInterface = "host_interface"
        case detail
        case receivedBytes = "received_bytes"
        case transmittedBytes = "transmitted_bytes"
        case connectedSince = "connected_since"
        case controlAvailable = "control_available"
        case updatedAt = "updated_at"
        case processID = "process_id"
    }
}

private enum DisplayState: Equatable {
    case connected
    case connecting
    case waiting
    case paused
    case error
    case stopped
    case unavailable
}

private struct Snapshot {
    let runtime: RuntimeStatus?
    let state: DisplayState
    let ipAddress: String?
    let message: String
}

private func ipv4Address(for interfaceName: String) -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        return nil
    }
    defer { freeifaddrs(interfaces) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        let record = current.pointee
        if String(cString: record.ifa_name) == interfaceName,
           let address = record.ifa_addr,
           address.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(address,
                                     socklen_t(address.pointee.sa_len),
                                     &host,
                                     socklen_t(host.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            if result == 0 {
                return String(cString: host)
            }
        }
        cursor = record.ifa_next
    }
    return nil
}

private func readSnapshot() -> Snapshot {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let runtime = try? JSONDecoder().decode(RuntimeStatus.self, from: data) else {
        let address = ipv4Address(for: "feth99")
        if address != nil {
            return Snapshot(runtime: nil,
                            state: .connected,
                            ipAddress: address,
                            message: localized("Connected (legacy status)", "已连接（旧版状态）"))
        }
        return Snapshot(runtime: nil,
                        state: .unavailable,
                        ipAddress: nil,
                        message: localized("Service status unavailable", "无法读取服务状态"))
    }

    let interface = runtime.hostInterface.isEmpty ? "feth99" : runtime.hostInterface
    let address = ipv4Address(for: interface)
    let age = Date().timeIntervalSince1970 - Double(runtime.updatedAt)
    if age > 10 {
        return Snapshot(runtime: runtime,
                        state: .unavailable,
                        ipAddress: address,
                        message: localized("Service status is stale", "服务状态已过期"))
    }

    let displayState: DisplayState
    let message: String
    switch runtime.state {
    case "connected":
        displayState = .connected
        message = address == nil
            ? localized("Configuring DHCP", "正在配置 DHCP")
            : localized("USB tethering connected", "USB 网络共享已连接")
    case "connecting":
        displayState = .connecting
        message = localized("Connecting", "正在连接")
    case "waiting":
        displayState = .waiting
        message = localized("Waiting for USB tethering", "等待 USB 网络共享")
    case "paused":
        displayState = .paused
        message = localized("Connection paused", "连接已暂停")
    case "error":
        displayState = .error
        message = localized("Service error", "服务错误")
    case "stopped":
        displayState = .stopped
        message = localized("Service stopped", "服务已停止")
    default:
        displayState = .unavailable
        message = localized("Unknown service state", "未知服务状态")
    }
    return Snapshot(runtime: runtime, state: displayState, ipAddress: address, message: message)
}

private enum LaunchAgentManager {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func executablePath() -> String {
        let argument = CommandLine.arguments[0]
        let absoluteURL: URL
        if argument.hasPrefix("/") {
            absoluteURL = URL(fileURLWithPath: argument)
        } else {
            absoluteURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argument)
        }
        // Preserve the installed application path instead of resolving bundle aliases.
        return absoluteURL.standardizedFileURL.path
    }

    static func writeConfiguration() throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        let configuration: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func removeConfiguration() throws {
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String],
                             allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              "launchctl exited with status \(process.terminationStatus)"])
        }
        return process.terminationStatus
    }

    static var isLoaded: Bool {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        return (try? runLaunchctl(["print", target], allowFailure: true)) == 0
    }

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "io.github.noahhhi.horndis.status"
        ).contains { $0.processIdentifier != getpid() }
    }

    static func openOnce() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                              "open exited with status \(process.terminationStatus)"])
        }
    }

    static func start() throws {
        guard isInstalled else {
            try openOnce()
            return
        }
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        if !isLoaded {
            try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }
        try runLaunchctl(["kickstart", target])
    }

    static func stop() throws {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: "io.github.noahhhi.horndis.status"
        ) where application.processIdentifier != getpid() {
            application.terminate()
        }
    }

    static func restart() throws {
        try stop()
        try start()
    }

    static func installAndStart() throws {
        try writeConfiguration()
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        try runLaunchctl(["kickstart", "-k", target])
    }

    static func uninstall() throws {
        let target = "gui/\(getuid())/\(launchAgentLabel)"
        try runLaunchctl(["bootout", target], allowFailure: true)
        try removeConfiguration()
    }
}

private enum ControlClient {
    static func send(_ command: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create the control socket"])
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(controlPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(ENAMETOOLONG),
                          userInfo: [NSLocalizedDescriptionKey: "Control socket path is too long"])
        }
        controlPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: pathCapacity) {
                    _ = strlcpy($0, source, pathCapacity)
                }
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor,
                               socketAddress,
                               socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("Cannot contact the HoRNDIS service", "无法连接 HoRNDIS 服务")])
        }
        let bytes = Array(command.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            throw NSError(domain: "HoRNDISStatus",
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                              localized("Cannot send the connection request", "无法发送连接请求")])
        }
    }
}

private enum NativeMenuMetrics {
    static let width: CGFloat = 274
    static let rowHeight: CGFloat = 24
    static let horizontalInset: CGFloat = 12
    static let iconSize: CGFloat = 16
    static let labelX: CGFloat = 38
}

@MainActor
private final class NativeMenuSwitchRow: NSView {
    let toggle = NSSwitch()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField

    init(title: String,
         image: NSImage?,
         state: NSControl.StateValue,
         isEnabled: Bool,
         target: AnyObject,
         action: Selector) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0,
                                 y: 0,
                                 width: NativeMenuMetrics.width,
                                 height: NativeMenuMetrics.rowHeight))

        iconView.image = image
        iconView.contentTintColor = isEnabled ? .labelColor : .disabledControlTextColor
        iconView.frame = NSRect(x: NativeMenuMetrics.horizontalInset,
                                y: floor((NativeMenuMetrics.rowHeight -
                                    NativeMenuMetrics.iconSize) / 2),
                                width: NativeMenuMetrics.iconSize,
                                height: NativeMenuMetrics.iconSize)
        addSubview(iconView)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: NativeMenuMetrics.labelX,
                                  y: 0,
                                  width: 170,
                                  height: NativeMenuMetrics.rowHeight)
        titleLabel.alignment = .left
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        toggle.controlSize = .mini
        toggle.state = state
        toggle.isEnabled = isEnabled
        toggle.target = target
        toggle.action = action
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(
            x: NativeMenuMetrics.width - NativeMenuMetrics.horizontalInset - toggle.frame.width,
            y: floor((NativeMenuMetrics.rowHeight - toggle.frame.height) / 2)
        )
        toggle.autoresizingMask = [.minXMargin]
        addSubview(toggle)

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(state: NSControl.StateValue, isEnabled: Bool) {
        if toggle.state != state {
            toggle.state = state
        }
        toggle.isEnabled = isEnabled
        iconView.contentTintColor = isEnabled ? .labelColor : .disabledControlTextColor
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggle.isEnabled && bounds.contains(point) && !toggle.frame.contains(point) {
            toggle.performClick(self)
        }
    }
}

private enum NativeMenuTag: Int {
    case status = 100
    case device
    case traffic
    case duration
    case authorization
    case connection
    case launchAtLogin
    case details
}

@MainActor
private final class StatusAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var timer: Timer?
    private var snapshot = readSnapshot()
    private var authorizationState = ServiceAuthorizationManager.state
    private var interfaceError: String?
    private var pendingConnectionState: Bool?
    private var pendingConnectionStartedAt: Date?
    private var menuIsOpen = false
    private var shouldRefreshOnClosedTick = false
    private var displayedStatusState: DisplayState?
    private var displayedStatusMessage: String?

    override init() {
        super.init()
        updateStatusItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refresh()
        configureNativeMenu()
        let refreshTimer = Timer(timeInterval: 1,
                                 target: self,
                                 selector: #selector(timerTick),
                                 userInfo: nil,
                                 repeats: true)
        refreshTimer.tolerance = 0.1
        RunLoop.main.add(refreshTimer, forMode: .default)
        RunLoop.main.add(refreshTimer, forMode: .eventTracking)
        timer = refreshTimer
    }

    @objc private func timerTick() {
        if menuIsOpen {
            refresh()
            return
        }
        shouldRefreshOnClosedTick.toggle()
        if shouldRefreshOnClosedTick {
            refresh()
        }
    }

    @objc private func refresh() {
        snapshot = readSnapshot()
        authorizationState = ServiceAuthorizationManager.state
        if let pending = pendingConnectionState {
            let reachedRequestedState = pending
                ? snapshot.state != .paused && snapshot.state != .stopped
                : snapshot.state == .paused || snapshot.state == .stopped
            let requestExpired = pendingConnectionStartedAt.map {
                Date().timeIntervalSince($0) > 5
            } ?? true
            if reachedRequestedState || requestExpired {
                pendingConnectionState = nil
                pendingConnectionStartedAt = nil
            }
        }
        updateStatusItem()
        if menuIsOpen {
            updateNativeVisibleContent()
        }
    }

    private func updateStatusItem() {
        let symbol: String
        let state: DisplayState
        if let pendingConnectionState {
            state = pendingConnectionState ? .connecting : .paused
        } else {
            state = snapshot.state
        }
        let statusChanged = displayedStatusState != state ||
            displayedStatusMessage != snapshot.message
        switch state {
        case .connected:
            symbol = "personalhotspot"
        case .connecting:
            symbol = "arrow.triangle.2.circlepath"
        case .waiting:
            symbol = "cable.connector"
        case .paused:
            symbol = "pause.circle"
        case .error:
            symbol = "exclamationmark.triangle"
        case .stopped, .unavailable:
            symbol = "network.slash"
        }
        if let button = statusItem.button,
           statusChanged || button.image == nil {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HoRNDIS")
                ?? NSImage(systemSymbolName: "network", accessibilityDescription: "HoRNDIS")
            image?.isTemplate = true
            button.image = image
            // Let NSStatusBarButton apply its standard template-image effects so the
            // symbol follows the actual menu bar appearance, independently of app mode.
            button.contentTintColor = nil
            button.toolTip = "HoRNDIS — \(snapshot.message)"
        }
        if statusChanged {
            displayedStatusState = state
            displayedStatusMessage = snapshot.message
        }
    }

    private func summaryContent() -> [(title: String, symbol: String)] {
        var content = [(snapshot.message, "personalhotspot")]
        if let runtime = snapshot.runtime {
            let device = runtime.device.isEmpty ? localized("No device", "未连接设备") : runtime.device
            let received = ByteCountFormatter.string(fromByteCount: Int64(runtime.receivedBytes),
                                                     countStyle: .binary)
            let transmitted = ByteCountFormatter.string(fromByteCount: Int64(runtime.transmittedBytes),
                                                        countStyle: .binary)
            let interval = runtime.connectedSince > 0
                ? max(0, Date().timeIntervalSince1970 - Double(runtime.connectedSince))
                : 0
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            let duration = runtime.connectedSince > 0 ? formatter.string(from: interval) ?? "—" : "—"
            content.append(("\(localized("Device", "设备")): \(device)", "iphone"))
            content.append(("↑ \(transmitted)    ↓ \(received)", "arrow.up.arrow.down"))
            content.append(("\(localized("Connected", "连接时长")): \(duration)", "clock"))
        } else if let address = snapshot.ipAddress {
            content.append(("\(localized("Device", "设备")): Android", "iphone"))
            content.append(("IP: \(address)", "globe"))
            content.append(("\(localized("Connected", "连接时长")): —", "clock"))
        } else {
            content.append(("\(localized("Device", "设备")): \(localized("No device", "未连接设备"))",
                            "iphone"))
            content.append(("↑ 0 bytes    ↓ 0 bytes", "arrow.up.arrow.down"))
            content.append(("\(localized("Connected", "连接时长")): —", "clock"))
        }
        content.append((authorizationState.title, authorizationState.symbol))
        return content
    }

    private func nativeSymbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func nativeInfoItem(tag: NativeMenuTag) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = tag.rawValue
        item.isEnabled = false
        return item
    }

    private func nativeActionItem(_ title: String,
                                  symbol: String,
                                  action: Selector,
                                  keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = nativeSymbol(symbol)
        return item
    }

    private func nativeSwitchItem(tag: NativeMenuTag,
                                  title: String,
                                  symbol: String,
                                  state: NSControl.StateValue,
                                  isEnabled: Bool,
                                  action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = tag.rawValue
        item.isEnabled = true
        item.view = NativeMenuSwitchRow(title: title,
                                        image: nativeSymbol(symbol),
                                        state: state,
                                        isEnabled: isEnabled,
                                        target: self,
                                        action: action)
        return item
    }

    private func configureNativeMenu() {
        let menu = NSMenu(title: "HoRNDIS")
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = NativeMenuMetrics.width

        menu.addItem(nativeInfoItem(tag: .status))
        menu.addItem(nativeInfoItem(tag: .device))
        menu.addItem(nativeInfoItem(tag: .traffic))
        menu.addItem(nativeInfoItem(tag: .duration))
        menu.addItem(nativeInfoItem(tag: .authorization))

        let authorize = nativeActionItem(localized("Authorize and Install…", "授权并安装…"),
                                         symbol: "lock.open",
                                         action: #selector(authorizeAndInstall))
        authorize.tag = 109
        menu.addItem(authorize)
        menu.addItem(.separator())

        menu.addItem(nativeSwitchItem(tag: .connection,
                                      title: localized("USB Tethering", "USB 网络共享"),
                                      symbol: "personalhotspot",
                                      state: .off,
                                      isEnabled: false,
                                      action: #selector(nativeSetConnection(_:))))
        menu.addItem(nativeSwitchItem(tag: .launchAtLogin,
                                      title: localized("Launch at Login", "登录时启动"),
                                      symbol: "power",
                                      state: .off,
                                      isEnabled: true,
                                      action: #selector(nativeSetLaunchAtLogin(_:))))

        let details = NSMenuItem(title: localized("Details", "详细信息"),
                                 action: nil,
                                 keyEquivalent: "")
        details.tag = NativeMenuTag.details.rawValue
        details.image = nativeSymbol("info.circle")
        details.submenu = NSMenu(title: localized("Details", "详细信息"))
        details.submenu?.delegate = self
        menu.addItem(details)

        menu.addItem(.separator())
        menu.addItem(nativeActionItem(localized("Quit HoRNDIS Status", "退出 HoRNDIS 状态栏"),
                                      symbol: "xmark.circle",
                                      action: #selector(quit),
                                      keyEquivalent: "q"))

        statusItem.menu = menu
        updateNativeVisibleContent()
        rebuildNativeDetailsMenu()
    }

    private func rebuildNativeDetailsMenu() {
        guard let item = statusItem.menu?.item(withTag: NativeMenuTag.details.rawValue),
              let submenu = item.submenu else {
            return
        }
        submenu.removeAllItems()
        if let runtime = snapshot.runtime {
            let interface = runtime.hostInterface.isEmpty ? "feth99" : runtime.hostInterface
            let address = snapshot.ipAddress ?? localized("configuring…", "配置中…")
            let rows = [
                ("IP: \(address)", "globe"),
                ("\(localized("Interface", "接口")): \(interface)", "network"),
                (runtime.deviceAddress.isEmpty ? nil : "MAC: \(runtime.deviceAddress)", "number"),
                ("PID: \(runtime.processID)", "gearshape"),
                (runtime.detail.isEmpty ? nil : runtime.detail, "text.bubble"),
            ]
            for (title, symbol) in rows {
                guard let title else { continue }
                let detail = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                detail.image = nativeSymbol(symbol)
                detail.isEnabled = false
                submenu.addItem(detail)
            }
        }
        if let interfaceError {
            let error = NSMenuItem(title: interfaceError, action: nil, keyEquivalent: "")
            error.image = nativeSymbol("exclamationmark.triangle")
            error.isEnabled = false
            submenu.addItem(error)
        }
        if !submenu.items.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(nativeActionItem(localized("Copy Diagnostics", "复制诊断信息"),
                                         symbol: "doc.on.doc",
                                         action: #selector(copyDiagnostics)))
        submenu.addItem(nativeActionItem(localized("Open Service Log", "打开服务日志"),
                                         symbol: "doc.text",
                                         action: #selector(openLog)))
        submenu.addItem(nativeActionItem(localized("Open Project Page", "打开项目主页"),
                                         symbol: "safari",
                                         action: #selector(openProject)))
    }

    private func updateNativeVisibleContent() {
        guard let menu = statusItem.menu else { return }
        let tags: [NativeMenuTag] = [.status, .device, .traffic, .duration, .authorization]
        for (tag, content) in zip(tags, summaryContent()) {
            guard let item = menu.item(withTag: tag.rawValue) else { continue }
            item.title = content.title
            item.image = nativeSymbol(content.symbol)
        }
        menu.item(withTag: 109)?.isHidden = authorizationState != .required

        let serviceEnabled = snapshot.runtime != nil &&
            snapshot.state != .paused && snapshot.state != .stopped
        let displayedState = pendingConnectionState ?? serviceEnabled
        let connectionAvailable = snapshot.runtime?.controlAvailable == true
        (menu.item(withTag: NativeMenuTag.connection.rawValue)?.view as? NativeMenuSwitchRow)?
            .update(state: displayedState ? .on : .off, isEnabled: connectionAvailable)
        (menu.item(withTag: NativeMenuTag.launchAtLogin.rawValue)?.view as? NativeMenuSwitchRow)?
            .update(state: LaunchAgentManager.isInstalled ? .on : .off, isEnabled: true)
    }

    @objc private func nativeSetConnection(_ sender: NSSwitch) {
        let requested = sender.state == .on
        if !setConnectionEnabled(requested) {
            sender.state = requested ? .off : .on
        }
        updateNativeVisibleContent()
    }

    @objc private func nativeSetLaunchAtLogin(_ sender: NSSwitch) {
        let requested = sender.state == .on
        if !setLaunchAtLoginEnabled(requested) {
            sender.state = requested ? .off : .on
        }
        updateNativeVisibleContent()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        snapshot = readSnapshot()
        authorizationState = ServiceAuthorizationManager.state
        updateStatusItem()
        if menu === statusItem.menu {
            updateNativeVisibleContent()
        } else {
            rebuildNativeDetailsMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = true
            refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = false
        }
    }

    @discardableResult
    private func setConnectionEnabled(_ requestedState: Bool) -> Bool {
        pendingConnectionState = requestedState
        pendingConnectionStartedAt = Date()
        updateStatusItem()
        do {
            try ControlClient.send(requestedState ? "connect\n" : "disconnect\n")
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
            pendingConnectionState = nil
            pendingConnectionStartedAt = nil
            updateStatusItem()
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
        return true
    }

    @objc private func copyDiagnostics() {
        var lines = [
            "HoRNDIS Status \(horndisStatusVersion)",
            "State: \(snapshot.runtime?.state ?? "unavailable")",
            "Device: \(snapshot.runtime?.device ?? "")",
            "Device MAC: \(snapshot.runtime?.deviceAddress ?? "")",
            "Interface: \(snapshot.runtime?.hostInterface ?? "feth99")",
            "IPv4: \(snapshot.ipAddress ?? "")",
            "Detail: \(snapshot.runtime?.detail ?? snapshot.message)",
            "Authorization: \(authorizationState == .granted ? "granted" : "required")",
        ]
        if let runtime = snapshot.runtime {
            lines.append("RX bytes: \(runtime.receivedBytes)")
            lines.append("TX bytes: \(runtime.transmittedBytes)")
            lines.append("Service PID: \(runtime.processID)")
            lines.append("Control available: \(runtime.controlAvailable == true)")
            lines.append("Status updated: \(runtime.updatedAt)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/horndis.log"))
    }

    @discardableResult
    private func setLaunchAtLoginEnabled(_ shouldInstall: Bool) -> Bool {
        do {
            if shouldInstall {
                try LaunchAgentManager.writeConfiguration()
            } else {
                try LaunchAgentManager.removeConfiguration()
            }
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
            return false
        }
        updateNativeVisibleContent()
        return true
    }

    @objc private func authorizeAndInstall() {
        let foregroundApplication = NSWorkspace.shared.frontmostApplication
        let applicationToRestore = foregroundApplication?.processIdentifier ==
            ProcessInfo.processInfo.processIdentifier ? nil : foregroundApplication
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            defer {
                if let applicationToRestore {
                    _ = applicationToRestore.activate(options: [.activateIgnoringOtherApps])
                }
            }
            do {
                try ServiceAuthorizationManager.requestInstallation()
                self.authorizationState = ServiceAuthorizationManager.state
                guard self.authorizationState == .granted else {
                    throw NSError(domain: "HoRNDISStatus",
                                  code: Int(EIO),
                                  userInfo: [NSLocalizedDescriptionKey:
                                      localized("The privileged service installation could not be verified",
                                                "无法验证特权服务是否已正确安装")])
                }
                self.interfaceError = nil
            } catch {
                self.interfaceError = error.localizedDescription
            }
            self.refresh()
        }
    }

    @objc private func openProject() {
        NSWorkspace.shared.open(projectURL)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private func writeStandardError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func handleCommandLine() -> Bool {
    guard CommandLine.arguments.count > 1 else {
        return false
    }
    let command = CommandLine.arguments[1]
    do {
        switch command {
        case "install":
            try LaunchAgentManager.installAndStart()
            print("HoRNDIS menu bar status installed and started.")
        case "start", "open":
            try LaunchAgentManager.start()
            print("HoRNDIS menu bar status started.")
        case "stop", "quit":
            try LaunchAgentManager.stop()
            print("HoRNDIS menu bar status stopped; login startup remains configured.")
        case "restart":
            try LaunchAgentManager.restart()
            print("HoRNDIS menu bar status restarted.")
        case "status":
            print("HoRNDIS menu bar status: \(LaunchAgentManager.isRunning ? "running" : "stopped")")
            print("Launch at login: \(LaunchAgentManager.isInstalled ? "enabled" : "disabled")")
        case "uninstall":
            try LaunchAgentManager.uninstall()
            print("HoRNDIS menu bar status stopped and removed.")
        case "--version", "version":
            print("horndis-status \(horndisStatusVersion)")
        case "--help", "help":
            print("""
            Usage:
              horndis-status             Run the menu bar status app
              horndis-status start       Open the app without changing login startup
              horndis-status stop        Quit the app but preserve login startup
              horndis-status restart     Restart the app
              horndis-status status      Show app and login-startup status
              horndis-status install     Start now and at login (no sudo)
              horndis-status uninstall   Remove the login item
              horndis-status --version
            """)
        default:
            writeStandardError("Unknown command: \(command)")
            exit(64)
        }
    } catch {
        writeStandardError(error.localizedDescription)
        exit(1)
    }
    return true
}

@main
private enum HoRNDISStatusEntryPoint {
    static func main() {
        if handleCommandLine() {
            return
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = StatusAppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
        }
    }
}
