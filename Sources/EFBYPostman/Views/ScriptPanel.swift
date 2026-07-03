import EfbyPresentation

enum ScriptPanel: Equatable {
    case preRequest
    case test

    init?(storageKey: String) {
        switch storageKey {
        case "preRequest":
            self = .preRequest
        case "test":
            self = .test
        default:
            return nil
        }
    }

    var storageKey: String {
        switch self {
        case .preRequest:
            return "preRequest"
        case .test:
            return "test"
        }
    }

    var scrollStorageKey: String {
        "scripts.\(storageKey)"
    }

    var event: ScriptEventType {
        switch self {
        case .preRequest:
            return .preRequest
        case .test:
            return .test
        }
    }

    func title(for transportKind: RequestTransportKind) -> String {
        switch self {
        case .preRequest:
            return "Pre-request Script"
        case .test:
            return transportKind == .webSocket ? "On Message Script" : "Post-response Script"
        }
    }

    func sidebarTitle(for transportKind: RequestTransportKind) -> String {
        switch self {
        case .preRequest:
            return "Pre-req"
        case .test:
            return transportKind == .webSocket ? "On Msg" : "Post-res"
        }
    }
}
