import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(CoreImage)
import CoreImage
#endif

/// PNG QR output for script console logs (`pm.generarqr` → `WorkspaceFlowInlineImageLogLine`).
enum PMQRCodeConsoleRenderer {
    /// Escribe un PNG cuadrado (alto contraste) en un temporal para `WorkspaceFlowInlineImageLogLine` (opción 1).
    static func writeQRPNGToTemporaryFile(for string: String, pixelSize: Int = 512) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        #if canImport(CoreImage)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let native = output.extent
        guard native.width > 1, native.height > 1 else { return nil }

        let side = max(64, min(pixelSize, 2048))
        let scale = CGFloat(side) / max(native.width, native.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral

        let ciContext = CIContext(options: nil)
        guard let cgImage = ciContext.createCGImage(scaled, from: extent) else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("efby-qr-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
        #else
        return nil
        #endif
    }
}
