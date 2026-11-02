import EfbyPresentation
import SwiftUI

struct WorkspacePane: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            RequestTabsBar(viewModel: viewModel)
            Divider().overlay(PostmanTheme.border)

            if let currentTab = viewModel.currentTab {
                RequestWorkspace(viewModel: viewModel, tab: currentTab)
                    .id(currentTab.id)
            } else {
                ContentUnavailableView("No Open Tabs", systemImage: "rectangle.on.rectangle")
                    .foregroundStyle(PostmanTheme.textSecondary)
            }
        }
        .background(PostmanTheme.appBackground)
    }
}
