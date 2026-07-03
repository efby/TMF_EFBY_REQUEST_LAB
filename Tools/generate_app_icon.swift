import AppKit
import CoreGraphics
import Foundation

struct IconGenerator {
    let inputURL: URL
    let outputURL: URL
    let canvasSize = CGSize(width: 1024, height: 1024)

    func run() throws {
        guard let sourceImage = loadSourceImage() else {
            throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to load source image at \(inputURL.path)"])
        }

        let cropped = cropWhitespace(from: sourceImage) ?? sourceImage
        let mark = makeLightPixelsTransparent(in: cropped) ?? cropped
        let paddedMark = addTransparentPadding(to: mark, horizontal: 88, vertical: 56) ?? mark
        let rendered = renderIcon(using: paddedMark)

        guard let tiffData = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode rendered icon as PNG"])
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: outputURL)
    }

    private func loadSourceImage() -> NSImage? {
        let ext = inputURL.pathExtension.lowercased()
        if ext == "ai" || ext == "pdf" {
            guard let pdfDocument = CGPDFDocument(inputURL as CFURL),
                  let page = pdfDocument.page(at: 1) else { return nil }

            let mediaRect = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 4
            let renderedWidth = Int(mediaRect.width * scale)
            let renderedHeight = Int(mediaRect.height * scale)

            guard let context = CGContext(
                data: nil,
                width: renderedWidth,
                height: renderedHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(renderedHeight))
            context.scaleBy(x: scale, y: -scale)
            context.drawPDFPage(page)

            guard let cgImage = context.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: renderedWidth, height: renderedHeight))
        }

        return NSImage(contentsOf: inputURL)
    }

    private func cropWhitespace(from image: NSImage) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return nil }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let threshold: CGFloat = 0.95

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var found = false

        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent < 0.05 { continue }
                let isNearWhite = color.redComponent >= threshold && color.greenComponent >= threshold && color.blueComponent >= threshold
                if !isNearWhite {
                    found = true
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard found else { return nil }

        let padding = max(width, height) / 8
        let originX = max(minX - padding, 0)
        let originY = max(minY - padding, 0)
        let cropWidth = min((maxX - minX) + (padding * 2), width - originX)
        let cropHeight = min((maxY - minY) + (padding * 2), height - originY)
        let cropRect = NSRect(x: originX, y: originY, width: cropWidth, height: cropHeight)

        guard let cgImage = bitmap.cgImage?.cropping(to: cropRect) else { return nil }
        let cropped = NSImage(cgImage: cgImage, size: cropRect.size)
        return cropped
    }

    private func makeLightPixelsTransparent(in image: NSImage) -> NSImage? {
        guard let sourceBitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return nil }

        let width = sourceBitmap.pixelsWide
        let height = sourceBitmap.pixelsHigh

        guard let transparentBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        transparentBitmap.size = NSSize(width: width, height: height)

        for y in 0..<height {
            for x in 0..<width {
                guard let color = sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }

                let isNearWhite = color.redComponent >= 0.95 && color.greenComponent >= 0.95 && color.blueComponent >= 0.95
                let alpha = isNearWhite ? CGFloat(0) : color.alphaComponent
                let output = NSColor(
                    calibratedRed: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent,
                    alpha: alpha
                )
                transparentBitmap.setColor(output, atX: x, y: y)
            }
        }

        guard let cgImage = transparentBitmap.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func addTransparentPadding(to image: NSImage, horizontal: CGFloat, vertical: CGFloat) -> NSImage? {
        let newSize = NSSize(
            width: image.size.width + (horizontal * 2),
            height: image.size.height + (vertical * 2)
        )

        let padded = NSImage(size: newSize)
        padded.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(
                x: horizontal,
                y: vertical,
                width: image.size.width,
                height: image.size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        padded.unlockFocus()
        return padded
    }

    private func renderIcon(using logo: NSImage) -> NSImage {
        let image = NSImage(size: canvasSize)
        image.lockFocus()

        let fullRect = NSRect(origin: .zero, size: canvasSize)
        let outerRect = fullRect.insetBy(dx: 42, dy: 42)
        let logoPanelRect = NSRect(
            x: outerRect.minX + 96,
            y: outerRect.minY + 244,
            width: outerRect.width - 192,
            height: outerRect.height - 452
        )
        let badgeWidth: CGFloat = 660
        let badgeHeight: CGFloat = 168
        let badgeTrailingPadding: CGFloat = 36
        let badgeRect = NSRect(
            x: outerRect.maxX - badgeWidth - badgeTrailingPadding,
            y: outerRect.minY + 78,
            width: badgeWidth,
            height: badgeHeight
        )

        let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 220, yRadius: 220)

        NSGraphicsContext.current?.imageInterpolation = .high

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.22, alpha: 1)
        ])
        gradient?.draw(in: outerPath, angle: 90)

        NSGraphicsContext.saveGraphicsState()

        let highlight = NSBezierPath(roundedRect: outerRect.insetBy(dx: 10, dy: 10), xRadius: 204, yRadius: 204)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        highlight.lineWidth = 3
        highlight.stroke()

        let panelPath = NSBezierPath(roundedRect: logoPanelRect, xRadius: 74, yRadius: 74)
        NSColor.white.setFill()
        panelPath.fill()

        NSColor.white.withAlphaComponent(0.20).setStroke()
        panelPath.lineWidth = 4
        panelPath.stroke()

        let fittedRect = fittedRect(for: logo.size, in: NSRect(
            x: logoPanelRect.minX + 10,
            y: logoPanelRect.minY + 4,
            width: logoPanelRect.width - 20,
            height: logoPanelRect.height - 8
        ))
        logo.draw(in: fittedRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 56, yRadius: 56)
        let badgeGradient = NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.49, blue: 0.34, alpha: 0.98),
            NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.36, alpha: 0.98)
        ])
        badgeGradient?.draw(in: badgePath, angle: 0)

        let badgeShadow = NSShadow()
        badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        badgeShadow.shadowBlurRadius = 18
        badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        badgeShadow.set()
        badgePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 114, weight: .black),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let badgeText = NSAttributedString(string: "#Request", attributes: attributes)
        let textRect = NSRect(
            x: badgeRect.minX,
            y: badgeRect.minY + 24,
            width: badgeRect.width,
            height: badgeRect.height
        )
        badgeText.draw(in: textRect)

        image.unlockFocus()
        return image
    }

    private func fittedRect(for sourceSize: CGSize, in bounds: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: bounds.midX - (size.width / 2),
            y: bounds.midY - (size.height / 2)
        )
        return NSRect(origin: origin, size: size)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: generate_app_icon.swift <input-image> <output-png>\n", stderr)
    exit(1)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

do {
    try IconGenerator(inputURL: inputURL, outputURL: outputURL).run()
    print("Generated icon PNG at \(outputURL.path)")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
