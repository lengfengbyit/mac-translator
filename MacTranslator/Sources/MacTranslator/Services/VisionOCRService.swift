import CoreGraphics
import Foundation
import Vision

/// Local offline OCR using Vision. Recognition runs on a background queue.
///
/// Vision returns observations in detection order, not reading order, and is
/// happy to emit low-confidence CJK garbage. This service reconstructs lines
/// from bounding boxes, drops noise and stitches fragments with sensible
/// spacing before handing the text to the LLM.
final class VisionOCRService {
    struct LineItem {
        let text: String
        let box: CGRect
    }

    func recognize(image: CGImage) async throws -> String {
        let prepared = Self.upscaleForRecognition(image)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
                do {
                    try handler.perform([request])
                    let items: [LineItem] = (request.results ?? []).compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first,
                              candidate.confidence >= 0.25 else { return nil }
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return LineItem(text: text, box: observation.boundingBox)
                    }
                    continuation.resume(returning: Self.readingOrder(items))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Vision needs a reasonable pixel density to separate CJK strokes. A
    /// 300 x 40 selection on a Retina display is upscaled before recognition.
    static func upscaleForRecognition(_ image: CGImage) -> CGImage {
        let targetLongest: CGFloat = 1400
        let longest = CGFloat(max(image.width, image.height))
        guard longest > 0, longest < targetLongest else { return image }
        let factor = min(3.0, targetLongest / longest)
        let width = max(1, Int(CGFloat(image.width) * factor))
        let height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Groups observations whose vertical centres are within roughly half a
    /// line height, then sorts each line left-to-right. Lines are joined with
    /// newlines; adjacent CJK fragments are concatenated without a space.
    static func readingOrder(_ items: [LineItem]) -> String {
        guard !items.isEmpty else { return "" }
        let sorted = items.sorted { lhs, rhs in
            let deltaY = lhs.box.midY - rhs.box.midY
            let tolerance = max(lhs.box.height, rhs.box.height) * 0.55
            if abs(deltaY) > tolerance { return deltaY > 0 }
            return lhs.box.minX < rhs.box.minX
        }

        var lines: [[LineItem]] = []
        for item in sorted {
            if let anchor = lines.last?.first,
               abs(anchor.box.midY - item.box.midY)
                    <= max(anchor.box.height, item.box.height) * 0.55 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }

        return lines
            .map { line in line.reduce("") { Self.join($0, $1.text) } }
            .joined(separator: "\n")
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        let leftCJK = lhs.last.map(Self.isCJK) ?? false
        let rightCJK = rhs.first.map(Self.isCJK) ?? false
        return (leftCJK || rightCJK) ? lhs + rhs : lhs + " " + rhs
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}
