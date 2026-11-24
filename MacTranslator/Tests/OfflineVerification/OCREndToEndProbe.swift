import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

// End-to-end probe of the real capture geometry + real Vision pipeline:
// display a window with known text, convert its AppKit frame through
// ScreenCaptureService.displaySpaceRect, capture with ScreenCaptureKit and
// OCR the result with VisionOCRService. No mock objects involved.
//
// Compile with:
//   Sources/MacTranslator/Core/Models/Enums.swift
//   Sources/MacTranslator/Services/ScreenCaptureService.swift
//   Sources/MacTranslator/Services/VisionOCRService.swift

@main
struct OCREndToEndProbe {
    @MainActor
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let frame = NSRect(x: 320, y: 480, width: 560, height: 170)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .white
        window.level = .floating
        let label = NSTextField(labelWithString: "Mac Translator 翻译器")
        label.font = NSFont.boldSystemFont(ofSize: 30)
        label.textColor = .black
        label.frame = NSRect(x: 26, y: 55, width: 510, height: 62)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        window.display()
        _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.8, false)

        let appkitRect = CGRect(
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
        )
        let displayRect = ScreenCaptureService.displaySpaceRect(from: appkitRect)
        print("E1 AppKit rect = \(appkitRect)")
        print("E2 Display rect = \(displayRect)")

        guard #available(macOS 15.2, *) else {
            print("E2E: SKIP (ScreenCaptureKit region capture needs macOS 15.2+)")
            window.close()
            return
        }

        guard let image = try? await SCScreenshotManager.captureImage(in: displayRect) else {
            print("E2E: FAIL (ScreenCaptureKit returned no image)")
            window.close()
            exit(1)
        }
        print("E3 captured \(image.width)x\(image.height) px (Retina scaled)")
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/mt_e2e_capture.png"))
        }

        let text = (try? await VisionOCRService().recognize(image: image)) ?? ""
        print("E4 Vision text = \(text.debugDescription)")
        let recognised = text.contains("Mac") || text.contains("Translator") || text.contains("翻译")
        print("E2E: \(recognised ? "PASS" : "FAIL") — 坐标转换 → 截图 → 阅读顺序 OCR")
        window.close()
        exit(recognised ? 0 : 1)
    }
}
