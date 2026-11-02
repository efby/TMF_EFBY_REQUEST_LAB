import EfbyPresentation
import SwiftUI

struct RequestTabsBar: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.tabs) { tab in
                    HStack(spacing: 8) {
                        requestPill(tab.request)
                        Button {
                            viewModel.selectedTabID = tab.id
                        } label: {
                            Text(tab.request.name)
                                .lineLimit(1)
                                .foregroundStyle(viewModel.selectedTabID == tab.id ? PostmanTheme.textPrimary : PostmanTheme.textSecondary)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("request.tab.\(tab.request.id.uuidString)")
                        .accessibilityValue(viewModel.selectedTabID == tab.id ? "selected" : "unselected")

                        if tab.isSending {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            viewModel.closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(PostmanTheme.textSecondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("request.tab.close.\(tab.request.id.uuidString)")
                        .accessibilityLabel("Close \(tab.request.name)")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        viewModel.selectedTabID == tab.id ? PostmanTheme.activeTab : PostmanTheme.tab,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }

                Button {
                    viewModel.newRequest()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(PostmanTheme.tab, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("request.tab.new")
                .accessibilityLabel("New Request")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(PostmanTheme.panel)
        .accessibilityIdentifier("request.tabs")
    }
}
