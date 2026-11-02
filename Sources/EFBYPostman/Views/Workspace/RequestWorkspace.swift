import EfbyPresentation
import SwiftUI

struct RequestWorkspace: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var tab: RequestTabState
    @State private var editorHeightRatio: CGFloat = 0.52

    var body: some View {
        VStack(spacing: 0) {
            RequestHeader(viewModel: viewModel, tab: tab)
            Divider().overlay(PostmanTheme.border)
            ResizableVerticalSplitView(
                topHeightRatio: $editorHeightRatio,
                minimumTopHeight: 220,
                minimumBottomHeight: 180
            ) {
                RequestEditorView(viewModel: viewModel, tab: tab)
            } bottom: {
                ResponsePane(viewModel: viewModel, tab: tab)
            }
        }
    }
}
