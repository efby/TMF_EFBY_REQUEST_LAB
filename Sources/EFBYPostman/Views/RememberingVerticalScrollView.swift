import AppKit
import SwiftUI

struct RememberingVerticalScrollView<Content: View>: NSViewRepresentable {
    @Binding var scrollOffset: Double
    var showsIndicators: Bool = true
    let content: Content

    init(
        scrollOffset: Binding<Double>,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self._scrollOffset = scrollOffset
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollOffset: $scrollOffset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = showsIndicators
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setFrameSize(hostingView.fittingSize)
        documentView.addSubview(hostingView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: documentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.attach(scrollView: scrollView, hostingView: hostingView)
        context.coordinator.applyScrollOffset(scrollOffset)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hostingView?.rootView = content
        scrollView.hasVerticalScroller = showsIndicators
        context.coordinator.applyScrollOffset(scrollOffset)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(
            coordinator,
            name: NSView.boundsDidChangeNotification,
            object: nsView.contentView
        )
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var scrollOffset: Double
        weak var scrollView: NSScrollView?
        var hostingView: NSHostingView<Content>?
        private var isApplyingScrollOffset = false

        init(scrollOffset: Binding<Double>) {
            self._scrollOffset = scrollOffset
        }

        func attach(scrollView: NSScrollView, hostingView: NSHostingView<Content>) {
            self.scrollView = scrollView
            self.hostingView = hostingView
        }

        func detach() {
            scrollView = nil
            hostingView = nil
        }

        @objc
        func boundsDidChange(_ notification: Notification) {
            guard !isApplyingScrollOffset,
                  let scrollView else {
                return
            }

            let offset = Double(scrollView.contentView.bounds.origin.y)
            if abs(scrollOffset - offset) > 0.5 {
                scrollOffset = offset
            }
        }

        func applyScrollOffset(_ requestedOffset: Double) {
            guard let scrollView else { return }

            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }

                let documentHeight = scrollView.documentView?.bounds.height ?? 0
                let visibleHeight = scrollView.contentView.bounds.height
                let maxOffset = max(0, documentHeight - visibleHeight)
                let clampedOffset = min(max(0, requestedOffset), maxOffset)
                let currentOffset = scrollView.contentView.bounds.origin.y

                guard abs(currentOffset - clampedOffset) > 0.5 else { return }

                self.isApplyingScrollOffset = true
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOffset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                Task { @MainActor [weak self] in
                    self?.isApplyingScrollOffset = false
                }
            }
        }
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
