#if canImport(JavaScriptCore) && canImport(Darwin)
import Darwin
import Foundation
import JavaScriptCore

/// The execution-limit entry points are WebKit SPI, rather than public Apple SDK API.
/// Resolve both at runtime and refuse execution when either is unavailable.
enum JavaScriptExecutionWatchdog {
    private typealias Callback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (OpaquePointer?, Double, Callback?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimit = @convention(c) (OpaquePointer?) -> Void

    private struct API: Sendable {
        let setLimit: SetLimit
        let clearLimit: ClearLimit
    }

    private static let api: API? = {
        guard let framework = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW | RTLD_LOCAL),
              let set = dlsym(framework, "JSContextGroupSetExecutionTimeLimit"),
              let clear = dlsym(framework, "JSContextGroupClearExecutionTimeLimit") else {
            return nil
        }
        // Keep the framework loaded for the lifetime of these function pointers.
        return API(setLimit: unsafeBitCast(set, to: SetLimit.self), clearLimit: unsafeBitCast(clear, to: ClearLimit.self))
    }()

    private static let callback: Callback = { context, pointer in
        guard let pointer else { return true }
        let control = Unmanaged<Control>.fromOpaque(pointer).takeUnretainedValue()
        if control.checkInterruption() != nil { return true }
        guard let api, let context, let group = JSContextGetGroup(context) else { return true }
        // Returning false continues evaluation without starting another timer. Rearm explicitly
        // so a long script remains cancellable after the first polling interval.
        api.setLimit(group, 0.02, callback, pointer)
        return false
    }

    final class Control {
        private let deadline: TimeInterval
        private let timeLimit: TimeInterval
        private(set) var interruption: ScriptExecutionInterruption?

        init(timeLimit: TimeInterval) {
            self.timeLimit = timeLimit
            deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        }

        @discardableResult
        func checkInterruption() -> ScriptExecutionInterruption? {
            if interruption == nil {
                if Task.isCancelled {
                    interruption = .cancelled
                } else if ProcessInfo.processInfo.systemUptime >= deadline {
                    interruption = .timeLimitExceeded(seconds: timeLimit)
                }
            }
            return interruption
        }

        func evaluate(_ source: String, in context: JSContext, sourceURL: URL? = nil) -> JSValue? {
            guard checkInterruption() == nil else { return nil }
            return context.evaluateScript(source, withSourceURL: sourceURL)
        }
    }

    static func run<T>(
        in context: JSContext,
        timeLimit: TimeInterval,
        operation: (Control) -> T
    ) -> Result<T, ScriptExecutionInterruption> {
        guard let api, let group = JSContextGetGroup(context.jsGlobalContextRef) else {
            return .failure(.watchdogUnavailable)
        }
        let control = Control(timeLimit: timeLimit)
        if let interruption = control.checkInterruption() { return .failure(interruption) }
        let pointer = Unmanaged.passUnretained(control).toOpaque()
        api.setLimit(group, min(timeLimit, 0.02), callback, pointer)
        defer { api.clearLimit(group) }
        // The callback runs synchronously on JavaScript's execution thread. The control stays
        // alive until evaluation returns and the watchdog has been cleared.
        return withExtendedLifetime(control) {
            let value = operation(control)
            if let interruption = control.checkInterruption() { return .failure(interruption) }
            return .success(value)
        }
    }
}
#endif
