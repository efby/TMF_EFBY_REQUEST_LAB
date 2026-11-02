@testable import EfbyInfrastructure
import EfbyDomain
import Foundation
import XCTest

#if os(macOS)
final class GitRepositorySecurityTests: XCTestCase {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.lock(); defer { lock.unlock() }; text += chunk }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let executable: URL
        let arguments: URL
        let credentialInput: URL
        let environment: [String: String]

        init(extraEnvironment: [String: String] = [:]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("efby-git-security-\(UUID())")
            repository = root.appendingPathComponent("repository")
            executable = root.appendingPathComponent("git-wrapper")
            arguments = root.appendingPathComponent("arguments")
            credentialInput = root.appendingPathComponent("credential-input")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let script = #"""
            #!/bin/sh
            shift
            printf '%s\n' "$@" >> "$EFBY_TEST_ARGUMENTS"
            while [ "$1" = '-c' ]; do shift 2; done
            case "$1" in
              credential)
                if [ "$2" = 'approve' ]; then
                  /bin/cat > "$EFBY_TEST_CREDENTIAL_INPUT"
                  exit 0
                fi
                if [ "$2" = 'fill' ]; then
                  /bin/cat > /dev/null
                  if [ "$EFBY_TEST_KEYCHAIN_FAIL" = '1' ]; then exit 1; fi
                  /bin/cat "$EFBY_TEST_CREDENTIAL_INPUT"
                  exit 0
                fi
                exit 1
                ;;
              fetch|push|ls-remote)
                if [ "$1" = 'ls-remote' ] && [ "$2" = '--symref' ] && [ -n "$EFBY_TEST_BRANCH" ]; then
                  printf 'ref: refs/heads/%s\tHEAD\n' "$EFBY_TEST_BRANCH"
                  exit 0
                fi
                printf '%s\n' "fatal: Authentication failed for https://old-user:old-password@example.invalid/repo.git" >&2
                exit 1
                ;;
              status)
                if [ "$EFBY_TEST_SPLIT_OUTPUT" = '1' ]; then
                  printf '%s' 'https://fake-user:fake-'
                  /bin/sleep 0.05
                  printf '%s\n' 'password@example.invalid/repo.git'
                  exit 0
                fi
                ;;
              diff|ls-files)
                if [ -n "$EFBY_TEST_PATH_OUTPUT" ]; then
                  printf '%s\n' "$EFBY_TEST_PATH_OUTPUT"
                  exit 0
                fi
                ;;
            esac
            exec /usr/bin/git "$@"
            """#
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            environment = ProcessInfo.processInfo.environment.merging([
                "EFBY_TEST_ARGUMENTS": arguments.path,
                "EFBY_TEST_CREDENTIAL_INPUT": credentialInput.path,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
            ].merging(extraEnvironment) { _, new in new }) { _, new in new }
        }

        func service() -> GitRepositoryService {
            GitRepositoryService(processExecutableURL: executable, environment: environment)
        }
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repository
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AppError.persistence("Local Git fixture failed.")
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testConnectStoresCredentialThroughStdinAndKeepsRemoteAndLogsClean() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let output = Output()
        let token = "fake-token@with:reserved-characters"
        let result = try await fixture.service().connectFlow(
            at: fixture.repository, remoteInput: "https://github.com/example/repo.git",
            credentials: GitCredentialInput(mode: .token, secret: token), onOutput: { output.append($0) })

        XCTAssertEqual(result.state, .authenticationRequired)
        XCTAssertEqual(try fixture.git(["remote", "get-url", "origin"]), "https://github.com/example/repo.git")
        let config = try String(contentsOf: fixture.repository.appendingPathComponent(".git/config"), encoding: .utf8)
        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
        for text in [config, arguments, output.value, result.output] {
            XCTAssertFalse(text.contains(token))
            XCTAssertFalse(text.contains("old-password"))
        }
        let input = try String(contentsOf: fixture.credentialInput, encoding: .utf8)
        XCTAssertTrue(input.contains("password=\(token)\n"))
        XCTAssertTrue(input.contains("username=x-access-token\n"))
        XCTAssertEqual(try fixture.git(["config", "--get-all", "credential.https://github.com/example/repo.git.helper"]), "osxkeychain")
        XCTAssertEqual(try fixture.git(["config", "--get", "credential.https://github.com/example/repo.git.username"]), "x-access-token")
    }

    func testMigratesAllFetchAndPushURLsWithoutExposingOldCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["init", "-b", "main"])
        _ = try fixture.git(["remote", "add", "origin", "HTTPS://fake-user:fake-password@example.invalid/repo.git"])
        _ = try fixture.git(["config", "--add", "remote.origin.url", "https://other:second-password@example.invalid/other.git"])
        _ = try fixture.git(["config", "remote.origin.pushurl", "https://writer:push-password@example.invalid/repo.git"])

        let remote = try await fixture.service().remoteURL(at: fixture.repository)
        XCTAssertEqual(remote, "HTTPS://example.invalid/repo.git")
        let config = try String(contentsOf: fixture.repository.appendingPathComponent(".git/config"), encoding: .utf8)
        for token in ["fake-password", "second-password", "push-password"] { XCTAssertFalse(config.contains(token)) }
        XCTAssertEqual(try fixture.git(["config", "--get-all", "remote.origin.url"]), "HTTPS://example.invalid/repo.git\nhttps://example.invalid/other.git")
        XCTAssertEqual(try fixture.git(["config", "--get", "remote.origin.pushurl"]), "https://example.invalid/repo.git")
    }

    func testKeychainFailureLeavesNoCredentialInRemoteAndStopsBeforeNetwork() async throws {
        let fixture = try Fixture(extraEnvironment: ["EFBY_TEST_KEYCHAIN_FAIL": "1"])
        defer { fixture.cleanup() }
        _ = try fixture.git(["init", "-b", "main"])
        _ = try fixture.git(["remote", "add", "origin", "https://fake-user:fake-password@example.invalid/repo.git"])
        let output = Output()
        do {
            _ = try await fixture.service().fetchOrigin(at: fixture.repository, onOutput: { output.append($0) })
            XCTFail("Expected secure storage failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("keychain"))
            XCTAssertFalse(error.localizedDescription.contains("fake-password"))
        }
        XCTAssertEqual(try fixture.git(["remote", "get-url", "origin"]), "https://example.invalid/repo.git")
        XCTAssertFalse(output.value.contains("fake-password"))
        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
        XCTAssertFalse(arguments.components(separatedBy: "\n").contains("fetch"))
    }

    func testSplitProcessOutputIsRedactedBeforeCallbacksAndResult() async throws {
        let fixture = try Fixture(extraEnvironment: ["EFBY_TEST_SPLIT_OUTPUT": "1"])
        defer { fixture.cleanup() }
        let output = Output()
        let result = try await fixture.service().status(at: fixture.repository, onOutput: { output.append($0) })
        XCTAssertFalse(output.value.contains("fake-password"))
        XCTAssertFalse(result.output.contains("fake-password"))
        XCTAssertTrue(result.output.contains("[REDACTED]"))
    }

    func testCredentialRedactionDoesNotAlterPathsUsedForGitOperations() async throws {
        let fixture = try Fixture(extraEnvironment: ["EFBY_TEST_PATH_OUTPUT": "fake-token-file.swift"])
        defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.connectFlow(at: fixture.repository, remoteInput: "https://github.com/example/repo.git",
            credentials: GitCredentialInput(mode: .token, secret: "fake-token"))
        let paths = try await service.localChangesForPull(at: fixture.repository)
        XCTAssertEqual(paths, ["fake-token-file.swift"])
    }

    func testCredentialProtocolRejectsLineBreakInjection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.service().connectFlow(at: fixture.repository, remoteInput: "https://github.com/example/repo.git",
                credentials: GitCredentialInput(mode: .token, secret: "fake-token\nusername=attacker"))
            XCTFail("Expected invalid credential rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("fake-token"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.credentialInput.path))
        XCTAssertEqual(try fixture.git(["remote", "get-url", "origin"]), "https://github.com/example/repo.git")
    }

    func testCredentialProtocolUsesDecodedRepositoryPathAndPort() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service().connectFlow(at: fixture.repository,
            remoteInput: "https://github.com:8443/team/my%20repo.git",
            credentials: GitCredentialInput(mode: .usernamePassword, username: "fake-user", secret: "fake-password"))
        let input = try String(contentsOf: fixture.credentialInput, encoding: .utf8)
        XCTAssertTrue(input.contains("host=github.com:8443\n"))
        XCTAssertTrue(input.contains("path=team/my repo.git\n"), input)
    }

    func testRecoveryDirectoriesAreNotCommittedOrCleanedAsUntrackedChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.git(["init", "-b", "main"])
        _ = try fixture.git(["config", "user.name", "Local Test"])
        _ = try fixture.git(["config", "user.email", "test@example.invalid"])
        let backup = fixture.repository.appendingPathComponent("workspace/.collections.efby-backup")
        let staging = fixture.repository.appendingPathComponent(".environments.efby-staging")
        for folder in [backup, staging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("recovery".utf8).write(to: folder.appendingPathComponent("data.json"))
        }
        try Data("managed".utf8).write(to: fixture.repository.appendingPathComponent("README.md"))
        let service = fixture.service()
        let changed = try await service.localChangesForPull(at: fixture.repository)
        XCTAssertEqual(changed, ["README.md"])
        do {
            _ = try await service.commitAndPush(at: fixture.repository, message: "Local integrity test")
            XCTFail("Network stub must reject push")
        } catch { }
        XCTAssertEqual(try fixture.git(["show", "--format=", "--name-only", "HEAD"]), "README.md")
        try Data("edited".utf8).write(to: fixture.repository.appendingPathComponent("README.md"))
        _ = try await service.stashPushIncludingUntracked(at: fixture.repository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("data.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("data.json").path))
        XCTAssertEqual(try String(contentsOf: fixture.repository.appendingPathComponent("README.md"), encoding: .utf8), "managed")
        _ = try await service.revertLocalChanges(at: fixture.repository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("data.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("data.json").path))
    }

    func testCredentialRedactionPreservesRemoteBranchNames() async throws {
        let fixture = try Fixture(extraEnvironment: ["EFBY_TEST_BRANCH": "main"])
        defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.connectFlow(at: fixture.repository, remoteInput: "https://github.com/example/repo.git",
            credentials: GitCredentialInput(mode: .token, secret: "main"))
        let branch = try await service.remoteDefaultBranch(at: fixture.repository)
        XCTAssertEqual(branch, "main")
    }
}
#endif
