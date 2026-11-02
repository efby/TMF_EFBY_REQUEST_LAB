import AppKit
import SwiftUI

enum PostmanTheme {
    static let appBackground = Color(nsColor: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let panel = Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1))
    static let panelElevated = Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    static let tab = Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.18, blue: 0.19, alpha: 1))
    static let activeTab = Color(nsColor: NSColor(calibratedRed: 0.21, green: 0.21, blue: 0.22, alpha: 1))
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.20, green: 0.43, blue: 0.83, alpha: 1))
    static let green = Color(nsColor: NSColor(calibratedRed: 0.23, green: 0.75, blue: 0.47, alpha: 1))
    static let orange = Color(nsColor: NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.22, alpha: 1))
    static let salmon = Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.53, blue: 0.47, alpha: 1))
    static let warning = Color(nsColor: NSColor(calibratedRed: 0.36, green: 0.26, blue: 0.05, alpha: 1))
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.63)
}
