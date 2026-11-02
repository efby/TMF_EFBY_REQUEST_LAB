import EfbyPresentation
import SwiftUI

struct EditableKeyValueList: View {
    let title: String
    @Binding var entries: [KeyValueEntry]
    @State private var previewPayload: CodeValuePreviewPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PostmanTheme.textPrimary)
                    Spacer()
                    addButton
                }
            } else {
                HStack {
                    Spacer()
                    addButton
                }
            }

            if entries.isEmpty {
                Text("No entries.")
                    .foregroundStyle(PostmanTheme.textSecondary)
            } else {
                ForEach(entries.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Toggle("", isOn: binding(for: index, keyPath: \.isEnabled))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .foregroundStyle(PostmanTheme.textSecondary)

                        darkRowInput("Key", text: binding(for: index, keyPath: \.key))
                        darkRowInput("Value", text: binding(for: index, keyPath: \.value))
                        previewButton(
                            title: entries[index].key.isEmpty ? "Value" : entries[index].key,
                            value: entries[index].value
                        )

                        Button {
                            entries.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(PostmanTheme.textSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $previewPayload) { payload in
            CodeValuePreviewSheet(payload: payload)
                .preferredColorScheme(.dark)
        }
    }

    private var addButton: some View {
        Button {
            entries.append(KeyValueEntry())
        } label: {
            Text("Add")
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.accent)
    }

    private func darkRowInput(_ placeholder: String, text: Binding<String>) -> some View {
        DarkTextInput(text: text, placeholder: placeholder)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
    }

    private func previewButton(title: String, value: String) -> some View {
        Button("Preview", systemImage: "magnifyingglass") {
            previewPayload = CodeValuePreviewPayload(title: title, value: value)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(PostmanTheme.textSecondary)
        .frame(width: 28, height: 28)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
        .accessibilityLabel("Preview \(title)")
    }

    private func binding<Value>(for index: Int, keyPath: WritableKeyPath<KeyValueEntry, Value>) -> Binding<Value> {
        Binding(
            get: { entries[index][keyPath: keyPath] },
            set: { entries[index][keyPath: keyPath] = $0 }
        )
    }
}
