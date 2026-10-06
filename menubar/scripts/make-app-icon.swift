// 生成 Resources/AppIcon.icns（程序坞 / 通知横幅 / 访达里显示的应用图标）。
// 用法：cd menubar && swift scripts/make-app-icon.swift && iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
// 图形全部手画（深色圆角底 + 「>_」提示符），不用 SF Symbols——它的许可不允许用在应用图标里。
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS 图标网格：1024 画布里主体 824，四周留 100
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke()
    shape.lineWidth = max(1, s * 6 / 1024)
    shape.stroke()

    let w = s * 78 / 1024
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: s * 300 / 1024, y: s * 650 / 1024))
    chevron.line(to: NSPoint(x: s * 470 / 1024, y: s * 512 / 1024))
    chevron.line(to: NSPoint(x: s * 300 / 1024, y: s * 374 / 1024))
    chevron.lineWidth = w
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()

    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: s * 540 / 1024, y: s * 374 / 1024))
    cursor.line(to: NSPoint(x: s * 730 / 1024, y: s * 374 / 1024))
    cursor.lineWidth = w
    cursor.lineCapStyle = .round
    NSColor(srgbRed: 0.24, green: 0.86, blue: 0.59, alpha: 1).setStroke()
    cursor.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: ".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(dir.path)")
