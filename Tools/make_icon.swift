// Builds AppIcon.icns from Icon/mangoclass.png.
// Crops to the "I HATE SCHOOL" text plus the head, then centers that on Apple's
// standard rounded-square icon grid (824pt body inside a 1024pt canvas).
//
//   swift Tools/make_icon.swift
//
import Foundation
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Icon/mangoclass.png")
let iconsetURL = root.appendingPathComponent("Icon/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Icon/AppIcon.icns")

guard let data = try? Data(contentsOf: sourceURL),
      let rep = NSBitmapImageRep(data: data),
      let full = rep.cgImage else {
    FileHandle.standardError.write(Data("could not read \(sourceURL.path)\n".utf8))
    exit(1)
}

// Region of the drawing we want: text on top, head below, cut at the neck.
// Measured from the ink bounding box (x 43...2399, text starts y 710) with a
// small bleed; y 2560 is just past where the jaw narrows into the shoulders.
let cropRect = CGRect(x: 33, y: 700, width: 2377, height: 1860)
guard let art = full.cropping(to: cropRect) else { exit(1) }

// Apple's icon grid.
let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100          // 824pt body centered in 1024pt canvas
let bodySize = canvas - bodyInset * 2
let cornerRadius: CGFloat = 185.4
let artPadding: CGFloat = 24          // breathing room inside the rounded square

func renderMaster() -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    let body = CGRect(x: bodyInset, y: bodyInset, width: bodySize, height: bodySize)
    let rounded = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // White squircle behind the artwork.
    ctx.addPath(rounded)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()

    // Clip so nothing spills past the rounded corners.
    ctx.addPath(rounded)
    ctx.clip()

    // Fit the artwork into the padded body, preserving aspect ratio.
    let available = bodySize - artPadding * 2
    let aspect = CGFloat(art.width) / CGFloat(art.height)
    var drawW = available
    var drawH = drawW / aspect
    if drawH > available {
        drawH = available
        drawW = drawH * aspect
    }
    let drawRect = CGRect(x: (canvas - drawW) / 2, y: (canvas - drawH) / 2, width: drawW, height: drawH)
    ctx.draw(art, in: drawRect)

    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let master = renderMaster()

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// (point size, scale) pairs macOS expects in an .iconset.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    write(scaled(master, to: pixels), to: iconsetURL.appendingPathComponent(name))
}

// Keep a full-size PNG around for previews / anywhere an .icns isn't wanted.
write(master, to: root.appendingPathComponent("Icon/AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("Wrote \(icnsURL.path)")
