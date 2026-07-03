import Foundation

/// Keeps a single security-scoped directory grant alive for macOS sandboxed file access.
@MainActor
struct SecurityScopedDirectoryAccess {
    private(set) var url: URL?
    private(set) var hasActiveAccess = false

    mutating func grantAccess(to url: URL) -> Bool {
        if self.url?.path == url.path, hasActiveAccess {
            return true
        }

        releaseAccess()
        let granted = url.startAccessingSecurityScopedResource()
        self.url = url
        hasActiveAccess = granted
        return granted
    }

    mutating func releaseAccess() {
        if hasActiveAccess, let url {
            url.stopAccessingSecurityScopedResource()
        }
        url = nil
        hasActiveAccess = false
    }

    struct RestoreResult {
        var url: URL
        var isStale: Bool
        var refreshedBookmarkData: Data?
    }

    mutating func restore(
        bookmarkData: Data,
        refreshStaleBookmark: (URL) -> Data?
    ) -> RestoreResult? {
        var isStale = false

        do {
            #if os(macOS)
            let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let resolveOptions: URL.BookmarkResolutionOptions = [.withoutUI]
            #endif

            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: resolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            guard grantAccess(to: resolvedURL) else {
                releaseAccess()
                return nil
            }

            let refreshedBookmarkData = isStale ? refreshStaleBookmark(resolvedURL) : nil
            return RestoreResult(
                url: resolvedURL,
                isStale: isStale,
                refreshedBookmarkData: refreshedBookmarkData
            )
        } catch {
            releaseAccess()
            return nil
        }
    }

    func makeBookmarkData(for url: URL) -> Data? {
        do {
            #if os(macOS)
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            return try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
        } catch {
            return try? url.bookmarkData()
        }
    }
}
