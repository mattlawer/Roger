import AppKit

let outDir = CommandLine.arguments[1]
let entries: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let p = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: p, height: p)
    let inset = p * 0.09
    let r = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.height * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.40, alpha: 1)
    ])!
    gradient.draw(in: path, angle: -65)
    let font = NSFont.systemFont(ofSize: p * 0.58, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let s = NSAttributedString(string: "R", attributes: attrs)
    let ss = s.size()
    s.draw(at: NSPoint(x: (p - ss.width) / 2, y: (p - ss.height) / 2 - p * 0.01))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (size, scale) in entries {
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! render(px: size * scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("Generated \(images.count) icons")
