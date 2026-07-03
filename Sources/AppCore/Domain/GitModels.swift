import Foundation

public struct GitRemoteConfiguration: Sendable, Equatable {
    public let remoteURL: String

    public init(remoteURL: String) {
        self.remoteURL = remoteURL
    }
}

public enum GitProvider: String, Sendable, Equatable {
    case bitbucket
    case github
    case gitlab
    case unknown

    public var displayName: String {
        switch self {
        case .bitbucket: return "Bitbucket"
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .unknown: return "Git provider"
        }
    }
}

public enum GitAuthenticationKind: Sendable, Equatable {
    case ssh
    case https
    case unknown
}

// MARK: - Git operations

public typealias GitOutputHandler = @Sendable (String) -> Void

public struct GitCommandResult: Sendable {
    public var output: String
    public var exitCode: Int32
    public var changedPaths: [String]
    public var requiresFullRefresh: Bool
    /// When a merge stopped with conflicts, paths still unmerged (`git diff --diff-filter=U`). Empty otherwise.
    public var mergeConflictsPending: [String]

    public init(
        output: String,
        exitCode: Int32,
        changedPaths: [String] = [],
        requiresFullRefresh: Bool = false,
        mergeConflictsPending: [String] = []
    ) {
        self.output = output
        self.exitCode = exitCode
        self.changedPaths = changedPaths
        self.requiresFullRefresh = requiresFullRefresh
        self.mergeConflictsPending = mergeConflictsPending
    }
}

public enum GitConnectionState: Sendable, Equatable {
    case connected
    case authenticationRequired
    case gitMissing
}

public enum GitCredentialMode: String, Sendable, Equatable, CaseIterable {
    case token = "Token / API Key"
    case usernamePassword = "Username & Password"
}

public struct GitCredentialInput: Sendable, Equatable {
    public let mode: GitCredentialMode
    public let username: String
    public let secret: String

    public init(mode: GitCredentialMode, username: String = "", secret: String) {
        self.mode = mode
        self.username = username
        self.secret = secret
    }
}

public struct GitConnectionFlowResult: Sendable, Equatable {
    public let state: GitConnectionState
    public let output: String
    public let remoteURL: String?
    public let provider: GitProvider
    public let authKind: GitAuthenticationKind
    public let helpURL: URL?
    public let credentialInstructions: String?
    public let preferredCredentialMode: GitCredentialMode?

    public init(
        state: GitConnectionState,
        output: String,
        remoteURL: String?,
        provider: GitProvider,
        authKind: GitAuthenticationKind,
        helpURL: URL? = nil,
        credentialInstructions: String? = nil,
        preferredCredentialMode: GitCredentialMode? = nil
    ) {
        self.state = state
        self.output = output
        self.remoteURL = remoteURL
        self.provider = provider
        self.authKind = authKind
        self.helpURL = helpURL
        self.credentialInstructions = credentialInstructions
        self.preferredCredentialMode = preferredCredentialMode
    }
}
