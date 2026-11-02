import EfbyPresentation
import SwiftUI

struct CollectionTreeView: View {
    let collection: CollectionModel
    let selectedNodeID: UUID?
    let onOpenRequest: (CollectionNode) -> Void
    let onNewRequest: () -> Void
    let onCloneCollection: () -> Void
    let onRenameCollection: () -> Void
    let onDeleteCollection: () -> Void
    let onRenameRequest: (CollectionNode) -> Void
    let onDuplicateRequest: (CollectionNode) -> Void
    let onDeleteRequest: (CollectionNode) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(collection.info.name)
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .font(.body.weight(.medium))
                Spacer()
                Button {
                    onNewRequest()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(PostmanTheme.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button("New Request", action: onNewRequest)
                    Button("Clone Collection", action: onCloneCollection)
                    Button("Rename Collection", action: onRenameCollection)
                    Button("Delete Collection", role: .destructive, action: onDeleteCollection)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if isExpanded {
                ForEach(collection.items) { child in
                    NodeRow(
                        node: child,
                        level: 1,
                        selectedNodeID: selectedNodeID,
                        onOpenRequest: onOpenRequest,
                        onRenameRequest: onRenameRequest,
                        onDuplicateRequest: onDuplicateRequest,
                        onDeleteRequest: onDeleteRequest
                    )
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: CollectionNode
    let level: Int
    let selectedNodeID: UUID?
    let onOpenRequest: (CollectionNode) -> Void
    let onRenameRequest: (CollectionNode) -> Void
    let onDuplicateRequest: (CollectionNode) -> Void
    let onDeleteRequest: (CollectionNode) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if node.kind == .folder {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PostmanTheme.textSecondary)
                            .frame(width: 10)
                        Text(node.name)
                            .foregroundStyle(level == 0 ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                            .font(level == 0 ? .body.weight(.medium) : .callout)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(level) * 14)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(node.children) { child in
                        NodeRow(
                            node: child,
                            level: level + 1,
                            selectedNodeID: selectedNodeID,
                            onOpenRequest: onOpenRequest,
                            onRenameRequest: onRenameRequest,
                            onDuplicateRequest: onDuplicateRequest,
                            onDeleteRequest: onDeleteRequest
                        )
                    }
                }
            } else {
                Button {
                    onOpenRequest(node)
                } label: {
                    HStack(spacing: 8) {
                        Spacer()
                            .frame(width: 10)
                        if let request = node.request {
                            requestPill(request)
                        } else {
                            methodPill(.get)
                        }
                        Text(node.name)
                            .lineLimit(1)
                            .foregroundStyle(PostmanTheme.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.request.\(node.id.uuidString)")
                .padding(.leading, CGFloat(level) * 14)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    selectedNodeID == node.id ? PostmanTheme.activeTab : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contextMenu {
                    Button("Rename Request") {
                        onRenameRequest(node)
                    }
                    Button("Duplicate Request") {
                        onDuplicateRequest(node)
                    }
                    Button("Delete Request", role: .destructive) {
                        onDeleteRequest(node)
                    }
                }
            }
        }
    }
}
