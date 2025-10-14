import BoxCore
import XCTest

final class BoxLoggingTests: XCTestCase {
    func testParseLogTarget() {
        XCTAssertEqual(BoxLogTarget.parse("stderr"), .stderr)
        XCTAssertEqual(BoxLogTarget.parse("stdout"), .stdout)
        XCTAssertEqual(BoxLogTarget.parse("file:/tmp/log.txt"), .file("/tmp/log.txt"))
        XCTAssertNil(BoxLogTarget.parse("invalid"))
        XCTAssertNil(BoxLogTarget.parse("file:"))
    }
}
