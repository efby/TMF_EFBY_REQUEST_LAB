import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Copia texto plano al portapapeles del sistema (macOS / iOS).
public enum PlatformClipboard {
    public static func copyPlainText(_ text: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = text
#endif
    }
}
