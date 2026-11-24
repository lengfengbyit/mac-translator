import AppKit
import CoreGraphics
import Foundation

extension CGImage {
    /// Scales the image so that its longest edge is at most `maxDimension`, preserving aspect ratio.
    func resized(maxDimension: CGFloat) -> CGImage? {
        let longest = CGFloat(max(width, height))
        guard longest > maxDimension, maxDimension > 0 else { return self }

        let scale = maxDimension / longest
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        let colorSpace = colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// JPEG bytes suitable for an OpenAI-compatible image_url data URI.
    func jpegData(compressionQuality: CGFloat = 0.8) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: self)
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }

    /// Resized + JPEG encoded bytes, capped at 2048 px on the longest edge.
    func multimodalJPEGData(maxDimension: CGFloat = 2048) -> Data? {
        guard let scaled = resized(maxDimension: maxDimension) else { return nil }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
