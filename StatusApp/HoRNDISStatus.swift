// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation
import SwiftUI

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
    let preferredLocalization = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        ?? Bundle.main.preferredLocalizations.first
        ?? Locale.preferredLanguages.first
        ?? "en"
    return preferredLocalization.hasPrefix("zh") ? chinese : english
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

private struct StatusPopoverRow: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
}

@MainActor
private final class StatusPopoverModel: ObservableObject {
    @Published var statusSymbol = "network.slash"
    @Published var summaryRows: [StatusPopoverRow] = []
    @Published var detailRows: [StatusPopoverRow] = []
    @Published var authorizationRequired = false
    @Published var connectionOn = false
    @Published var connectionEnabled = false
    @Published var launchAtLoginOn = false
    @Published var detailsExpanded = false

    var setConnection: (Bool) -> Void = { _ in }
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var authorize: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var openLog: () -> Void = {}
    var openProject: () -> Void = {}
    var quit: () -> Void = {}
    var didAppear: () -> Void = {}
    var didDisappear: () -> Void = {}
}

private enum StatusPopoverMetrics {
    static let width: CGFloat = 286
    static let rowHeight: CGFloat = 32
    // The current system Apple menu leaves 5 pt between the selection and
    // each horizontal edge. Keep the same measured inset here.
    static let selectionInset: CGFloat = 5
    static let selectionVerticalInset: CGFloat = 4
    // 5 pt outer selection inset + 7 pt content inset preserves the shared
    // 12 pt icon column used by summary and switch rows.
    static let selectionContentHorizontalInset: CGFloat = 7
    // Matches the native macOS menu selection curve. On current systems,
    // ConcentricRectangle also resolves this relative to the system container.
    static let selectionCornerRadius: CGFloat = 8
}

private struct StatusPopoverInfoRow: View {
    let row: StatusPopoverRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .frame(width: 16)
                .foregroundColor(.secondary)
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: StatusPopoverMetrics.rowHeight)
    }
}

private final class StatusPopoverHoverModel: ObservableObject {
    @Published var isHovered = false
}

private struct StatusPopoverSwitchRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    private var toggle: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .controlSize(.mini)
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var systemToggle: some View {
        if #available(macOS 12.0, *) {
            toggle.toggleStyle(.switch)
        } else {
            toggle.toggleStyle(SwitchToggleStyle(tint: Color(NSColor.controlAccentColor)))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 8)
            systemToggle
        }
        .padding(.horizontal, 12)
        .frame(height: StatusPopoverMetrics.rowHeight)
    }
}

private struct StatusPopoverSelectionBackground: View {
    let isSelected: Bool

    private var compatibilityBackground: some View {
        RoundedRectangle(
            cornerRadius: StatusPopoverMetrics.selectionCornerRadius,
            style: .continuous
        )
            .fill(isSelected ? Color.accentColor : Color.clear)
            .padding(.vertical, StatusPopoverMetrics.selectionVerticalInset)
    }

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(StatusPopoverMetrics.selectionCornerRadius)
                )
            )
            .fill(isSelected ? Color.accentColor : Color.clear)
            .padding(.vertical, StatusPopoverMetrics.selectionVerticalInset)
        } else {
            compatibilityBackground
        }
#else
        compatibilityBackground
#endif
    }
}

private struct StatusPopoverActionRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @StateObject private var hoverModel: StatusPopoverHoverModel

    init(title: String,
         symbol: String,
         shortcut: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
        _hoverModel = StateObject(wrappedValue: StatusPopoverHoverModel())
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .foregroundColor(hoverModel.isHovered
                            ? Color(NSColor.selectedMenuItemTextColor).opacity(0.75)
                            : Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.horizontal, StatusPopoverMetrics.selectionContentHorizontalInset)
            .frame(height: StatusPopoverMetrics.rowHeight)
            .foregroundColor(hoverModel.isHovered
                ? Color(NSColor.selectedMenuItemTextColor)
                : Color.primary)
            .background(StatusPopoverSelectionBackground(
                isSelected: hoverModel.isHovered
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, StatusPopoverMetrics.selectionInset)
        .onHover { hovering in
            hoverModel.isHovered = hovering
        }
    }
}

private struct StatusPopoverDisclosureLabel: View {
    let expanded: Bool
    @StateObject private var hoverModel = StatusPopoverHoverModel()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .frame(width: 16)
            Text(localized("Details", "详细信息"))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(hoverModel.isHovered
                    ? Color(NSColor.selectedMenuItemTextColor).opacity(0.8)
                    : .secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, StatusPopoverMetrics.selectionContentHorizontalInset)
        .frame(height: StatusPopoverMetrics.rowHeight)
        .foregroundColor(hoverModel.isHovered
            ? Color(NSColor.selectedMenuItemTextColor)
            : Color.primary)
        .background(StatusPopoverSelectionBackground(
            isSelected: hoverModel.isHovered
        ))
        .contentShape(Rectangle())
        .padding(.horizontal, StatusPopoverMetrics.selectionInset)
        .frame(height: StatusPopoverMetrics.rowHeight)
        .onHover { hovering in
            hoverModel.isHovered = hovering
        }
    }
}

@available(macOS 13.0, *)
private struct StatusPopoverDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                if #available(macOS 14.0, *) {
                    withAnimation(.smooth(duration: 0.22, extraBounce: 0)) {
                        configuration.isExpanded.toggle()
                    }
                } else {
                    withAnimation(.spring().speed(1.6)) {
                        configuration.isExpanded.toggle()
                    }
                }
            } label: {
                configuration.label
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
        .clipped()
    }
}

private struct StatusPopoverContent: View {
    @ObservedObject var model: StatusPopoverModel

    private var connectionBinding: Binding<Bool> {
        Binding(get: { model.connectionOn }, set: { model.setConnection($0) })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLoginOn },
                set: { model.setLaunchAtLogin($0) })
    }

    private var legacyDetailsBinding: Binding<Bool> {
        Binding(get: { model.detailsExpanded }, set: { expanded in
            withAnimation(.spring().speed(1.6)) {
                model.detailsExpanded = expanded
            }
        })
    }

    private var detailsContent: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 10)
            ForEach(model.detailRows) { StatusPopoverInfoRow(row: $0) }
            StatusPopoverActionRow(title: localized("Copy Diagnostics", "复制诊断信息"),
                                   symbol: "doc.on.doc",
                                   action: model.copyDiagnostics)
            StatusPopoverActionRow(title: localized("Open Service Log", "打开服务日志"),
                                   symbol: "doc.text",
                                   action: model.openLog)
            StatusPopoverActionRow(title: localized("Open Project Page", "打开项目主页"),
                                   symbol: "safari",
                                   action: model.openProject)
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        if #available(macOS 13.0, *) {
            DisclosureGroup(isExpanded: $model.detailsExpanded) {
                detailsContent
            } label: {
                StatusPopoverDisclosureLabel(expanded: model.detailsExpanded)
            }
            .disclosureGroupStyle(StatusPopoverDisclosureStyle())
        } else {
            DisclosureGroup(isExpanded: legacyDetailsBinding) {
                detailsContent
            } label: {
                StatusPopoverDisclosureLabel(expanded: model.detailsExpanded)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.summaryRows) { StatusPopoverInfoRow(row: $0) }
            if model.authorizationRequired {
                StatusPopoverActionRow(
                    title: localized("Authorize and Install…", "授权并安装…"),
                    symbol: "exclamationmark.shield",
                    action: model.authorize
                )
            }
            Divider().padding(.horizontal, 10)
            StatusPopoverSwitchRow(title: localized("USB Tethering", "USB 网络共享"),
                                   symbol: "personalhotspot",
                                   isOn: connectionBinding,
                                   isEnabled: model.connectionEnabled)
            StatusPopoverSwitchRow(title: localized("Launch at Login", "登录时启动"),
                                   symbol: "power",
                                   isOn: launchAtLoginBinding,
                                   isEnabled: true)
            detailsSection
            Divider().padding(.horizontal, 10)
            StatusPopoverActionRow(title: localized("Quit HoRNDIS Status",
                                                     "退出 HoRNDIS 状态栏"),
                                   symbol: "xmark.circle",
                                   shortcut: "⌘Q",
                                   action: model.quit)
        }
        .padding(.top, 6)
        // The final row already contributes 4 pt through its selection
        // background. One extra point matches the Apple menu's 5 pt bottom
        // edge while preserving the shared 32 pt row height.
        .padding(.bottom, 1)
        .frame(width: StatusPopoverMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: model.didAppear)
        .onDisappear(perform: model.didDisappear)
    }
}

private struct StatusPopoverLabel: View {
    @ObservedObject var model: StatusPopoverModel

    var body: some View {
        Image(systemName: model.statusSymbol)
            .accessibilityLabel("HoRNDIS")
    }
}

@MainActor
private final class StatusAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let popoverModel = StatusPopoverModel()
    private var legacyStatusItem: NSStatusItem?
    private let legacyPopover = NSPopover()
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
    private var didFinishLaunching = false
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var localEscapeMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private let outsideClickMask: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    override init() {
        super.init()
        configurePopoverActions()
        updateStatusItem()
        updatePopoverModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        NSApp.setActivationPolicy(.accessory)
        refresh()
        if #unavailable(macOS 13.0) {
            configureLegacyPopover()
        }
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
        updatePopoverModel()
    }

    private func configurePopoverActions() {
        popoverModel.setConnection = { [weak self] in
            _ = self?.setConnectionEnabled($0)
        }
        popoverModel.setLaunchAtLogin = { [weak self] in
            _ = self?.setLaunchAtLoginEnabled($0)
        }
        popoverModel.authorize = { [weak self] in
            self?.closeLegacyPopoverBeforeAction()
            self?.authorizeAndInstall()
        }
        popoverModel.copyDiagnostics = { [weak self] in
            self?.closeLegacyPopoverBeforeAction()
            self?.copyDiagnostics()
        }
        popoverModel.openLog = { [weak self] in
            self?.closeLegacyPopoverBeforeAction()
            self?.openLog()
        }
        popoverModel.openProject = { [weak self] in
            self?.closeLegacyPopoverBeforeAction()
            self?.openProject()
        }
        popoverModel.quit = { [weak self] in self?.quit() }
        popoverModel.didAppear = { [weak self] in
            self?.menuIsOpen = true
        }
        popoverModel.didDisappear = { [weak self] in
            self?.menuIsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.menuIsOpen else {
                    return
                }
                self.popoverModel.detailsExpanded = false
            }
        }
    }

    private func makePopoverContentController()
        -> NSHostingController<StatusPopoverContent> {
        let controller = NSHostingController(
            rootView: StatusPopoverContent(model: popoverModel)
        )
        return controller
    }

    private func setInitialPopoverContentSize() {
        guard let controller = legacyPopover.contentViewController
                as? NSHostingController<StatusPopoverContent> else {
            return
        }
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.sizeThatFits(
            in: NSSize(width: StatusPopoverMetrics.width,
                       height: .greatestFiniteMagnitude)
        )
        let target = NSSize(width: StatusPopoverMetrics.width,
                            height: ceil(fitting.height))
        guard target.width.isFinite,
              target.height.isFinite,
              target.height > 0,
              target.height < 2_000,
              (abs(legacyPopover.contentSize.width - target.width) > 0.5 ||
                abs(legacyPopover.contentSize.height - target.height) > 0.5) else {
            return
        }
        // Bound the initial hidden popover once. While it is visible, the
        // hosting controller and AppKit animate SwiftUI's intrinsic-size
        // changes together; repeatedly forcing contentSize during disclosure
        // animation would restart the whole popover transition.
        legacyPopover.contentSize = target
    }

    private func installOutsideClickMonitors() {
        guard localOutsideClickMonitor == nil,
              globalOutsideClickMonitor == nil,
              localEscapeMonitor == nil,
              resignActiveObserver == nil,
              activeSpaceObserver == nil else { return }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: outsideClickMask
        ) { [weak self] event in
            guard let self else { return event }
            let popoverWindow = self.legacyPopover.contentViewController?.view.window
            if event.window === popoverWindow {
                // An initial mouse-down inside the popover may start the
                // system switch's native drag loop. Never close its host
                // until a later, independent outside click.
                return event
            }
            if let button = self.legacyStatusItem?.button,
               event.window === button.window,
               button.bounds.contains(button.convert(event.locationInWindow,
                                                     from: nil)) {
                return event
            }
            DispatchQueue.main.async { [weak self] in
                self?.closePopoverForOutsideClick()
            }
            return event
        }
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: outsideClickMask
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.closePopoverForOutsideClick()
            }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard event.keyCode == 53,
                  self?.legacyPopover.isShown == true else {
                return event
            }
            DispatchQueue.main.async { [weak self] in
                self?.closePopoverForOutsideClick()
            }
            return nil
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.closePopoverForOutsideClick()
            }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.closePopoverForOutsideClick()
            }
        }
    }

    private func closeLegacyPopoverBeforeAction() {
        guard legacyPopover.isShown else { return }
        legacyPopover.performClose(nil)
    }

    private func closePopoverForOutsideClick() {
        guard legacyPopover.isShown else { return }
        legacyPopover.performClose(nil)
    }

    private func removeOutsideClickMonitors() {
        if let monitor = localOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            localOutsideClickMonitor = nil
        }
        if let monitor = globalOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalOutsideClickMonitor = nil
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activeSpaceObserver = nil
        }
    }

    private func configureLegacyPopover() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        legacyStatusItem = item
        item.isVisible = true
        let initialImage = NSImage(systemSymbolName: "personalhotspot",
                                   accessibilityDescription: "HoRNDIS")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "HoRNDIS")
        initialImage?.isTemplate = true
        item.button?.image = initialImage
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover(_:))
        // We close on the next independent outside mouse-down instead of
        // allowing AppKit to tear down the host during a switch drag.
        legacyPopover.behavior = .applicationDefined
        legacyPopover.animates = true
        legacyPopover.delegate = self
        legacyPopover.contentViewController = makePopoverContentController()
        setInitialPopoverContentSize()
        updateStatusItem()
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        if legacyPopover.isShown {
            legacyPopover.performClose(sender)
        } else {
            legacyPopover.show(relativeTo: sender.bounds,
                               of: sender,
                               preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        menuIsOpen = true
        installOutsideClickMonitors()
    }

    func popoverDidShow(_ notification: Notification) {
        // Make only the popover key. This gives native controls the system
        // active appearance without moving the user's foreground application
        // behind the menu-bar utility.
        legacyPopover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillClose(_ notification: Notification) {
        menuIsOpen = false
        removeOutsideClickMonitors()
        // Reset synchronously before creating the next host. This avoids a
        // reopened collapsed view inheriting the old expanded content size.
        popoverModel.detailsExpanded = false
    }

    func popoverDidClose(_ notification: Notification) {
        // Recreate the host only after AppKit has completely closed the window.
        // The application-defined lifetime lets the native switch finish its
        // pointer tracking before close; rebuilding additionally clears any
        // interrupted hover state before the next open.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.legacyPopover.isShown else { return }
            self.legacyPopover.contentViewController = self.makePopoverContentController()
            self.setInitialPopoverContentSize()
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
        if popoverModel.statusSymbol != symbol {
            popoverModel.statusSymbol = symbol
        }
        if let button = legacyStatusItem?.button,
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

    private func updatePopoverModel() {
        let summary = summaryContent().enumerated().map { index, row in
            StatusPopoverRow(id: "summary-\(index)",
                             title: row.title,
                             symbol: row.symbol)
        }
        if popoverModel.summaryRows != summary {
            popoverModel.summaryRows = summary
        }

        var detailRows: [StatusPopoverRow] = []
        if let runtime = snapshot.runtime {
            let interface = runtime.hostInterface.isEmpty ? "feth99" : runtime.hostInterface
            let address = snapshot.ipAddress ?? localized("configuring…", "配置中…")
            detailRows.append(StatusPopoverRow(id: "ip",
                                               title: "IP: \(address)",
                                               symbol: "globe"))
            detailRows.append(StatusPopoverRow(
                id: "interface",
                title: "\(localized("Interface", "接口")): \(interface)",
                symbol: "network"
            ))
            if !runtime.deviceAddress.isEmpty {
                detailRows.append(StatusPopoverRow(id: "mac",
                                                   title: "MAC: \(runtime.deviceAddress)",
                                                   symbol: "number"))
            }
            detailRows.append(StatusPopoverRow(id: "pid",
                                               title: "PID: \(runtime.processID)",
                                               symbol: "gearshape"))
            if !runtime.detail.isEmpty {
                detailRows.append(StatusPopoverRow(id: "detail",
                                                   title: runtime.detail,
                                                   symbol: "text.bubble"))
            }
        }
        if let interfaceError {
            detailRows.append(StatusPopoverRow(id: "error",
                                               title: interfaceError,
                                               symbol: "exclamationmark.triangle"))
        }
        if popoverModel.detailRows != detailRows {
            popoverModel.detailRows = detailRows
        }

        let serviceEnabled = snapshot.runtime != nil &&
            snapshot.state != .paused && snapshot.state != .stopped
        let displayedState = pendingConnectionState ?? serviceEnabled
        if popoverModel.connectionOn != displayedState {
            popoverModel.connectionOn = displayedState
        }
        let connectionAvailable = snapshot.runtime?.controlAvailable == true
        if popoverModel.connectionEnabled != connectionAvailable {
            popoverModel.connectionEnabled = connectionAvailable
        }
        let launchAtLogin = LaunchAgentManager.isInstalled
        if popoverModel.launchAtLoginOn != launchAtLogin {
            popoverModel.launchAtLoginOn = launchAtLogin
        }
        let authorizationRequired = authorizationState == .required
        if popoverModel.authorizationRequired != authorizationRequired {
            popoverModel.authorizationRequired = authorizationRequired
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
        updatePopoverModel()
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

@available(macOS 13.0, *)
private struct ModernHoRNDISStatusApplication: App {
    @NSApplicationDelegateAdaptor(StatusAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverContent(model: appDelegate.popoverModel)
        } label: {
            StatusPopoverLabel(model: appDelegate.popoverModel)
        }
        .menuBarExtraStyle(.window)
    }
}

@main
private enum HoRNDISStatusEntryPoint {
    static func main() {
        if handleCommandLine() {
            return
        }
        if #available(macOS 13.0, *) {
            ModernHoRNDISStatusApplication.main()
        } else {
            MainActor.assumeIsolated {
                let application = NSApplication.shared
                let delegate = StatusAppDelegate()
                application.delegate = delegate
                application.setActivationPolicy(.accessory)
                application.run()
            }
        }
    }
}
