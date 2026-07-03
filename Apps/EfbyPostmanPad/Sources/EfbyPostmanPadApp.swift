import EfbyPresentation
import SwiftUI

@main
struct EfbyPostmanPadApp: App {
    @StateObject private var viewModel = MainViewModel()

    var body: some Scene {
        WindowGroup {
            PadShellView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
