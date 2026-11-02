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
        if isTerminationInProgress { return .terminateLater }
        guard let viewModel else {
            return .terminateNow
        }

        isTerminationInProgress = true
        Task { @MainActor [weak self, weak viewModel] in
            let saved = await viewModel?.flushStateForApplicationTermination() ?? true
            self?.isTerminationInProgress = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

@main
struct EFBYPostmanApp: App {
    @NSApplicationDelegateAdaptor(EFBYPostmanAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: MainViewModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            do {
                let testViewModel = try UITestLaunchConfiguration.makeViewModel()
                _viewModel = StateObject(wrappedValue: testViewModel)
            } catch {
                fatalError("Invalid UI test configuration: \(error)")
            }
            return
        }
        #endif
        _viewModel = StateObject(wrappedValue: MainViewModel(dependencies: AppDependencies.live()))
    }

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
