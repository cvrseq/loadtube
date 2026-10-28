#!/usr/bin/env swift
import AppKit

// Генерация иконки 1024×1024 для LoadTube.

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon_1024.png"
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Не удалось создать bitmap")
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Не удалось создать графический контекст")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

// Фон — скруглённый квадрат с градиентом
let inset: CGFloat = 64
let backgroundRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 190, yRadius: 190)

if let gradient = NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.29, blue: 0.26, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.62, blue: 0.15, alpha: 1)
]) {
    gradient.draw(in: background, angle: -55)
}

// Белая стрелка вниз
NSColor.white.set()

let shaft = NSBezierPath(
    roundedRect: NSRect(x: 478, y: 470, width: 68, height: 212),
    xRadius: 34,
    yRadius: 34
)
shaft.fill()

let head = NSBezierPath()
head.move(to: NSPoint(x: 396, y: 522))
head.line(to: NSPoint(x: 628, y: 522))
head.line(to: NSPoint(x: 512, y: 318))
head.close()
head.lineJoinStyle = .round
head.fill()

let shelf = NSBezierPath(
    roundedRect: NSRect(x: 380, y: 218, width: 264, height: 46),
    xRadius: 23,
    yRadius: 23
)
shelf.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Не удалось закодировать PNG")
}

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: url)
print("Иконка сохранена: \(outputPath)")
