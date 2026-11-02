import AppKit
import SwiftUI

struct ResizableVerticalSplitView<Top: View, Bottom: View>: View {
    @Binding var topHeightRatio: CGFloat
    let minimumTopHeight: CGFloat
    let minimumBottomHeight: CGFloat
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @State private var dragOriginRatio: CGFloat?
    @State private var isHoveringDivider = false

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 10
            let totalHeight = geometry.size.height
            let availableHeight = max(totalHeight - dividerHeight, minimumTopHeight + minimumBottomHeight)
            let proposedTopHeight = availableHeight * topHeightRatio
            let topHeight = min(max(proposedTopHeight, minimumTopHeight), availableHeight - minimumBottomHeight)
            let bottomHeight = max(availableHeight - topHeight, minimumBottomHeight)

            VStack(spacing: 0) {
                top
                    .frame(height: topHeight)

                Rectangle()
                    .fill(PostmanTheme.border.opacity(0.8))
                    .frame(height: 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(PostmanTheme.panelElevated)
                            .frame(width: 84, height: dividerHeight)
                            .overlay(
                                HStack(spacing: 5) {
                                    Capsule().fill(PostmanTheme.textSecondary.opacity(0.7)).frame(width: 14, height: 3)
                                    Capsule().fill(PostmanTheme.textSecondary.opacity(0.7)).frame(width: 14, height: 3)
                                }
                            )
                    }
                    .frame(height: dividerHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHoveringDivider else { return }
                        isHoveringDivider = hovering
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragOriginRatio == nil {
                                    dragOriginRatio = topHeightRatio
                                }
                                let baseRatio = dragOriginRatio ?? topHeightRatio
                                let deltaRatio = value.translation.height / availableHeight
                                topHeightRatio = min(max(baseRatio + deltaRatio, minimumTopHeight / availableHeight), 1 - (minimumBottomHeight / availableHeight))
                            }
                            .onEnded { _ in
                                dragOriginRatio = nil
                            }
                    )

                bottom
                    .frame(height: bottomHeight)
            }
        }
    }
}
