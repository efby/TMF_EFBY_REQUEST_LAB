import AppKit
import EfbyPresentation
import SwiftUI

final class EFBYPostmanAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: MainViewModel?
    private var isTerminationInProgress = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationInProgress, let viewModel else {
            return .terminateNow
        }

        isTerminationInProgress = true
        Task { @MainActor [weak self, weak viewModel] in
            await viewModel?.flushStateForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
            self?.isTerminationInProgress = false
        }
        return .terminateLater
    }
}

@main
struct EFBYPostmanApp: App {
    @NSApplicationDelegateAdaptor(EFBYPostmanAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MainViewModel(dependencies: AppDependencies.live())

    var body: some Scene {
        WindowGroup("EFBY Request Lab") {
            RootView(viewModel: viewModel)
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Workspace") {
                Button("New Request") {
                    viewModel.newRequest()
                }
                .keyboardShortcut("n")

                Button("Duplicate Request") {
                    viewModel.duplicateCurrentRequest()
                }
                .keyboardShortcut("d")

                Button("Send Request") {
                    viewModel.sendCurrentRequest()
                }
                .keyboardShortcut(.return)
            }
        }
    }
}
