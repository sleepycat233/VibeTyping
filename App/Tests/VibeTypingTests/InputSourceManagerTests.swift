import Carbon
import XCTest
@testable import VibeTyping

final class InputSourceManagerTests: XCTestCase {
    func testCJKDetectionUsesTypeAndKnownPrefixes() {
        XCTAssertTrue(InputSourceManager.isCJK(
            sourceType: kTISTypeKeyboardInputMode as String,
            sourceID: "unknown"
        ))
        XCTAssertTrue(InputSourceManager.isCJK(
            sourceType: kTISTypeKeyboardLayout as String,
            sourceID: "com.apple.inputmethod.SCIM.ITABC"
        ))
        XCTAssertFalse(InputSourceManager.isCJK(
            sourceType: kTISTypeKeyboardLayout as String,
            sourceID: "com.apple.keylayout.ABC"
        ))
    }
}
