// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import Foundation

private let horndisStatusVersion = "0.2.0"
private let statusPath = "/var/run/horndis/status.json"
private let controlPath = "/var/run/horndis/control.sock"
private let launchAgentLabel = "io.github.noahhhi.horndis.status"
private let projectURL = URL(string: "https://github.com/noahhhi/HoRNDIS-Userspace")!

private func localized(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
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

private enum DisplayState {
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
        if Bundle.main.bundleIdentifier == launchAgentLabel,
           let bundledExecutable = Bundle.main.executableURL {
            return bundledExecutable.standardizedFileURL.path
        }
        let argument = CommandLine.arguments[0]
        let absoluteURL: URL
        if argument.hasPrefix("/") {
            absoluteURL = URL(fileURLWithPath: argument)
        } else {
            absoluteURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argument)
        }
        return absoluteURL.resolvingSymlinksInPath().standardizedFileURL.path
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

    static func runLaunchctl(_ arguments: [String], allowFailure: Bool = false) throws {
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

private enum MenuMetrics {
    static let width: CGFloat = 286
    static let rowHeight: CGFloat = 30
    static let horizontalInset: CGFloat = 13
    static let iconSize: CGFloat = 16
    static let iconTextGap: CGFloat = 10
    static let textX = horizontalInset + iconSize + iconTextGap
}

@MainActor
private class HighlightableMenuRowView: NSView {
    private var trackingAreaReference: NSTrackingArea?
    private(set) var isHovered = false
    var allowsHighlight = true

    init() {
        super.init(frame: NSRect(x: 0,
                                 y: 0,
                                 width: MenuMetrics.width,
                                 height: MenuMetrics.rowHeight))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard allowsHighlight else {
            return
        }
        isHovered = true
        needsDisplay = true
        hoverStateDidChange()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        hoverStateDidChange()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered && allowsHighlight {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2),
                         xRadius: 6,
                         yRadius: 6).fill()
        }
    }

    func hoverStateDidChange() {}
}

@MainActor
private final class SystemAccentSwitch: NSSwitch {
    override func draw(_ dirtyRect: NSRect) {
        guard state == .on else {
            super.draw(dirtyRect)
            return
        }

        let trackRect = bounds.insetBy(dx: 1, dy: 1)
        let accentColor = isEnabled
            ? NSColor.controlAccentColor
            : NSColor.controlAccentColor.withAlphaComponent(0.45)
        accentColor.setFill()
        NSBezierPath(roundedRect: trackRect,
                     xRadius: trackRect.height / 2,
                     yRadius: trackRect.height / 2).fill()

        let knobInset: CGFloat = 2
        let knobDiameter = trackRect.height - knobInset * 2
        let knobRect = NSRect(x: trackRect.maxX - knobInset - knobDiameter,
                              y: trackRect.minY + knobInset,
                              width: knobDiameter,
                              height: knobDiameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class MenuSwitchRowView: HighlightableMenuRowView {
    let toggle: SystemAccentSwitch
    private let titleLabel: NSTextField

    init(title: String,
         state: NSControl.StateValue,
         isEnabled: Bool,
         target: AnyObject,
         action: Selector) {
        toggle = SystemAccentSwitch()
        titleLabel = NSTextField(labelWithString: title)
        super.init()

        allowsHighlight = isEnabled
        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: MenuMetrics.horizontalInset,
                                  y: floor((MenuMetrics.rowHeight - titleLabel.frame.height) / 2),
                                  width: 195,
                                  height: titleLabel.frame.height)
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)

        toggle.controlSize = .small
        toggle.state = state
        toggle.isEnabled = isEnabled
        toggle.target = target
        toggle.action = action
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(
            x: frame.width - MenuMetrics.horizontalInset - toggle.frame.width,
            y: floor((MenuMetrics.rowHeight - toggle.frame.height) / 2)
        )
        toggle.autoresizingMask = [.minXMargin]
        addSubview(toggle)

        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hoverStateDidChange() {
        titleLabel.textColor = isHovered ? .selectedMenuItemTextColor : (toggle.isEnabled
            ? .labelColor
            : .disabledControlTextColor)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggle.isEnabled && bounds.contains(point) && !toggle.frame.contains(point) {
            toggle.performClick(self)
        }
    }
}

@MainActor
private final class MenuActionRowView: HighlightableMenuRowView {
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField?
    private weak var actionTarget: AnyObject?
    private let actionSelector: Selector

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    init(title: String,
         image: NSImage?,
         target: AnyObject,
         action: Selector,
         keyEquivalent: String = "") {
        iconView = NSImageView()
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = keyEquivalent.isEmpty
            ? nil
            : NSTextField(labelWithString: "⌘\(keyEquivalent.uppercased())")
        actionTarget = target
        actionSelector = action
        super.init()

        iconView.image = image
        iconView.contentTintColor = .labelColor
        iconView.frame = NSRect(x: MenuMetrics.horizontalInset,
                                y: floor((MenuMetrics.rowHeight - MenuMetrics.iconSize) / 2),
                                width: MenuMetrics.iconSize,
                                height: MenuMetrics.iconSize)
        addSubview(iconView)

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.sizeToFit()
        let shortcutWidth: CGFloat = shortcutLabel == nil ? 0 : 38
        titleLabel.frame = NSRect(x: MenuMetrics.textX,
                                  y: floor((MenuMetrics.rowHeight - titleLabel.frame.height) / 2),
                                  width: MenuMetrics.width - MenuMetrics.textX -
                                      MenuMetrics.horizontalInset - shortcutWidth,
                                  height: titleLabel.frame.height)
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)

        if let shortcutLabel {
            shortcutLabel.font = NSFont.menuFont(ofSize: 0)
            shortcutLabel.textColor = .tertiaryLabelColor
            shortcutLabel.alignment = .right
            shortcutLabel.sizeToFit()
            shortcutLabel.frame = NSRect(
                x: MenuMetrics.width - MenuMetrics.horizontalInset - shortcutWidth,
                y: floor((MenuMetrics.rowHeight - shortcutLabel.frame.height) / 2),
                width: shortcutWidth,
                height: shortcutLabel.frame.height
            )
            shortcutLabel.autoresizingMask = [.minXMargin]
            addSubview(shortcutLabel)
        }

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hoverStateDidChange() {
        let color: NSColor = isHovered ? .selectedMenuItemTextColor : .labelColor
        iconView.contentTintColor = color
        titleLabel.textColor = color
        shortcutLabel?.textColor = isHovered ? .selectedMenuItemTextColor : .tertiaryLabelColor
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            NSApp.sendAction(actionSelector, to: actionTarget, from: self)
        }
    }
}

@MainActor
private final class MenuTextRowView: NSView {
    init(title: String, image: NSImage?) {
        super.init(frame: NSRect(x: 0,
                                 y: 0,
                                 width: MenuMetrics.width,
                                 height: MenuMetrics.rowHeight))

        let icon = NSImageView(frame: NSRect(
            x: MenuMetrics.horizontalInset,
            y: floor((MenuMetrics.rowHeight - MenuMetrics.iconSize) / 2),
            width: MenuMetrics.iconSize,
            height: MenuMetrics.iconSize
        ))
        icon.image = image
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        label.frame = NSRect(x: MenuMetrics.textX,
                             y: floor((MenuMetrics.rowHeight - label.frame.height) / 2),
                             width: MenuMetrics.width - MenuMetrics.textX -
                                 MenuMetrics.horizontalInset,
                             height: label.frame.height)
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct DetailRow {
    enum Kind {
        case text
        case action(Selector)
        case separator

        var isSeparator: Bool {
            if case .separator = self {
                return true
            }
            return false
        }
    }

    let title: String
    let symbol: String
    let kind: Kind
}

@MainActor
private final class AnimatedDetailsView: NSView {
    private let collapsedTitle: String
    private let expandedTitle: String
    private var headerRow: MenuActionRowView!
    private let contentView: NSView
    private let contentHeight: CGFloat
    private let onToggle: (Bool) -> Void
    private var expanded: Bool

    init(collapsedTitle: String,
         expandedTitle: String,
         expanded: Bool,
         rows: [DetailRow],
         target: AnyObject,
         symbolImage: (String) -> NSImage?,
         onToggle: @escaping (Bool) -> Void) {
        self.collapsedTitle = collapsedTitle
        self.expandedTitle = expandedTitle
        self.expanded = expanded
        self.onToggle = onToggle

        let separatorHeight: CGFloat = 10
        contentHeight = rows.reduce(0) { partial, row in
            partial + (row.kind.isSeparator ? separatorHeight : MenuMetrics.rowHeight)
        }
        contentView = NSView(frame: NSRect(x: 0,
                                           y: 0,
                                           width: MenuMetrics.width,
                                           height: contentHeight))
        super.init(frame: NSRect(x: 0,
                                 y: 0,
                                 width: MenuMetrics.width,
                                 height: MenuMetrics.rowHeight +
                                     (expanded ? contentHeight : 0)))

        headerRow = MenuActionRowView(title: expanded ? expandedTitle : collapsedTitle,
                                      image: symbolImage("info.circle"),
                                      target: self,
                                      action: #selector(toggle))

        wantsLayer = true
        layer?.masksToBounds = true

        headerRow.frame.origin.y = expanded ? contentHeight : 0
        headerRow.autoresizingMask = [.width]
        addSubview(headerRow)

        var cursor = contentHeight
        for row in rows {
            let height = row.kind.isSeparator ? separatorHeight : MenuMetrics.rowHeight
            cursor -= height

            switch row.kind {
            case .separator:
                let line = NSBox(frame: NSRect(x: 13,
                                               y: cursor + floor(height / 2),
                                               width: MenuMetrics.width - 26,
                                               height: 1))
                line.boxType = .separator
                line.autoresizingMask = [.width]
                contentView.addSubview(line)
            case .text:
                let textRow = MenuTextRowView(title: row.title,
                                              image: symbolImage(row.symbol))
                textRow.frame.origin.y = cursor
                textRow.autoresizingMask = [.width]
                contentView.addSubview(textRow)
            case let .action(selector):
                let actionRow = MenuActionRowView(title: row.title,
                                                  image: symbolImage(row.symbol),
                                                  target: target,
                                                  action: selector)
                actionRow.frame.origin.y = cursor
                actionRow.autoresizingMask = [.width]
                contentView.addSubview(actionRow)
            }
        }

        contentView.alphaValue = expanded ? 1 : 0
        addSubview(contentView, positioned: .below, relativeTo: headerRow)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func toggle() {
        setExpanded(!expanded, animated: true)
    }

    func setExpanded(_ newValue: Bool, animated: Bool) {
        guard newValue != expanded else {
            return
        }
        expanded = newValue
        onToggle(newValue)

        let targetHeight = MenuMetrics.rowHeight + (newValue ? contentHeight : 0)
        let targetHeaderOrigin = NSPoint(x: headerRow.frame.origin.x,
                                         y: newValue ? contentHeight : 0)
        headerRow.title = newValue ? expandedTitle : collapsedTitle

        guard animated else {
            frame.size.height = targetHeight
            headerRow.frame.origin = targetHeaderOrigin
            contentView.alphaValue = newValue ? 1 : 0
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            animator().setFrameSize(NSSize(width: frame.width, height: targetHeight))
            headerRow.animator().setFrameOrigin(targetHeaderOrigin)
            contentView.animator().alphaValue = newValue ? 1 : 0
        }
    }
}

@MainActor
private final class StatusAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var timer: Timer?
    private var snapshot = readSnapshot()
    private var interfaceError: String?
    private var showDetails = UserDefaults.standard.bool(forKey: "showDetails")
    private var menuIsOpen = false
    private var pendingConnectionState: Bool?
    private var pendingConnectionStartedAt: Date?
    private weak var detailsView: AnimatedDetailsView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresh()
        updateMenu()
        timer = Timer.scheduledTimer(timeInterval: 2,
                                     target: self,
                                     selector: #selector(refresh),
                                     userInfo: nil,
                                     repeats: true)
    }

    @objc private func refresh() {
        snapshot = readSnapshot()
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
    }

    private func updateStatusItem() {
        let symbol: String
        let color: NSColor
        let state: DisplayState
        if let pendingConnectionState {
            state = pendingConnectionState ? .connecting : .paused
        } else {
            state = snapshot.state
        }
        switch state {
        case .connected:
            symbol = "personalhotspot"
            color = .systemGreen
        case .connecting:
            symbol = "arrow.triangle.2.circlepath"
            color = .systemOrange
        case .waiting:
            symbol = "cable.connector"
            color = .secondaryLabelColor
        case .paused:
            symbol = "pause.circle"
            color = .secondaryLabelColor
        case .error:
            symbol = "exclamationmark.triangle"
            color = .systemRed
        case .stopped, .unavailable:
            symbol = "network.slash"
            color = .secondaryLabelColor
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HoRNDIS")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "HoRNDIS")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = color
        statusItem.button?.toolTip = "HoRNDIS — \(snapshot.message)"
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func disabledItem(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = MenuTextRowView(title: title, image: symbolImage(symbol))
        return item
    }

    private func connectionSwitchItem() -> NSMenuItem {
        let item = NSMenuItem()
        let serviceEnabled = snapshot.runtime != nil &&
            snapshot.state != .paused && snapshot.state != .stopped
        let displayedState = pendingConnectionState ?? serviceEnabled
        let row = MenuSwitchRowView(title: localized("USB Tethering", "USB 网络共享"),
                                    state: displayedState ? .on : .off,
                                    isEnabled: snapshot.runtime?.controlAvailable == true,
                                    target: self,
                                    action: #selector(setConnection(_:)))

        item.view = row
        item.toolTip = row.toggle.isEnabled
            ? nil
            : localized("Install or upgrade the background service first",
                        "请先安装或升级后台服务")
        return item
    }

    private func launchAtLoginSwitchItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuSwitchRowView(title: localized("Launch at Login", "登录时启动"),
                                      state: LaunchAgentManager.isInstalled ? .on : .off,
                                      isEnabled: true,
                                      target: self,
                                      action: #selector(setLaunchAtLogin(_:)))
        return item
    }

    private func actionItem(_ title: String,
                            symbol: String,
                            action: Selector,
                            keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.view = MenuActionRowView(title: title,
                                      image: symbolImage(symbol),
                                      target: self,
                                      action: action,
                                      keyEquivalent: keyEquivalent)
        return item
    }

    private func updateMenu(_ existingMenu: NSMenu? = nil) {
        let menu = existingMenu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        menu.minimumWidth = 286
        menu.addItem(disabledItem(snapshot.message, symbol: "personalhotspot"))

        if let runtime = snapshot.runtime {
            let device = runtime.device.isEmpty ? localized("No device", "未连接设备") : runtime.device
            menu.addItem(disabledItem("\(localized("Device", "设备")): \(device)", symbol: "iphone"))
            let received = ByteCountFormatter.string(fromByteCount: Int64(runtime.receivedBytes),
                                                     countStyle: .binary)
            let transmitted = ByteCountFormatter.string(fromByteCount: Int64(runtime.transmittedBytes),
                                                        countStyle: .binary)
            menu.addItem(disabledItem("↓ \(received)    ↑ \(transmitted)",
                                      symbol: "arrow.up.arrow.down"))
            let interval = runtime.connectedSince > 0
                ? max(0, Date().timeIntervalSince1970 - Double(runtime.connectedSince))
                : 0
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            let duration = runtime.connectedSince > 0 ? formatter.string(from: interval) ?? "—" : "—"
            menu.addItem(disabledItem("\(localized("Connected", "连接时长")): \(duration)",
                                      symbol: "clock"))
        } else if let address = snapshot.ipAddress {
            menu.addItem(disabledItem("\(localized("Device", "设备")): Android",
                                      symbol: "iphone"))
            menu.addItem(disabledItem("IP: \(address)", symbol: "globe"))
        } else {
            menu.addItem(disabledItem("\(localized("Device", "设备")): \(localized("No device", "未连接设备"))",
                                      symbol: "iphone"))
            menu.addItem(disabledItem("↓ 0 bytes    ↑ 0 bytes", symbol: "arrow.up.arrow.down"))
            menu.addItem(disabledItem("\(localized("Connected", "连接时长")): —", symbol: "clock"))
        }

        menu.addItem(.separator())
        menu.addItem(connectionSwitchItem())
        menu.addItem(launchAtLoginSwitchItem())

        var detailRows: [DetailRow] = [.init(title: "", symbol: "", kind: .separator)]
        if let runtime = snapshot.runtime {
            let interface = runtime.hostInterface.isEmpty ? "feth99" : runtime.hostInterface
            let address = snapshot.ipAddress ?? localized("configuring…", "配置中…")
            detailRows.append(.init(title: "IP: \(address)", symbol: "globe", kind: .text))
            detailRows.append(.init(title: "\(localized("Interface", "接口")): \(interface)",
                                    symbol: "network",
                                    kind: .text))
            if !runtime.deviceAddress.isEmpty {
                detailRows.append(.init(title: "MAC: \(runtime.deviceAddress)",
                                        symbol: "number",
                                        kind: .text))
            }
            detailRows.append(.init(title: "PID: \(runtime.processID)",
                                    symbol: "gearshape",
                                    kind: .text))
            if !runtime.detail.isEmpty {
                detailRows.append(.init(title: runtime.detail,
                                        symbol: "text.bubble",
                                        kind: .text))
            }
        }
        if let interfaceError {
            detailRows.append(.init(title: interfaceError,
                                    symbol: "exclamationmark.triangle",
                                    kind: .text))
        }
        detailRows.append(.init(title: "", symbol: "", kind: .separator))
        detailRows.append(.init(title: localized("Copy Diagnostics", "复制诊断信息"),
                                symbol: "doc.on.doc",
                                kind: .action(#selector(copyDiagnostics))))
        detailRows.append(.init(title: localized("Open Service Log", "打开服务日志"),
                                symbol: "doc.text",
                                kind: .action(#selector(openLog))))
        detailRows.append(.init(title: localized("Open Project Page", "打开项目主页"),
                                symbol: "safari",
                                kind: .action(#selector(openProject))))

        let detailItem = NSMenuItem()
        let detailView = AnimatedDetailsView(
            collapsedTitle: localized("Show Details", "显示详细信息"),
            expandedTitle: localized("Hide Details", "收起详细信息"),
            expanded: showDetails,
            rows: detailRows,
            target: self,
            symbolImage: symbolImage
        ) { [weak self] expanded in
            self?.showDetails = expanded
            UserDefaults.standard.set(expanded, forKey: "showDetails")
        }
        detailsView = detailView
        detailItem.view = detailView
        menu.addItem(detailItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(localized("Quit HoRNDIS Status", "退出 HoRNDIS 状态栏"),
                                symbol: "xmark.circle",
                                action: #selector(quit),
                                keyEquivalent: "q"))
        if statusItem.menu !== menu {
            statusItem.menu = menu
        }
    }

    @objc private func setConnection(_ sender: NSSwitch) {
        let requestedState = sender.state == .on
        pendingConnectionState = requestedState
        pendingConnectionStartedAt = Date()
        updateStatusItem()
        do {
            try ControlClient.send(requestedState ? "connect\n" : "disconnect\n")
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
            showDetails = true
            pendingConnectionState = nil
            pendingConnectionStartedAt = nil
            sender.state = requestedState ? .off : .on
            detailsView?.setExpanded(true, animated: true)
            updateStatusItem()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
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

    @objc private func setLaunchAtLogin(_ sender: NSSwitch) {
        let shouldInstall = sender.state == .on
        do {
            if shouldInstall {
                try LaunchAgentManager.writeConfiguration()
            } else {
                try LaunchAgentManager.removeConfiguration()
            }
            interfaceError = nil
        } catch {
            interfaceError = error.localizedDescription
            sender.state = shouldInstall ? .off : .on
            showDetails = true
            detailsView?.setExpanded(true, animated: true)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        snapshot = readSnapshot()
        updateStatusItem()
        updateMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
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
        case "uninstall":
            try LaunchAgentManager.uninstall()
            print("HoRNDIS menu bar status stopped and removed.")
        case "--version", "version":
            print("horndis-status \(horndisStatusVersion)")
        case "--help", "help":
            print("""
            Usage:
              horndis-status             Run the menu bar status app
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

if !handleCommandLine() {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = StatusAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
