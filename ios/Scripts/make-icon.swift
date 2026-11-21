// Makes the iOS app icon (1024 px, full bleed, no alpha) from the Mac
// icon's art: crops the Mac icon's plate to its edges, and paints the
// corners the Mac squircle leaves transparent with the plate's coral
// gradient (iOS masks the corners itself).
//
//   swift ios/Scripts/make-icon.swift Resources/AppIcon.icns ios/Owlink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let icns = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift AppIcon.icns out.png\n".data(using: .utf8)!); exit(2)
}
var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
guard let src = icns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { exit(1) }
let w = src.width, h = src.height
// The plate is the fully opaque part; the Mac icon's drop shadow and
// antialiased squircle edge (alpha < 250) are dropped, so the gradient
// shows through there instead of a dark rim.
let rgba = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rgba.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = rgba.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if px[i + 3] < 250 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0; continue }
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
// CGContext memory rows run top-down for this bitmap.
let crop = rgba.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let n = 1024
let out = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let top = CGColor(red: 0xff / 255.0, green: 0x8d / 255.0, blue: 0x6b / 255.0, alpha: 1)
let bot = CGColor(red: 0xf5 / 255.0, green: 0x6a / 255.0, blue: 0x4b / 255.0, alpha: 1)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bot] as CFArray, locations: [0, 1])!
out.drawLinearGradient(grad, start: CGPoint(x: 0, y: n), end: CGPoint(x: 0, y: 0), options: [])
out.interpolationQuality = .high
out.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) from plate \(maxX - minX + 1)x\(maxY - minY + 1)")
