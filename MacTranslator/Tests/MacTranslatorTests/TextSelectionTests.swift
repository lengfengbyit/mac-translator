import Foundation
import XCTest
@testable import MacTranslator

final class TextSelectionTests: XCTestCase {
    private func service(
        ax: @escaping () -> String? = { nil },
        script: @escaping () async -> String? = { nil },
        clipboard: @escaping () -> String? = { nil },
        now: @escaping () -> Date = Date.init,
        window: TimeInterval = 1.0
    ) -> TextSelectionService {
        TextSelectionService(
            axReader: ax,
            scriptReader: script,
            clipboardReader: clipboard,
            currentTime: now,
            dedupWindow: window
        )
    }

    func testAXResultWinsWithoutClipboardFallback() async {
        let sut = service(
            ax: { "AX 文本" },
            script: { () async -> String? in "脚本文本" },
            clipboard: { "剪贴板文本" }
        )
        let result = await sut.selectText()
        XCTAssertEqual(result.text, "AX 文本")
        XCTAssertEqual(result.usedLevel, .ax)
        XCTAssertFalse(result.usedClipboardFallback)
    }

    func testFallsBackToAppleScriptWhenAXEmpty() async {
        let sut = service(script: { () async -> String? in "浏览器选中文本" })
        let result = await sut.selectText()
        XCTAssertEqual(result.text, "浏览器选中文本")
        XCTAssertEqual(result.usedLevel, .appleScript)
        XCTAssertFalse(result.usedClipboardFallback)
    }

    func testFallsBackToCmdCAndMarksClipboardUsage() async {
        let sut = service(clipboard: { "兜底文本" })
        let result = await sut.selectText()
        XCTAssertEqual(result.text, "兜底文本")
        XCTAssertEqual(result.usedLevel, .cmdC)
        XCTAssertTrue(result.usedClipboardFallback)
    }

    func testBlankTextDoesNotCountAsSelection() async {
        let sut = service(ax: { "   " }, script: { () async -> String? in nil }, clipboard: { "" })
        let result = await sut.selectText()
        XCTAssertTrue(result.isEmpty)
    }

    func testDuplicateSelectionSuppressedWithinWindow() async {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sut = service(ax: { "重复文本" }, now: { fixedDate })

        let first = await sut.selectText()
        let second = await sut.selectText()

        XCTAssertEqual(first.text, "重复文本")
        XCTAssertTrue(second.isEmpty)
    }

    func testDuplicateWindowExpiryAllowsSameTextAgain() async {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ticks = 0
        let sut = service(
            ax: { "同一文本" },
            now: {
                ticks += 1
                return base.addingTimeInterval(Double(ticks) * 2.0)
            }
        )

        let first = await sut.selectText()
        let second = await sut.selectText()
        XCTAssertEqual(first.text, "同一文本")
        XCTAssertEqual(second.text, "同一文本")
    }
}
