import AppKit
import CoreGraphics
import CoreText

/// Teksten under et bilde: sted og dato på første linje, beskrivelsen under.
struct Caption: Hashable {
    var heading: String
    var body: String
    var isEmpty: Bool { heading.isEmpty && body.isEmpty }
}

/// Tegner én side med Core Graphics. Samme kode brukes til forhåndsvisning og PDF,
/// så det du ser er det som trykkes.
enum PageRenderer {
    // Typografi i utkastet. Justeres etter Figma-skissen.
    static let headingFont = "AkkuratStd-Regular"
    static let bodyFont = "AkkuratStd-Light"
    static let fontSize: CGFloat = 8.5
    static let lineHeight: CGFloat = 11

    /// Ren svart (DeviceGray 0 = 100 % K på trykk) og hvitt.
    static let black = CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [0, 1])!
    static let white = CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [1, 1])!

    /// Tegner siden i `ctx`. Koordinatsystemet må være punkter med origo nede til venstre på hele
    /// PDF-siden (format.pageSize: kutt + utfallende kant på topp, bunn og ytterkant).
    static func draw(_ page: BookPage, format: BookFormat, isRight: Bool, in ctx: CGContext,
                     images: [String: CGImage], captions: [String: Caption], map: MapData? = nil) {
        let b = BookFormat.bleed
        let full = format.pageSize
        // Høyresider har ryggen til venstre (ingen utfallende kant der), venstresider motsatt.
        let trimX: CGFloat = isRight ? 0 : b

        // Hvitt papir.
        ctx.setFillColor(white)
        ctx.fill(CGRect(origin: .zero, size: full))

        // Fra «øvre venstre hjørne av kuttet, y nedover» til Core Graphics' «nede til venstre, y oppover».
        func cg(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX + trimX, y: full.height - (r.maxY + b), width: r.width, height: r.height)
        }

        let aspect: (String) -> CGFloat = { id in
            guard let image = images[id] else { return 1.5 }
            return CGFloat(image.width) / CGFloat(image.height)
        }
        let layout = PageGeometry.layout(for: page, format: format, isRight: isRight, showMap: map != nil, aspect: aspect)
        for slot in layout.slots {
            let rect = cg(slot.photoRect)
            if let image = images[slot.photo] {
                drawImage(image, in: rect, fill: slot.fill, ctx: ctx)
            } else {
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(rect)
            }
            if let captionRect = slot.captionRect, let caption = captions[slot.photo], !caption.isEmpty {
                drawText(caption, in: cg(captionRect), ctx: ctx)
            }
        }
        if let map, let rect = layout.map {
            if page.layout == .fullBleed {
                // Hvitt felt bak kartet når det ligger oppå et bilde.
                ctx.setFillColor(white)
                ctx.addPath(CGPath(roundedRect: cg(rect).insetBy(dx: -6, dy: -6), cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.fillPath()
            }
            MapRenderer.draw(map, in: cg(rect), ctx: ctx)
        }
    }

    /// Bildet i rammen. Med `fill` fyller det rammen og beskjæres likt på begge sider.
    private static func drawImage(_ image: CGImage, in rect: CGRect, fill: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.clip(to: rect)
        var target = rect
        if fill {
            let a = CGFloat(image.width) / CGFloat(image.height)
            if rect.width / rect.height > a {
                target.size.height = rect.width / a
            } else {
                target.size.width = rect.height * a
            }
            target.origin = CGPoint(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: target)
        ctx.restoreGState()
    }

    /// Teksten i ren svart (100 % K på trykk).
    private static func drawText(_ caption: Caption, in rect: CGRect, ctx: CGContext) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        func attributes(_ fontName: String) -> [NSAttributedString.Key: Any] {
            let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            return [.font: font, .paragraphStyle: paragraph,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): black]
        }
        let text = NSMutableAttributedString()
        if !caption.heading.isEmpty { text.append(NSAttributedString(string: caption.heading, attributes: attributes(headingFont))) }
        if !caption.body.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: attributes(headingFont))) }
            text.append(NSAttributedString(string: caption.body, attributes: attributes(bodyFont)))
        }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// Siden som bilde til skjermen. `showBleed: false` viser bare det som er innenfor kuttet.
    static func image(_ page: BookPage, format: BookFormat, isRight: Bool, pixelWidth: Int, showBleed: Bool,
                      images: [String: CGImage], captions: [String: Caption], map: MapData? = nil) -> CGImage? {
        let b = BookFormat.bleed
        let size = showBleed ? format.pageSize : format.trim
        let scale = CGFloat(pixelWidth) / size.width
        let pixelHeight = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if !showBleed { ctx.translateBy(x: isRight ? 0 : -b, y: -b) }
        draw(page, format: format, isRight: isRight, in: ctx, images: images, captions: captions, map: map)
        return ctx.makeImage()
    }
}
