import Foundation

@main
private enum MenuUIContractTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2,
                     "usage: menu-ui-contract-tests <HoRNDISStatus.swift>")
        let source = try String(contentsOfFile: CommandLine.arguments[1],
                                encoding: .utf8)

        func metric(_ name: String) -> Double {
            let pattern = "static let \(name): CGFloat = ([0-9.]+)"
            let expression = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            guard let match = expression.firstMatch(in: source, range: range),
                  let valueRange = Range(match.range(at: 1), in: source),
                  let value = Double(source[valueRange]) else {
                fatalError("Cannot read menu metric: \(name)")
            }
            return value
        }

        let requiredFragments = [
            "static let width: CGFloat = 286",
            "static let rowHeight: CGFloat = 32",
            "static let selectionInset: CGFloat = 5",
            "static let selectionVerticalInset: CGFloat = 4",
            "static let selectionContentHorizontalInset: CGFloat = 7",
            "static let selectionCornerRadius: CGFloat = 8",
            "HStack(spacing: 10)",
            ".frame(width: 16)",
            "Toggle(title, isOn: $isOn)",
            ".toggleStyle(.switch)",
            "StatusPopoverDisclosureStyle",
            ".smooth(duration: 0.22, extraBounce: 0)",
            ".spring().speed(1.6)",
            ".padding(.bottom, 1)",
            "MenuBarExtra",
            ".menuBarExtraStyle(.window)",
            "UserDefaults.standard.stringArray(forKey: \"AppleLanguages\")",
            "Timer(timeInterval: 1,",
            "RunLoop.main.add(refreshTimer, forMode: .eventTracking)",
            "if menuIsOpen && snapshot.state == .connected",
            "ControlClient.send(\"observe\\n\")",
        ]
        for fragment in requiredFragments {
            precondition(source.contains(fragment),
                         "Menu UI contract is missing: \(fragment)")
        }

        let forbiddenFragments = [
            ".containerShape(",
            ".allowsHitTesting(false)",
            "NativeMenuSwitchRow",
            "NativeMenuDetailsRow",
        ]
        for fragment in forbiddenFragments {
            precondition(!source.contains(fragment),
                         "Menu UI contract forbids: \(fragment)")
        }

        precondition(metric("selectionInset") +
            metric("selectionContentHorizontalInset") == 12,
            "Interactive rows must share the 12 pt icon column")
        precondition(metric("rowHeight") -
            2 * metric("selectionVerticalInset") == 24,
            "Interactive selections must remain 24 pt high")
        precondition(metric("selectionCornerRadius") == 8,
            "Selection radius must match the native menu selection curve")

        print("Menu UI source contract passed")
    }
}
