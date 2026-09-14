// Masks a square PNG into the macOS app-icon shape: the artwork is scaled into the standard
// icon area (824 of 1024 px, i.e. a 100 px transparent margin on each side) and clipped to a
// rounded rectangle whose corner radius is ~22.4% of that area, matching Apple's icon grid.
//
//   swiftc -O Scripts/round-icon.swift -o build/round-icon && build/round-icon in.png out.png [size]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: round-icon <in.png> <out.png> [size=1024]\n".data(using: .utf8)!)
    exit(1)
}
let size = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
let inset = CGFloat(size) * 100.0 / 1024.0          // Apple's grid: 100 px margin at 1024
let area = CGFloat(size) - inset * 2
let radius = area * 0.2237                          // ~185 px at 824

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
let frame = NSRect(x: inset, y: inset, width: area, height: area)
NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
do { try png.write(to: URL(fileURLWithPath: args[2])) } catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); exit(3) }
