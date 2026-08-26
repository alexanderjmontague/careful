import AppKit

// Renders Careful.icns. The mark is a padlock on a lime squircle, matching the
// lock glyph used in the menu bar.
func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Full-bleed. macOS 26 masks legacy .icns with its own squircle, so leaving a
    // margin here produces a squircle nested inside another squircle. Filling the
    // canvas lets the system mask supply the single, correct shape.
    let inset: CGFloat = 0
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237   // Apple's squircle-ish corner ratio
    let platePath = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    platePath.addClip()
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.812, green: 0.961, blue: 0.286, alpha: 1),  // #CFF549
            NSColor(calibratedRed: 0.537, green: 0.784, blue: 0.098, alpha: 1),  // #89C819
        ]
    )!
    gradient.draw(in: plate, angle: -90)
    ctx.restoreGState()

    // A hairline top highlight keeps it from looking flat at large sizes.
    ctx.saveGState()
    platePath.addClip()
    NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
    let rim = NSBezierPath(
        roundedRect: plate.insetBy(dx: s * 0.006, dy: s * 0.006),
        xRadius: radius, yRadius: radius
    )
    rim.lineWidth = max(1, s * 0.006)
    rim.stroke()
    ctx.restoreGState()

    // Near-black with a green cast, so the lock stays legible on lime at 16px.
    let ink = NSColor(calibratedRed: 0.078, green: 0.114, blue: 0.031, alpha: 1)
    ink.setFill()
    ink.setStroke()

    let R = plate.width
    let cx = plate.midX
    let bodyW = R * 0.50, bodyH = R * 0.33
    let bodyY = plate.minY + R * 0.215
    let body = CGRect(x: cx - bodyW / 2, y: bodyY, width: bodyW, height: bodyH)
    NSBezierPath(roundedRect: body, xRadius: R * 0.055, yRadius: R * 0.055).fill()

    // Shackle: two legs joined by a half-circle, stroked with round caps.
    let shackleR = R * 0.125
    let legTop = body.maxY + R * 0.085
    let shackle = NSBezierPath()
    shackle.move(to: CGPoint(x: cx - shackleR, y: body.maxY + R * 0.004))
    shackle.line(to: CGPoint(x: cx - shackleR, y: legTop))
    // clockwise: true sweeps 180 -> 90 -> 0, the upper half. The other direction
    // draws the arc below the centre and the lock reads as a vest.
    shackle.appendArc(
        withCenter: CGPoint(x: cx, y: legTop),
        radius: shackleR, startAngle: 180, endAngle: 0, clockwise: true
    )
    shackle.line(to: CGPoint(x: cx + shackleR, y: body.maxY + R * 0.004))
    shackle.lineWidth = R * 0.062
    shackle.lineCapStyle = .round
    shackle.lineJoinStyle = .round
    shackle.stroke()

    // Keyhole, punched out of the body.
    ctx.saveGState()
    ctx.setBlendMode(.destinationOut)
    NSColor.black.setFill()
    let keyR = R * 0.040
    let keyCenter = CGPoint(x: cx, y: body.midY + R * 0.025)
    NSBezierPath(ovalIn: CGRect(
        x: keyCenter.x - keyR, y: keyCenter.y - keyR, width: keyR * 2, height: keyR * 2
    )).fill()
    NSBezierPath(rect: CGRect(
        x: cx - keyR * 0.52, y: body.minY + R * 0.052,
        width: keyR * 1.04, height: keyCenter.y - (body.minY + R * 0.052)
    )).fill()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let plan: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in plan {
    try! render(size: size).write(to: URL(fileURLWithPath: iconset + "/" + name))
}
print("rendered \(plan.count) sizes")
