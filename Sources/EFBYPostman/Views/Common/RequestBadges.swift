import EfbyPresentation
import SwiftUI

func methodPill(_ method: HTTPMethod) -> some View {
    Text(method.rawValue)
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(methodColor(method))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(methodColor(method).opacity(0.15), in: Capsule())
}

func requestPill(_ request: APIRequestModel) -> some View {
    Group {
        if request.transportKind == .webSocket {
            Text("WS")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(PostmanTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(PostmanTheme.accent.opacity(0.15), in: Capsule())
        } else if request.isLambdaInvoke {
            Text("λ")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(PostmanTheme.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(PostmanTheme.orange.opacity(0.15), in: Capsule())
        } else {
            methodPill(request.method)
        }
    }
}

private func methodColor(_ method: HTTPMethod) -> Color {
    switch method {
    case .get:
        return PostmanTheme.green
    case .post:
        return PostmanTheme.orange
    case .put:
        return .yellow
    case .patch:
        return .mint
    case .delete:
        return .red
    case .head:
        return .teal
    case .options:
        return .blue
    }
}
