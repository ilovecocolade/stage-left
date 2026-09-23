// Draws the Stagehand icon and writes Resources/AppIcon.icns and docs/logo.png.
//
//   swift Tools/make-icon.swift
//
// The idea: one window in the spotlight, the rest waiting in the wings — which
// is what a stagehand looks after, one screen at a time.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's icon body is a superellipse rather than a rounded rectangle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Draws on a 1024-point canvas, y up.
func drawIcon() {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Backdrop: a theatre at night.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x7B5CFF), color(0x3A2A9E), color(0x160F3D)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)

    // The spotlight, falling from the top onto the stage.
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: 560, y: 924))
    beam.line(to: NSPoint(x: 660, y: 924))
    beam.line(to: NSPoint(x: 870, y: 262))
    beam.line(to: NSPoint(x: 350, y: 262))
    beam.close()
    NSGraphicsContext.current?.saveGraphicsState()
    beam.addClip()
    // Fades to nothing before its lower edge, so the beam has no visible end.
    NSGradient(colors: [color(0xFFFFFF, 0.34), color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)],
               atLocations: [0, 0.7, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: 300, y: 262, width: 620, height: 662), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Where the light lands: a soft pool, no edge.
    NSGradient(colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0.07), color(0xFFFFFF, 0)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: NSBezierPath(ovalIn: CGRect(x: 318, y: 210, width: 584, height: 104)),
              relativeCenterPosition: .zero)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The window on stage.
    let window = CGRect(x: 398, y: 318, width: 420, height: 372)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x0B0726, 0.55)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 34
    shadow.set()
    color(0xFFFFFF).setFill()
    rounded(window, 46).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [color(0xFFFFFF), color(0xECE8FF)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: rounded(window, 46), angle: -90)
    // Title bar.
    NSGraphicsContext.current?.saveGraphicsState()
    rounded(window, 46).addClip()
    color(0xD9D1FF).setFill()
    CGRect(x: window.minX, y: window.maxY - 74, width: window.width, height: 74).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    for (i, hex) in [0xFF6B6B, 0xFFC24B, 0x4CD787].enumerated() {
        color(UInt32(hex)).setFill()
        NSBezierPath(ovalIn: CGRect(x: window.minX + 36 + CGFloat(i) * 38, y: window.maxY - 50, width: 24, height: 24)).fill()
    }

    // The windows waiting in the wings.
    let tile = CGSize(width: 118, height: 100)
    let gap: CGFloat = 26
    let total = tile.height * 3 + gap * 2
    for i in 0..<3 {
        let y = window.midY + total / 2 - tile.height - CGFloat(i) * (tile.height + gap)
        let frame = CGRect(x: 214, y: y, width: tile.width, height: tile.height)
        let fade = 0.62 - CGFloat(i) * 0.14
        color(0xFFFFFF, fade * 0.55).setFill()
        rounded(frame, 28).fill()
        color(0xFFFFFF, fade).setFill()
        rounded(frame.insetBy(dx: 18, dy: 18), 12).fill()
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    NSAffineTransform().then { $0.scale(by: scale); $0.concat() }
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return strippingMetadata(rep.representation(using: .png, properties: [:])!)
}

/// Keeps only the chunks needed to draw the image. AppKit adds an EXIF block,
/// and a published image should carry nothing it does not need.
func strippingMetadata(_ png: Data) -> Data {
    let keep: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "IDAT", "IEND"]
    var out = png.prefix(8)
    var offset = 8
    while offset + 12 <= png.count {
        let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        let end = offset + 12 + length
        if keep.contains(type) { out.append(png[offset..<end]) }
        offset = end
    }
    return Data(out)
}

extension NSAffineTransform {
    func then(_ body: (NSAffineTransform) -> Void) { body(self) }
}

// Write the .icns container directly rather than through iconutil, which
// re-encodes every image and adds its own metadata back.
let entries: [(type: String, pixels: Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]

func bigEndian(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}

var body = Data()
var rendered: [Int: Data] = [:]
for entry in entries {
    let image = rendered[entry.pixels] ?? png(pixels: entry.pixels)
    rendered[entry.pixels] = image
    body.append(Data(entry.type.utf8))
    body.append(bigEndian(image.count + 8))
    body.append(image)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(body.count + 8))
icns.append(body)

try! icns.write(to: root.appendingPathComponent("Resources/AppIcon.icns"))
try! rendered[1024]!.write(to: root.appendingPathComponent("docs/logo.png"))
print("wrote Resources/AppIcon.icns and docs/logo.png")
