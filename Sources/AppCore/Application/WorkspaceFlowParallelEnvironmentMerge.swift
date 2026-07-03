import Foundation

/// Folding strategy when joining parallel BPMN branches' flat environment maps.
public enum WorkspaceFlowParallelEnvironmentMerge: Sendable {
    /// When two branches disagree on a key, prefer the value that **diverged** from `baseline` (typically the active environment snapshot at flow start, after batch preflight)
    /// over a value still equal to baseline on the other branch (e.g. a branch that never ran WebSocket scripts).
    public static func fold(
        _ accumulated: [String: String],
        _ incoming: [String: String],
        baseline: [String: String]
    ) -> [String: String] {
        var result = accumulated
        for (key, incomingValue) in incoming {
            guard let previousValue = result[key] else {
                result[key] = incomingValue
                continue
            }
            if previousValue == incomingValue {
                continue
            }
            let base = baseline[key] ?? ""
            let prevChanged = previousValue != base
            let incChanged = incomingValue != base
            if prevChanged, !incChanged {
                result[key] = previousValue
            } else if incChanged, !prevChanged {
                result[key] = incomingValue
            } else if prevChanged, incChanged {
                result[key] = incomingValue
            } else {
                result[key] = incomingValue.isEmpty ? previousValue : incomingValue
            }
        }
        return result
    }
}
