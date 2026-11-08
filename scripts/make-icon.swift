import AppKit

// 生成 App 图标：蓝色渐变圆角底 + 白色衣架。
// 用法：swift scripts/make-icon.swift <输出.png>
// 为什么自己画：原项目的名称和图标不在 MIT 许可范围内，fork 必须自备。

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 图标惯例：四周留白，圆角约为边长的 22%
let inset: CGFloat = 96
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.22
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 渐变底：上浅下深，像被光照着
if let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.60, blue: 0.96, alpha: 1),
    NSColor(srgbRed: 0.22, green: 0.34, blue: 0.72, alpha: 1),
]) {
    gradient.draw(in: path, angle: -90)
}

// 一层很淡的内高光，让它有点立体感
NSColor(white: 1, alpha: 0.12).setStroke()
path.lineWidth = 6
path.stroke()

// 白色衣架
let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "hanger", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(at: NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2),
                from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

// 写成 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("图标生成失败")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("图标已生成：\(output)")
