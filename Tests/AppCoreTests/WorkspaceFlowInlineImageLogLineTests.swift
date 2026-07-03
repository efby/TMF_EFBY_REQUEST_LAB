import EfbyPresentation
import Foundation
import XCTest

final class WorkspaceFlowInlineImageLogLineTests: XCTestCase {
    func testEncodeParse_roundTrip() {
        let url = URL(fileURLWithPath: "/tmp/test-qr.png")
        let line = WorkspaceFlowInlineImageLogLine.encode(fileURL: url, caption: "QR (pm.generarqr)")
        let parsed = WorkspaceFlowInlineImageLogLine.parse(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.fileURL.path, url.path)
        XCTAssertEqual(parsed?.caption, "QR (pm.generarqr)")
    }

    func testVisualKind_classifiesMarkerLine() {
        let url = URL(fileURLWithPath: "/var/tmp/x.png")
        let line = WorkspaceFlowInlineImageLogLine.encode(fileURL: url, caption: "x")
        let kind = WorkspaceFlowRunLogClassifier.visualKind(for: line)
        XCTAssertEqual(kind, .inlineImage)
    }

    func testParse_rejectsNonFileURL() {
        let line = "\(WorkspaceFlowInlineImageLogLine.markerPrefix)\thttps://example.com/a.png\tcap"
        XCTAssertNil(WorkspaceFlowInlineImageLogLine.parse(line))
    }
}
