import CoreGraphics
import Foundation

// CI needs room for the app's 1200-point window plus system chrome.
// Display bounds and mode.width/height use display coordinates; pixelWidth/
// pixelHeight describe the backing pixels and must not satisfy this minimum.
struct DisplaySize: Equatable, CustomStringConvertible {
    let width: Int
    let height: Int

    func contains(_ minimum: DisplaySize) -> Bool {
        width >= minimum.width && height >= minimum.height
    }

    var description: String { "\(width)x\(height)" }
}

struct DisplayModeInfo {
    let index: Int
    let logical: DisplaySize
    let backing: DisplaySize
    let refreshRate: Double
}

let minimumSize = DisplaySize(width: 1440, height: 900)
let preferredSize = DisplaySize(width: 1920, height: 1080)

func selectMode(
    from modes: [DisplayModeInfo],
    minimum: DisplaySize = minimumSize,
    preferred: DisplaySize = preferredSize
) -> DisplayModeInfo? {
    modes.filter { $0.logical.contains(minimum) }.min { lhs, rhs in
        func distance(_ mode: DisplayModeInfo) -> Double {
            let dx = Double(mode.logical.width) - Double(preferred.width)
            let dy = Double(mode.logical.height) - Double(preferred.height)
            return dx * dx + dy * dy
        }
        let leftDistance = distance(lhs)
        let rightDistance = distance(rhs)
        if leftDistance != rightDistance { return leftDistance < rightDistance }
        // Prefer an unscaled mode for equal logical sizes to avoid unnecessary
        // rendering work and oversized CI screenshots.
        let leftBacking = Double(lhs.backing.width) * Double(lhs.backing.height)
        let rightBacking = Double(rhs.backing.width) * Double(rhs.backing.height)
        if leftBacking != rightBacking { return leftBacking < rightBacking }
        let leftRate = lhs.refreshRate.isFinite ? abs(lhs.refreshRate - 60) : .infinity
        let rightRate = rhs.refreshRate.isFinite ? abs(rhs.refreshRate - 60) : .infinity
        if leftRate != rightRate { return leftRate < rightRate }
        return lhs.index < rhs.index
    }
}

enum DisplaySetupError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

func currentSize(_ display: CGDirectDisplayID) -> DisplaySize {
    let bounds = CGDisplayBounds(display)
    return DisplaySize(width: Int(bounds.width.rounded(.down)), height: Int(bounds.height.rounded(.down)))
}

struct VMDisplayProvider {
    let name: String
    let path: String
    let arguments: [String]
}

// These are the preinstalled guest tools documented by runner-images maintainers
// in issues #9345 and #8606. Never discover or invoke a command through a shell.
let vmDisplayProviders = [
    VMDisplayProvider(name: "Anka", path: "/Library/Application Support/Veertu/Anka/addons/change_res",
                      arguments: ["1920x1080x32@30"]),
    VMDisplayProvider(name: "VMware", path: "/Library/Application Support/VMware Tools/vmware-resolutionSet",
                      arguments: ["1920", "1080"])
]

func verifyMinimumDisplay(_ display: CGDirectDisplayID) -> Bool {
    // WindowServer can publish its new bounds asynchronously after an API or
    // guest utility returns. Verify actual coordinates instead of exit status.
    let deadline = Date().addingTimeInterval(5)
    repeat {
        let actual = currentSize(display)
        if actual.contains(minimumSize) {
            print("Verified display: \(actual) logical. UI tests may start.")
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}

func setSessionDisplayMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode) -> CGError {
    // CGDisplaySetDisplayMode reverts when this helper exits. The test runner is
    // a separate process, so retain the selected mode for the login session.
    var configuration: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configuration)
    guard beginResult == .success, let configuration else { return beginResult == .success ? .failure : beginResult }

    let configureResult = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard configureResult == .success else {
        CGCancelDisplayConfiguration(configuration)
        return configureResult
    }
    // Completing consumes the configuration, including when it fails.
    return CGCompleteDisplayConfiguration(configuration, .forSession)
}

func configureUsingGuestTools(_ display: CGDirectDisplayID) throws {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
        throw DisplaySetupError.message("Guest display utilities are restricted to GitHub Actions.")
    }
    for provider in vmDisplayProviders {
        let available = FileManager.default.isExecutableFile(atPath: provider.path)
        print("\(provider.name) display provider: \(provider.path); executable: \(available).")
        guard available else { continue }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: provider.path)
        process.arguments = provider.arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            print("\(provider.name) could not start: \(error).")
            continue
        }
        if finished.wait(timeout: .now() + 15) == .timedOut {
            print("\(provider.name) timed out after 15 seconds; requesting termination.")
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }
        if process.isRunning {
            print("\(provider.name) is still running; no exit status available.")
        } else {
            print("\(provider.name) exit status: \(process.terminationStatus).")
        }
        if verifyMinimumDisplay(display) { return }
        print("\(provider.name) did not provide the required logical bounds: \(currentSize(display)).")
    }
    throw DisplaySetupError.message("No CoreGraphics mode or preinstalled Anka/VMware utility provided \(minimumSize) logical coordinates. Actual display: \(currentSize(display)). Backing-pixel size alone is insufficient.")
}

func inspectAndConfigure(checkOnly: Bool) throws {
    // A normal local invocation must never alter the user's display.
    guard checkOnly || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
        throw DisplaySetupError.message("Display changes are restricted to GitHub Actions. Use --check-only locally.")
    }

    let display = CGMainDisplayID()
    let before = currentSize(display)
    guard display != 0, before.width > 0, before.height > 0 else {
        throw DisplaySetupError.message("No active main display was found. UI tests require a graphical login session.")
    }
    print("Main display \(display): \(before) logical; UI minimum: \(minimumSize).")
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let nativeModes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    let isRotated = abs(CGDisplayRotation(display).truncatingRemainder(dividingBy: 180) - 90) < 0.1
    let modes = nativeModes.enumerated().map { index, mode in
        DisplayModeInfo(
            index: index,
            logical: DisplaySize(width: isRotated ? mode.height : mode.width, height: isRotated ? mode.width : mode.height),
            backing: DisplaySize(width: mode.pixelWidth, height: mode.pixelHeight),
            refreshRate: mode.refreshRate
        )
    }
    print("Available display modes (logical / backing pixels):")
    for mode in modes {
        print("  [\(mode.index)] \(mode.logical) / \(mode.backing), \(mode.refreshRate) Hz")
    }

    if before.contains(minimumSize) {
        print("Display is already large enough; no change made.")
        return
    }
    let selected = selectMode(from: modes)
    if checkOnly {
        if let selected {
            print("Would select mode [\(selected.index)] \(selected.logical).")
        } else {
            print("No suitable CoreGraphics mode is available; CI would try preinstalled guest display utilities.")
        }
        print("--check-only made no changes and ran no guest utilities.")
        throw DisplaySetupError.message("The current display is too small for UI tests; run configuration on the CI runner.")
    }
    guard let selected else {
        print("No suitable CoreGraphics mode; trying preinstalled CI guest display tools.")
        return try configureUsingGuestTools(display)
    }

    print("Selecting mode [\(selected.index)] \(selected.logical) logical / \(selected.backing) backing pixels.")
    let result = setSessionDisplayMode(display, nativeModes[selected.index])
    if result != .success {
        print("Session display configuration failed with error \(result.rawValue) for \(selected.logical); trying CI guest tools.")
        return try configureUsingGuestTools(display)
    }
    if verifyMinimumDisplay(display) { return }
    print("CoreGraphics mode did not take effect; trying preinstalled CI guest display tools.")
    try configureUsingGuestTools(display)
}

func selfTest() throws {
    func mode(_ index: Int, _ width: Int, _ height: Int, backingWidth: Int? = nil, backingHeight: Int? = nil) -> DisplayModeInfo {
        DisplayModeInfo(index: index, logical: DisplaySize(width: width, height: height),
                        backing: DisplaySize(width: backingWidth ?? width, height: backingHeight ?? height), refreshRate: 60)
    }
    var assertions = 0
    func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        guard condition else { throw DisplaySetupError.message("Display self-test failed: \(message)") }
    }
    let hidpiTooSmall = mode(0, 1024, 768, backingWidth: 2048, backingHeight: 1536)
    let minimum = mode(1, 1440, 900)
    let preferred = mode(2, 1920, 1080)
    try expect(selectMode(from: [hidpiTooSmall]) == nil, "HiDPI backing pixels must not satisfy logical minimum")
    try expect(selectMode(from: [hidpiTooSmall, minimum])?.index == 1, "valid logical dimensions must win over an unusable HiDPI mode")
    try expect(selectMode(from: [minimum, mode(3, 2560, 1440), preferred])?.index == 2, "1920x1080 must be preferred when available")
    try expect(selectMode(from: [minimum, mode(3, 1600, 900)])?.index == 3, "fallback must choose the closest suitable mode")
    try expect(selectMode(from: [mode(0, 1920, 800), mode(1, 1280, 1080)]) == nil, "both logical dimensions must meet the minimum")
    try expect(selectMode(from: []) == nil, "empty mode lists must fail instead of allowing UI tests")
    try expect(selectMode(from: [mode(0, 1920, 1080, backingWidth: 3840, backingHeight: 2160), preferred])?.index == 2, "equivalent logical modes should avoid unnecessary backing pixels")
    try expect(!DisplaySize(width: 1024, height: 768).contains(minimumSize), "observed CI display must be rejected")
    try expect(DisplaySize(width: 1440, height: 900).contains(minimumSize), "exact minimum must be accepted")
    print("Display selection self-tests passed (\(assertions) assertions); no display APIs were invoked.")
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["--self-test"]: try selfTest()
    case ["--check-only"]: try inspectAndConfigure(checkOnly: true)
    case []: try inspectAndConfigure(checkOnly: false)
    case ["--help"], ["-h"]:
        print("Usage: xcrun swift Tools/configure_ui_test_display.swift [--check-only | --self-test]")
        print("Display changes require GITHUB_ACTIONS=true. --check-only never changes the display.")
    default: throw DisplaySetupError.message("Unknown arguments. Use --help for usage.")
    }
} catch {
    FileHandle.standardError.write(Data("UI display setup failed: \(error)\n".utf8))
    exit(1)
}
