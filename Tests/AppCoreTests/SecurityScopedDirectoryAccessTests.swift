@testable import EfbyPresentation
import Foundation
import XCTest

final class SecurityScopedDirectoryAccessTests: XCTestCase {
    @MainActor
    func testOrdinaryReadableDirectoryDoesNotRequireSecurityScope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("workspace".utf8).write(to: directory.appendingPathComponent("marker"))
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            stopAccess: { stopped.append($0) }
        ))

        XCTAssertTrue(access.grantAccess(to: directory))
        XCTAssertEqual(access.url, directory)
        XCTAssertFalse(access.hasActiveAccess)
        access.releaseAccess()
        XCTAssertNil(access.url)
        XCTAssertTrue(stopped.isEmpty, "Ordinary access must not release a scope that was never acquired.")
    }

    @MainActor
    func testUnreadableOrdinaryDirectoryDoesNotBecomeConfigured() {
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in throw CocoaError(.fileReadNoPermission) }
        ))

        XCTAssertFalse(access.grantAccess(to: fixtureURL))
        XCTAssertNil(access.url)
        XCTAssertFalse(access.hasActiveAccess)
        XCTAssertTrue(stopped.isEmpty)
    }

    @MainActor
    func testScopedGrantIsReleasedWhenDirectoryReadFails() {
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in true },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in throw CocoaError(.fileReadNoPermission) }
        ))

        XCTAssertFalse(access.grantAccess(to: fixtureURL))
        XCTAssertNil(access.url)
        XCTAssertFalse(access.hasActiveAccess)
        XCTAssertEqual(stopped, [fixtureURL])
        access.releaseAccess()
        XCTAssertEqual(stopped, [fixtureURL])
    }

    @MainActor
    func testRepeatedAccessDoesNotAcquireDuplicateScopeAndReleaseIsBalanced() {
        var starts = 0
        var reads = 0
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in starts += 1; return true },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in reads += 1 }
        ))

        XCTAssertTrue(access.grantAccess(to: fixtureURL))
        XCTAssertTrue(access.grantAccess(to: fixtureURL))
        XCTAssertTrue(access.hasActiveAccess)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(reads, 2)
        access.releaseAccess()
        access.releaseAccess()
        XCTAssertEqual(stopped, [fixtureURL])
        XCTAssertNil(access.url)
        XCTAssertFalse(access.hasActiveAccess)
    }

    @MainActor
    func testOrdinaryAccessIsRevalidatedAndClearedAfterPermissionIsLost() {
        var canRead = true
        var starts = 0
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in starts += 1; return false },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in
                if !canRead { throw CocoaError(.fileReadNoPermission) }
            }
        ))

        XCTAssertTrue(access.grantAccess(to: fixtureURL))
        canRead = false
        XCTAssertFalse(access.grantAccess(to: fixtureURL))
        XCTAssertNil(access.url)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(stopped.isEmpty)
    }

    @MainActor
    func testSwitchingDirectoriesReleasesPreviousScopedGrant() {
        let other = fixtureURL.appendingPathComponent("other")
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in true },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in }
        ))

        XCTAssertTrue(access.grantAccess(to: fixtureURL))
        XCTAssertTrue(access.grantAccess(to: other))
        XCTAssertEqual(stopped, [fixtureURL])
        XCTAssertEqual(access.url, other)
        access.releaseAccess()
        XCTAssertEqual(stopped, [fixtureURL, other])
    }

    @MainActor
    func testStaleBookmarkIsRefreshedAfterDirectoryAccessSucceeds() {
        let refreshedData = Data("new bookmark".utf8)
        var refreshedURLs: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            validateDirectory: { _ in },
            resolveBookmark: { _, _ in .init(url: self.fixtureURL, isStale: true) }
        ))

        let result = access.restore(bookmarkData: Data()) {
            refreshedURLs.append($0)
            return refreshedData
        }
        XCTAssertEqual(result?.url, fixtureURL)
        XCTAssertEqual(result?.isStale, true)
        XCTAssertEqual(result?.refreshedBookmarkData, refreshedData)
        XCTAssertEqual(refreshedURLs, [fixtureURL])
        XCTAssertEqual(access.url, fixtureURL)
        XCTAssertFalse(access.hasActiveAccess)
    }

    @MainActor
    func testDeniedBookmarkDoesNotRefreshOrRetainItsURL() {
        var refreshes = 0
        var stopped: [URL] = []
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in true },
            stopAccess: { stopped.append($0) },
            validateDirectory: { _ in throw CocoaError(.fileReadNoPermission) },
            resolveBookmark: { _, _ in .init(url: self.fixtureURL, isStale: true) }
        ))

        let result = access.restore(bookmarkData: Data()) { _ in
            refreshes += 1
            return Data()
        }
        XCTAssertNil(result)
        XCTAssertNil(access.url)
        XCTAssertFalse(access.hasActiveAccess)
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(stopped, [fixtureURL])
    }

    @MainActor
    func testCurrentBookmarkIsNotRewritten() {
        var refreshes = 0
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            validateDirectory: { _ in },
            resolveBookmark: { _, _ in .init(url: self.fixtureURL, isStale: false) }
        ))

        let result = access.restore(bookmarkData: Data()) { _ in
            refreshes += 1
            return Data()
        }
        XCTAssertEqual(result?.isStale, false)
        XCTAssertNil(result?.refreshedBookmarkData)
        XCTAssertEqual(refreshes, 0)
    }

    #if os(macOS)
    @MainActor
    func testLegacyPlainBookmarkCanBeResolvedAndRenewedWithoutBypassingFilePermissions() {
        var optionsUsed: [URL.BookmarkResolutionOptions] = []
        var refreshes = 0
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            validateDirectory: { _ in },
            resolveBookmark: { _, options in
                optionsUsed.append(options)
                if options.contains(.withSecurityScope) { throw CocoaError(.fileReadCorruptFile) }
                return .init(url: self.fixtureURL, isStale: false)
            }
        ))

        let refreshed = Data("renewed legacy bookmark".utf8)
        let result = access.restore(bookmarkData: Data()) { _ in
            refreshes += 1
            return refreshed
        }
        XCTAssertEqual(optionsUsed, [[.withSecurityScope, .withoutUI], [.withoutUI]])
        XCTAssertEqual(result?.url, fixtureURL)
        XCTAssertEqual(result?.isStale, false)
        XCTAssertEqual(result?.refreshedBookmarkData, refreshed)
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(access.hasActiveAccess)
    }

    @MainActor
    func testLegacyPlainResolutionStillRejectsDirectoryWithoutPermission() {
        var refreshes = 0
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in false },
            validateDirectory: { _ in throw CocoaError(.fileReadNoPermission) },
            resolveBookmark: { _, options in
                if options.contains(.withSecurityScope) { throw CocoaError(.fileReadCorruptFile) }
                return .init(url: self.fixtureURL, isStale: false)
            }
        ))

        XCTAssertNil(access.restore(bookmarkData: Data()) { _ in refreshes += 1; return Data() })
        XCTAssertNil(access.url)
        XCTAssertFalse(access.hasActiveAccess)
        XCTAssertEqual(refreshes, 0)
    }
    #endif

    @MainActor
    func testCorruptBookmarkDoesNotAcquireAccessOrRemainConfigured() {
        var starts = 0
        var access = SecurityScopedDirectoryAccess(operations: .init(
            startAccess: { _ in starts += 1; return false },
            resolveBookmark: { _, _ in throw CocoaError(.fileReadCorruptFile) }
        ))

        XCTAssertNil(access.restore(bookmarkData: Data()) { _ in XCTFail("Cannot refresh a corrupt bookmark"); return nil })
        XCTAssertEqual(starts, 0)
        XCTAssertNil(access.url)
    }

    @MainActor
    func testPlainBookmarkRestoresRealExistingDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmark = try directory.bookmarkData()
        let bookmarkMaker = SecurityScopedDirectoryAccess()
        var access = SecurityScopedDirectoryAccess()
        defer { access.releaseAccess() }

        let result = access.restore(bookmarkData: bookmark) { bookmarkMaker.makeBookmarkData(for: $0) }
        XCTAssertEqual(result?.url.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertEqual(access.url?.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
    }

    @MainActor
    func testRegularFileCannotBeUsedAsDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        try Data().write(to: file)
        var access = SecurityScopedDirectoryAccess(operations: .init(startAccess: { _ in false }))

        XCTAssertFalse(access.grantAccess(to: file))
        XCTAssertNil(access.url)
    }

    private var fixtureURL: URL { URL(fileURLWithPath: "/tmp/efby-access-tests", isDirectory: true) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("efby-access-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
