import AppKit
import SwiftUI

@main
struct StatusSwitchAppearanceProbe {
    static func main() {
        precondition(CommandLine.arguments.count == 2,
                     "usage: status-switch-appearance-probe <output.png>")
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        // The production MenuBarExtra supplies an active control environment.
        // Render the same native switch without a custom tint or drawing code.
        let content = VStack {
            Toggle("", isOn: .constant(true))
                .labelsHidden()
                .toggleStyle(.switch)
                .environment(\.controlActiveState, .key)
                .environment(\.appearsActive, true)
                .controlSize(.mini)
                .fixedSize()
                .padding(8)
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame.size = hostingView.fittingSize
        hostingView.layoutSubtreeIfNeeded()

        let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)!
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        let bitmap = NSBitmapImageRep(data: png)!
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)!
        var closestDistance = Double.greatestFiniteMagnitude
        var closestColor = NSColor.clear
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let distance = pow(color.redComponent - accent.redComponent, 2) +
                    pow(color.greenComponent - accent.greenComponent, 2) +
                    pow(color.blueComponent - accent.blueComponent, 2)
                if distance < closestDistance {
                    closestDistance = distance
                    closestColor = color
                }
            }
        }
        print("size=\(hostingView.frame.size.width)x\(hostingView.frame.size.height)")
        print("accent=\(accent)")
        print("closest=\(closestColor)")
        print("distance=\(closestDistance)")
        precondition(closestDistance < 0.02, "Rendered switch does not contain the system accent color")
    }
}
