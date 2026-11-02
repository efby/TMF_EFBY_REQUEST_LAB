import Foundation

/// Keeps one usable directory URL, balancing security-scoped access when required.
@MainActor
struct SecurityScopedDirectoryAccess {
    struct ResolvedBookmark {
        var url: URL
        var isStale: Bool
    }

    /// The operating system remains the authority for ordinary and scoped access.
    /// These operations also let tests exercise denial without changing OS permissions.
    struct Operations {
        var startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var validateDirectory: (URL) throws -> Void = { url in
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        var resolveBookmark: (Data, URL.BookmarkResolutionOptions) throws -> ResolvedBookmark = { data, options in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        }
    }

    private let operations: Operations
    /// Set only after an actual directory read succeeds, with or without a scope.
    private(set) var url: URL?
    /// Tracks only successful scope acquisitions, not ordinary directory access.
    private(set) var hasActiveAccess = false

    init(operations: Operations = Operations()) {
        self.operations = operations
    }

    mutating func grantAccess(to url: URL) -> Bool {
        if self.url == url {
            do {
                try operations.validateDirectory(url)
                return true
            } catch {
                releaseAccess()
                return false
            }
        }

        releaseAccess()
        let acquiredScope = operations.startAccess(url)
        do {
            try operations.validateDirectory(url)
        } catch {
            if acquiredScope { operations.stopAccess(url) }
            return false
        }

        self.url = url
        hasActiveAccess = acquiredScope
        return true
    }

    mutating func releaseAccess() {
        if hasActiveAccess, let url {
            operations.stopAccess(url)
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
        do {
            let resolved: ResolvedBookmark
            var usedPlainResolution = false
            #if os(macOS)
            do {
                resolved = try operations.resolveBookmark(bookmarkData, [.withSecurityScope, .withoutUI])
            } catch {
                // Older releases may have stored an ordinary bookmark, or its
                // scoped portion may no longer apply to the updated application.
                // Resolving a location alone never grants access to that location.
                resolved = try operations.resolveBookmark(bookmarkData, [.withoutUI])
                usedPlainResolution = true
            }
            #else
            resolved = try operations.resolveBookmark(bookmarkData, [.withoutUI])
            #endif

            guard grantAccess(to: resolved.url) else { return nil }

            let refreshedBookmarkData = resolved.isStale || usedPlainResolution
                ? refreshStaleBookmark(resolved.url) : nil
            return RestoreResult(
                url: resolved.url,
                isStale: resolved.isStale,
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
