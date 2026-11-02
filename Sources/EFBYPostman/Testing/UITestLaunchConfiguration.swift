#if DEBUG
import EfbyPresentation
import Foundation

/// Only the explicit debug launch mode uses these fixtures. Runtime services,
/// persistence, and UI actions remain the same as in a normal app launch.
@MainActor
enum UITestLaunchConfiguration {
    static func makeViewModel() throws -> MainViewModel {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["EFBY_UI_TEST_DIRECTORY"],
              directory.hasPrefix("/"),
              let baseURLString = environment["EFBY_UI_TEST_BASE_URL"],
              let baseURL = URL(string: baseURLString),
              baseURL.scheme == "http", baseURL.host == "127.0.0.1",
              baseURL.port != nil, baseURL.user == nil, baseURL.password == nil else {
            throw ConfigurationError.invalidEnvironment
        }

        let root = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath()
        // Xcode's macOS UI runner uses its own sandbox container for temporary files.
        let runnerTemporaryDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.efby.requestlabs.uitests.xctrunner/Data/tmp", isDirectory: true)
        let temporaryRoots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp"), runnerTemporaryDirectory]
            .map { $0.resolvingSymlinksInPath().pathComponents }
        guard root.lastPathComponent.hasPrefix("efby-ui-tests-"),
              temporaryRoots.contains(where: { root.pathComponents.starts(with: $0) }) else {
            throw ConfigurationError.requiresTemporaryDirectory
        }

        let storageURL = root.appendingPathComponent("workspace.json")
        if !FileManager.default.fileExists(atPath: storageURL.path) {
            try seedWorkspaces(in: root, storageURL: storageURL, baseURL: baseURL)
        }
        return MainViewModel(dependencies: .live(
            workspaceRepository: WorkspaceRepository(storageURL: storageURL)
        ))
    }

    private static func seedWorkspaces(in root: URL, storageURL: URL, baseURL: URL) throws {
        let workdir = root.appendingPathComponent("workdir", isDirectory: true)
        let alphaEnvironment = EnvironmentProfile(
            name: "Alpha Environment", variables: [VariableValue(key: "workspaceMarker", value: "alpha")]
        )
        let betaEnvironment = EnvironmentProfile(
            name: "Beta Environment", variables: [VariableValue(key: "workspaceMarker", value: "beta")]
        )
        let alpha = WorkspaceState(
            activeWorkspaceName: "Alpha",
            collections: [CollectionModel(
                info: CollectionInfoModel(name: "Alpha Collection"),
                items: [
                    node(name: "Alpha GET", requestID: "11111111-1111-1111-1111-111111111111",
                         nodeID: "22222222-2222-2222-2222-222222222222", url: baseURL.appendingPathComponent("success")),
                    node(name: "Alpha Slow", requestID: "33333333-3333-3333-3333-333333333333",
                         nodeID: "44444444-4444-4444-4444-444444444444", url: baseURL.appendingPathComponent("slow")),
                ]
            )],
            environments: [alphaEnvironment], activeEnvironmentID: alphaEnvironment.id
        )
        let beta = WorkspaceState(
            activeWorkspaceName: "Beta",
            collections: [CollectionModel(
                info: CollectionInfoModel(name: "Beta Collection"),
                items: [node(name: "Beta GET", requestID: "55555555-5555-5555-5555-555555555555",
                             nodeID: "66666666-6666-6666-6666-666666666666", url: baseURL.appendingPathComponent("beta"))]
            )],
            environments: [betaEnvironment], activeEnvironmentID: betaEnvironment.id
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for state in [alpha, beta] {
            let directory = workdir.appendingPathComponent(state.activeWorkspaceName!, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(
                to: directory.appendingPathComponent(SharedCollectionsRepository.workspaceSnapshotFilename),
                options: .atomic
            )
        }
        try Data().write(to: workdir.appendingPathComponent(SharedCollectionsRepository.workdirMarkerFilename))
        var local = alpha
        local.sharedCollectionsDirectoryPath = workdir.path
        try encoder.encode(local).write(to: storageURL, options: .atomic)
    }

    private static func node(name: String, requestID: String, nodeID: String, url: URL) -> CollectionNode {
        CollectionNode(
            id: UUID(uuidString: nodeID)!, name: name, kind: .request,
            request: APIRequestModel(id: UUID(uuidString: requestID)!, name: name, url: url.absoluteString)
        )
    }

    private enum ConfigurationError: Error {
        case invalidEnvironment
        case requiresTemporaryDirectory
    }
}
#endif
