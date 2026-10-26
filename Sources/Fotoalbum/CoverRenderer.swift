import AppKit
import CoreGraphics
import CoreText

/// Tegner smussomslaget med Core Graphics, til forhåndsvisning og PDF.
/// Forside og bakside: bildet over hele flaten (til brettene og ut i utfallende kant).
/// Tittel nede til venstre på forsiden og på ryggen (lest ovenfra og ned). Klaffene er hvite,
/// med kartet over hele ruten på bakre klaff.
enum CoverRenderer {
    static let titleFont = "AkkuratStd-Bold"
    static let subtitleFont = "AkkuratStd-Regular"

    /// `ctx` i punkter med origo nede til venstre på hele PDF-siden (spec.pageSize).
    static func draw(_ cover: Cover, spec: CoverSpec, in ctx: CGContext,
                     images: [String: CGImage], routeMap: MapData?, customMaxPixels: Int = 10000) {
        let b = CoverSpec.bleed
        let full = spec.pageSize
        // Eget omslag: fila fyller hele flaten, utfallende kant inkludert.
        if cover.useCustom, let path = cover.customFile {
            ctx.setFillColor(PageRenderer.white)
            ctx.fill(CGRect(origin: .zero, size: full))
            CoverTemplate.draw(URL(fileURLWithPath: path), in: CGRect(origin: .zero, size: full), ctx: ctx,
                               maxPixels: customMaxPixels)
            return
        }
        func cg(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX + b, y: full.height - (r.maxY + b), width: r.width, height: r.height)
        }
        /// En del av omslaget utvidet ut i utfallende kant (topp og bunn, og ytterkant for klaffene).
        func bled(_ r: CGRect, left: Bool = false, right: Bool = false) -> CGRect {
            CGRect(x: r.minX - (left ? b : 0), y: r.minY - b,
                   width: r.width + (left ? b : 0) + (right ? b : 0), height: r.height + 2 * b)
        }

        ctx.setFillColor(PageRenderer.white)
        ctx.fill(CGRect(origin: .zero, size: full))

        // Bildene på bakside og forside.
        if let id = cover.backPhoto, let image = images[id] {
            fill(image, in: cg(bled(spec.back)), ctx: ctx)
        }
        if let id = cover.frontPhoto, let image = images[id] {
            fill(image, in: cg(bled(spec.front)), ctx: ctx)
        }

        let color = cover.whiteTitle && cover.frontPhoto != nil ? PageRenderer.white : PageRenderer.black

        // Tittel på forsiden, nede til venstre innenfor sikker sone.
        let inset = CoverSpec.safe + 18
        let titleBox = CGRect(x: spec.front.minX + inset, y: spec.front.maxY - inset - 80,
                              width: spec.front.width - 2 * inset, height: 80)
        drawText([(cover.title, titleFont, 30), (cover.subtitle, subtitleFont, 12)],
                 in: cg(titleBox), color: color, bottomAligned: true, ctx: ctx)

        // Ryggen: hvit, med tittel lest ovenfra og ned, midtstilt.
        let spineText = [cover.title, cover.subtitle].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        if spec.spineWidth >= 20, !spineText.isEmpty {
            let r = cg(spec.spine)
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: -.pi / 2)
            let size = min(11, spec.spineWidth * 0.32)
            let box = CGRect(x: -r.height / 2 + CoverSpec.safe, y: -size * 0.7, width: r.height - 2 * CoverSpec.safe, height: size * 1.6)
            drawText([(spineText, subtitleFont, size)], in: box, color: PageRenderer.black, centered: true, ctx: ctx)
            ctx.restoreGState()
        }

        // Kartet med hele ruten på bakre klaff.
        if cover.mapOnFlap, let routeMap {
            let width = spec.flapWidth - 2 * inset
            let height = width / MapRenderer.aspect
            let rect = CGRect(x: spec.backFlap.minX + inset, y: spec.backFlap.midY - height / 2, width: width, height: height)
            MapRenderer.draw(routeMap, in: cg(rect), ctx: ctx)
        }
    }

    private static func fill(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let a = CGFloat(image.width) / CGFloat(image.height)
        var target = rect
        if rect.width / rect.height > a { target.size.height = rect.width / a } else { target.size.width = rect.height * a }
        target.origin = CGPoint(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: target)
        ctx.restoreGState()
    }

    /// Linjer med hver sin font og størrelse.
    private static func drawText(_ lines: [(String, String, CGFloat)], in rect: CGRect, color: CGColor,
                                 bottomAligned: Bool = false, centered: Bool = false, ctx: CGContext) {
        let text = NSMutableAttributedString()
        for (string, fontName, size) in lines where !string.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .left
            let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: string, attributes: [
                .font: font, .paragraphStyle: paragraph,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]))
        }
        guard text.length > 0 else { return }
        let setter = CTFramesetterCreateWithAttributedString(text)
        var box = rect
        if bottomAligned {
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                      CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            box = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ceil(needed.height))
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// Omslaget som bilde til skjermen (hele flaten med utfallende kant).
    static func image(_ cover: Cover, spec: CoverSpec, pixelWidth: Int,
                      images: [String: CGImage], routeMap: MapData?) -> CGImage? {
        let size = spec.pageSize
        let scale = CGFloat(pixelWidth) / size.width
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: Int((size.height * scale).rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(cover, spec: spec, in: ctx, images: images, routeMap: routeMap, customMaxPixels: pixelWidth)
        return ctx.makeImage()
    }
}
