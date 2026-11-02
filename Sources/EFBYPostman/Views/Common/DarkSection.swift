import SwiftUI

struct DarkSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(PostmanTheme.textPrimary)
            content
        }
        .padding(14)
        .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
    }
}
