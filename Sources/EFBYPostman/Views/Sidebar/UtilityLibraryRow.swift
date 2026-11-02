import EfbyPresentation
import SwiftUI

struct UtilityLibraryRow: View {
    let utility: WorkspaceScriptUtility

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PostmanTheme.panelElevated)
                    .frame(width: 28, height: 28)

                Image(systemName: "curlybraces.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(utility.isEnabled ? PostmanTheme.accent : PostmanTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(utility.name)
                        .lineLimit(1)
                        .foregroundStyle(PostmanTheme.textPrimary)

                    Circle()
                        .fill(utility.isEnabled ? PostmanTheme.green : PostmanTheme.textSecondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Text(utility.isEnabled ? "JavaScript utility available in all scripts" : "Disabled for this workspace")
                    .font(.caption2)
                    .foregroundStyle(PostmanTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
