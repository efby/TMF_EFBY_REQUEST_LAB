import EfbyPresentation
import SwiftUI

struct EditableVariableList: View {
    @Binding var variables: [VariableValue]
    @State private var previewPayload: CodeValuePreviewPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Variables")
                    .font(.headline)
                    .foregroundStyle(PostmanTheme.textPrimary)
                Spacer()
                Button {
                    variables.append(VariableValue())
                } label: {
                    Text("Add Variable")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.accent)
            }

            ForEach(variables.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(for: index, keyPath: \.isEnabled))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    DarkTextInput(text: binding(for: index, keyPath: \.key), placeholder: "Key")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    DarkTextInput(text: binding(for: index, keyPath: \.value), placeholder: "Value")
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                    previewButton(
                        title: variables[index].key.isEmpty ? "Value" : variables[index].key,
                        value: variables[index].value
                    )
                    Button {
                        variables.remove(at: index)
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
        .sheet(item: $previewPayload) { payload in
            CodeValuePreviewSheet(payload: payload)
                .preferredColorScheme(.dark)
        }
    }

    private func binding<Value>(for index: Int, keyPath: WritableKeyPath<VariableValue, Value>) -> Binding<Value> {
        Binding(
            get: { variables[index][keyPath: keyPath] },
            set: { variables[index][keyPath: keyPath] = $0 }
        )
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
}
