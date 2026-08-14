#!/usr/bin/env swift
// Готовит все размеры macOS из мастер-логотипа. Белое поле исходного рендера
// намеренно отсекается, а углы становятся настоящими прозрачными пикселями.

import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.iconset"
let masterPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "./Resources/AppIcon-master.png"

guard let master = NSImage(contentsOfFile: masterPath) else {
    FileHandle.standardError.write(Data("Не найден мастер логотипа: \(masterPath)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setShouldAntialias(true)

    // Скруглённый квадрат в пропорциях macOS: поле по краям и радиус ≈ 22%.
    let inset = side * 0.08
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let path = CGPath(roundedRect: rect,
                      cornerWidth: rect.width * 0.235,
                      cornerHeight: rect.width * 0.235,
                      transform: nil)

    context.saveGState()
    context.addPath(path)
    context.clip()

    // Генератор оставил около 5% белого монтажного поля. Берём только саму
    // тёмную плитку и масштабируем её внутрь системного силуэта macOS.
    let crop = min(master.size.width, master.size.height) * 0.052
    let source = NSRect(x: crop, y: crop,
                        width: master.size.width - crop * 2,
                        height: master.size.height - crop * 2)
    master.draw(in: rect, from: source, operation: .copy, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    context.restoreGState()

    guard let cgImage = context.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

// Набор размеров, который ожидает iconutil.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write(Data("Не удалось отрисовать \(variant.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    try data.write(to: url)
}

print("Иконка собрана: \(variants.count) размеров в \(outputDirectory)")
