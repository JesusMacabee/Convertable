import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Embedded-art normalisation: decode anything ImageIO understands, fit within `maxPixels`, re-encode as JPEG.
public enum Artwork {
    public struct Result: Equatable, Sendable { public let data: Data; public let width: Int; public let height: Int; public let mimeType: String }

    public static func downscale(_ data: Data, maxPixels: Int, jpegQuality: Double) -> Result? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Let ImageIO do the scaling while decoding: cheaper than decoding a 3000² PNG fully.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Result(data: out as Data, width: img.width, height: img.height, mimeType: "image/jpeg")
    }

    public static func dimensions(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
