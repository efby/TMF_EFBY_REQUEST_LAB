import EfbyPresentation
import SwiftUI

struct FlowRow: View {
    let flow: WorkspaceFlowDefinition
    var isFlowRunning: Bool = false

    private var validationColor: Color {
        flow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PostmanTheme.textSecondary.opacity(0.55) : PostmanTheme.green
    }

    private var validationText: String {
        if flow.bpmnXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No BPMN diagram saved yet"
        }
        return "\(flow.taskBindings.count) task bindings configured"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PostmanTheme.panelElevated)
                    .frame(width: 28, height: 28)

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PostmanTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(flow.name)
                        .lineLimit(1)
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Circle()
                        .fill(validationColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Text(validationText)
                    .font(.caption2)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isFlowRunning {
                Text("Running")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PostmanTheme.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
