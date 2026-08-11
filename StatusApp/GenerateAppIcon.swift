// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

private struct IconRendition {
    let filename: String
    let pixels: Int
}

private let renditions = [
    IconRendition(filename: "icon_16x16.png", pixels: 16),
    IconRendition(filename: "icon_16x16@2x.png", pixels: 32),
    IconRendition(filename: "icon_32x32.png", pixels: 32),
    IconRendition(filename: "icon_32x32@2x.png", pixels: 64),
    IconRendition(filename: "icon_128x128.png", pixels: 128),
    IconRendition(filename: "icon_128x128@2x.png", pixels: 256),
    IconRendition(filename: "icon_256x256.png", pixels: 256),
    IconRendition(filename: "icon_256x256@2x.png", pixels: 512),
    IconRendition(filename: "icon_512x512.png", pixels: 512),
    IconRendition(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                  xRadius: 220,
                                  yRadius: 220)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 44
    shadow.shadowOffset = NSSize(width: 0, height: -22)
    shadow.set()
    NSColor(calibratedRed: 0.04, green: 0.30, blue: 0.78, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.96, alpha: 1), 0),
        (NSColor(calibratedRed: 0.04, green: 0.76, blue: 0.78, alpha: 1), 1)
    )!
    gradient.draw(in: background, angle: 90)

    // A rounded H doubles as a simple network bridge: two endpoints joined by
    // a central data path. The broad silhouette remains legible at 16 points.
    let leftEndpoint = NSBezierPath(roundedRect: NSRect(x: 238, y: 248, width: 184, height: 528),
                                    xRadius: 92,
                                    yRadius: 92)
    let rightEndpoint = NSBezierPath(roundedRect: NSRect(x: 602, y: 248, width: 184, height: 528),
                                     xRadius: 92,
                                     yRadius: 92)
    let bridge = NSBezierPath(roundedRect: NSRect(x: 350, y: 418, width: 324, height: 188),
                              xRadius: 94,
                              yRadius: 94)

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(calibratedRed: 0.0, green: 0.20, blue: 0.50, alpha: 0.25)
    glyphShadow.shadowBlurRadius = 20
    glyphShadow.shadowOffset = NSSize(width: 0, height: -10)
    glyphShadow.set()
    NSColor.white.withAlphaComponent(0.96).setFill()
    leftEndpoint.fill()
    rightEndpoint.fill()
    bridge.fill()
    NSGraphicsContext.restoreGraphicsState()

    let leftPort = NSBezierPath(ovalIn: NSRect(x: 294, y: 476, width: 72, height: 72))
    let rightPort = NSBezierPath(ovalIn: NSRect(x: 658, y: 476, width: 72, height: 72))
    NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.88, alpha: 1).setFill()
    leftPort.fill()
    rightPort.fill()
}

private func writeRendition(_ rendition: IconRendition, to directory: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: rendition.pixels,
                                        pixelsHigh: rendition.pixels,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "HoRNDISIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create icon bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let scale = CGFloat(rendition.pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "HoRNDISIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot encode icon PNG"])
    }
    try data.write(to: directory.appendingPathComponent(rendition.filename), options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: GenerateAppIcon <iconset-directory>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outputDirectory,
                                            withIntermediateDirectories: true)
    for rendition in renditions {
        try writeRendition(rendition, to: outputDirectory)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
