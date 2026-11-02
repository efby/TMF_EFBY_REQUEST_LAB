import EfbyPresentation
import SwiftUI

struct SidebarToolbar: View {
    @ObservedObject var viewModel: MainViewModel
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(PostmanTheme.textSecondary)
                    DarkTextInput(text: $viewModel.searchText, placeholder: "Search")
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(PostmanTheme.panelElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

                Button {
                    onImport()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PostmanTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Import")
            }
        }
        .padding(12)
        .background(PostmanTheme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PostmanTheme.border)
                .frame(height: 1)
        }
    }
}
