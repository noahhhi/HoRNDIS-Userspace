import Foundation

@main
private enum MenuUIContractTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2,
                     "usage: menu-ui-contract-tests <HoRNDISStatus.swift>")
        let source = try String(contentsOfFile: CommandLine.arguments[1],
                                encoding: .utf8)

        let requiredFragments = [
            "NSApplicationDelegate, NSMenuDelegate",
            "NSStatusBar.system.statusItem",
            "let menu = NSMenu(title: \"HoRNDIS\")",
            "menu.autoenablesItems = false",
            "private func nativeStateItem",
            "symbol: String? = nil",
            "let item = nativeActionItem(title, action: action)",
            "item.state = .off",
            "connection.state = displayedState ? .on : .off",
            "launchAtLogin.state = LaunchAgentManager.isInstalled ? .on : .off",
            "setPreferredImageVisibility:",
            "item.setValue(1, forKey: \"preferredImageVisibility\")",
            "private func setNativeOffStateImage",
            "item.offStateImage = nativeSymbol(symbol)",
            "usesStateColumn: Bool = false",
            "usesStateColumn: true",
            "let requestedState = sender.state != .on",
            "details.submenu = submenu",
            "private func configureDetailsMenu(_ menu: NSMenu)",
            "summary.deviceAndDurationFormat",
            "authorizationState.warningTitle.map",
            "title: summary.traffic, symbol: \"arrow.up\"",
            "func menuWillOpen(_ menu: NSMenu)",
            "func menuDidClose(_ menu: NSMenu)",
            "func menuNeedsUpdate(_ menu: NSMenu)",
            "Save Diagnostic Report…",
            "Report a Bug…",
            "NSLocalizedString(key,",
            "tableName: \"Localizable\"",
            "Timer(timeInterval: 1,",
            "RunLoop.main.add(refreshTimer, forMode: .eventTracking)",
            "if menuIsOpen && snapshot.state == .connected",
            "ControlClient.send(\"observe\\n\")",
            "LaunchAgentManager.terminateOtherInstances()",
        ]
        for fragment in requiredFragments {
            precondition(source.contains(fragment),
                         "Menu UI contract is missing: \(fragment)")
        }

        let forbiddenFragments = [
            "import SwiftUI",
            "MenuBarExtra",
            "NSPopover",
            "NSHostingView",
            "NSHostingController",
            "NSSwitch",
            "Toggle(",
            "DisclosureGroup",
            ".containerShape(",
            ".allowsHitTesting(false)",
            "NativeMenuSwitchRow",
            "NativeMenuDetailsRow",
            ".view =",
            "menu.minimumWidth",
            "SymbolConfiguration(pointSize:",
            "image?.size = NSSize",
            "item.indentationLevel",
            "UserDefaults.standard.stringArray(forKey: \"AppleLanguages\")",
            "preferredLocalization.hasPrefix(\"zh\")",
            "nativeInfoItem(tag: .duration)",
            "setNativeImage(\"info.circle\", on: details)",
            "symbol: \"personalhotspot\"",
            "symbol: \"power\"",
            "symbol: \"xmark.circle\"",
            "symbol: \"exclamationmark.shield\",\n            action: #selector(authorizeAndInstall)",
        ]
        for fragment in forbiddenFragments {
            precondition(!source.contains(fragment),
                         "Menu UI contract forbids: \(fragment)")
        }

        print("Menu UI source contract passed")
    }
}
