import XCTest
import SwiftUI
@testable import Minis

/// App 里的字号档叠在系统「更大字体」上，而不是把系统设置盖掉
final class FontScaleStackingTests: XCTestCase {
    func testDefaultFollowsSystem() {
        for size in DynamicTypeSize.allCases {
            XCTAssertEqual(FontScaleLevel.default.dynamicTypeSize(stackedOn: size), size, "默认档应该完全跟系统：\(size)")
        }
    }

    func testSameAsBeforeOnSystemDefault() {
        // 系统是默认字号时，和以前的绝对映射一样
        for level in FontScaleLevel.allCases {
            XCTAssertEqual(level.dynamicTypeSize(stackedOn: .large), level.dynamicTypeSize, "\(level)")
        }
    }

    func testStacksAndClamps() {
        XCTAssertEqual(FontScaleLevel.large.dynamicTypeSize(stackedOn: .xLarge), .xxxLarge)
        XCTAssertEqual(FontScaleLevel.extraLarge.dynamicTypeSize(stackedOn: .accessibility4), .accessibility5)
        XCTAssertEqual(FontScaleLevel.xSmall.dynamicTypeSize(stackedOn: .xSmall), .xSmall)
    }
}
