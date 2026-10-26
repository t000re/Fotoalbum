import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Til deg som lager omslaget selv i Figma eller Photoshop: målene, en mal med hjelpelinjer,
/// og innlesing av det ferdige omslaget (bilde eller PDF).
enum CoverTemplate {
    static let ppi: CGFloat = 300

    static func px(_ pt: CGFloat) -> Int { Int((pt / 72 * ppi).rounded()) }
    static func mm(_ pt: CGFloat) -> String { String(format: "%.1f mm", pt / 72 * 25.4).replacingOccurrences(of: ".", with: ",") }

    /// Én linje i måltabellen.
    struct Measure: Identifiable {
        let name: String
        let pt: CGFloat
        var id: String { name }
        var pxText: String { "\(CoverTemplate.px(pt)) px" }
        var mmText: String { CoverTemplate.mm(pt) }
        var ptText: String { String(format: "%.0f pt", pt) }
    }

    /// Bredder fra venstre, og høyden.
    static func measures(_ spec: CoverSpec) -> [Measure] {
        [
            Measure(name: "Hele fila, bredde", pt: spec.pageSize.width),
            Measure(name: "Hele fila, høyde", pt: spec.pageSize.height),
            Measure(name: "Utfallende kant (alle sider)", pt: CoverSpec.bleed),
            Measure(name: "Bakre klaff", pt: spec.flapWidth),
            Measure(name: "Bakside", pt: spec.panel.width),
            Measure(name: "Rygg", pt: spec.spineWidth),
            Measure(name: "Forside", pt: spec.panel.width),
            Measure(name: "Fremre klaff", pt: spec.flapWidth),
            Measure(name: "Høyde etter kutt", pt: spec.panel.height),
            Measure(name: "Sikker sone (fra kutt og bretter)", pt: CoverSpec.safe),
        ]
    }

    /// Hvor brettene og kuttet ligger, målt fra venstre kant av fila (med utfallende kant).
    static func lines(_ spec: CoverSpec) -> [(name: String, pt: CGFloat)] {
        let b = CoverSpec.bleed
        return [
            ("Kutt venstre", b),
            ("Brett klaff | bakside", b + spec.back.minX),
            ("Brett bakside | rygg", b + spec.spine.minX),
            ("Brett rygg | forside", b + spec.spine.maxX),
            ("Brett forside | klaff", b + spec.front.maxX),
            ("Kutt høyre", b + spec.trim.width),
        ]
    }

    /// Målene som tekst, til utklippstavlen.
    static func text(_ spec: CoverSpec, pages: Int, paper: Paper, format: BookFormat) -> String {
        var s = "Blurb smussomslag – \(format.name), \(pages) sider, \(paper.name)\n"
        s += "Lag fila i \(px(spec.pageSize.width)) × \(px(spec.pageSize.height)) px (300 ppi), sRGB.\n\n"
        for m in measures(spec) { s += "\(m.name): \(m.pxText) · \(m.mmText) · \(m.ptText)\n" }
        s += "\nLinjer fra venstre kant:\n"
        for l in lines(spec) { s += "\(l.name): \(px(l.pt)) px · \(mm(l.pt))\n" }
        return s
    }

    // MARK: Mal

    /// Malen i 300 ppi: utfallende kant i rødt, kutt i magenta, bretter stiplet i blått,
    /// sikre soner stiplet i grått, og navn og mål på hver flate.
    static func templateImage(_ spec: CoverSpec) -> CGImage? {
        let scale = ppi / 72
        let w = px(spec.pageSize.width), h = px(spec.pageSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let b = CoverSpec.bleed, full = spec.pageSize
        func cg(_ r: CGRect) -> CGRect { CGRect(x: r.minX + b, y: full.height - (r.maxY + b), width: r.width, height: r.height) }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: full))
        // Utfallende kant.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: full))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(cg(CGRect(origin: .zero, size: spec.trim)))
        // Ryggen og klaffene litt grå, så flatene skilles.
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for r in [spec.backFlap, spec.spine, spec.frontFlap] { ctx.fill(cg(r)) }

        // Sikre soner.
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        for r in [spec.backFlap, spec.back, spec.front, spec.frontFlap] {
            ctx.stroke(cg(r.insetBy(dx: CoverSpec.safe, dy: CoverSpec.safe)))
        }
        // Bretter.
        ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 1, alpha: 1))
        ctx.setLineWidth(0.75)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        for x in [spec.back.minX, spec.spine.minX, spec.spine.maxX, spec.front.maxX] {
            ctx.move(to: CGPoint(x: x + b, y: 0))
            ctx.addLine(to: CGPoint(x: x + b, y: full.height))
        }
        ctx.strokePath()
        // Kutt.
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(CGColor(srgbRed: 0.9, green: 0, blue: 0.7, alpha: 1))
        ctx.setLineWidth(0.75)
        ctx.stroke(cg(CGRect(origin: .zero, size: spec.trim)))

        // Navn og mål.
        let parts: [(String, CGRect)] = [("BAKRE KLAFF", spec.backFlap), ("BAKSIDE", spec.back),
                                         ("FORSIDE", spec.front), ("FREMRE KLAFF", spec.frontFlap)]
        for (name, r) in parts {
            label("\(name)\n\(px(r.width)) × \(px(r.height)) px\n\(mm(r.width)) × \(mm(r.height))", in: cg(r), ctx: ctx)
        }
        // Ryggen: rotert tekst.
        let spine = cg(spec.spine)
        ctx.saveGState()
        ctx.translateBy(x: spine.midX, y: spine.midY)
        ctx.rotate(by: -.pi / 2)
        label("RYGG  \(px(spec.spineWidth)) px · \(mm(spec.spineWidth))",
              in: CGRect(x: -spine.height / 2, y: -spine.width / 2, width: spine.height, height: spine.width), ctx: ctx, size: 7)
        ctx.restoreGState()
        // Forklaring nederst på bakre klaff (innenfor kuttet).
        let legend = "Rødt: utfallende kant (beskjæres). Magenta: kutt. Blått stiplet: bretter. Grått stiplet: sikker sone."
        label(legend, in: cg(CGRect(x: spec.backFlap.minX + 22, y: spec.panel.height - 60, width: spec.flapWidth - 44, height: 40)),
              ctx: ctx, size: 5.5)
        return ctx.makeImage()
    }

    private static func label(_ text: String, in rect: CGRect, ctx: CGContext, size: CGFloat = 10) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont(name: "AkkuratStd-Regular", size: size) ?? NSFont.systemFont(ofSize: size)
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1)])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                  CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let box = CGRect(x: rect.minX, y: rect.midY - needed.height / 2, width: rect.width, height: ceil(needed.height) + 1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        let dpi: [CFString: Any] = [kCGImagePropertyDPIWidth: ppi, kCGImagePropertyDPIHeight: ppi]
        CGImageDestinationAddImage(d, image, dpi as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    // MARK: Eget omslag

    /// Størrelsen på et eget omslag: piksler for bilder, punkter for PDF.
    static func size(of url: URL) -> (size: CGSize, isPDF: Bool)? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
            return (page.getBoxRect(.mediaBox).size, true)
        }
        return PDFExporter.pixelSize(url).map { ($0, false) }
    }

    /// Sjekker at det egne omslaget passer. nil = alt i orden, ellers en forklaring.
    static func problem(with url: URL, spec: CoverSpec) -> String? {
        guard let (size, isPDF) = size(of: url) else { return "Fila kan ikke leses." }
        let expected = spec.pageSize.width / spec.pageSize.height
        let actual = size.width / size.height
        if abs(actual - expected) / expected > 0.005 {
            return isPDF
                ? String(format: "PDF-en er %.0f × %.0f pt, men skal være %.0f × %.0f pt.", size.width, size.height, spec.pageSize.width, spec.pageSize.height)
                : "Bildet er \(Int(size.width)) × \(Int(size.height)) px, men skal være \(px(spec.pageSize.width)) × \(px(spec.pageSize.height)) px (samme forhold)."
        }
        if !isPDF, size.width < spec.pageSize.width / 72 * 200 {
            return "Bildet er bare \(Int(size.width)) px bredt. Bruk \(px(spec.pageSize.width)) px (300 ppi) for skarpt trykk."
        }
        return nil
    }

    /// Tegner det egne omslaget over hele flaten (bilde eller første side i en PDF).
    static func draw(_ url: URL, in rect: CGRect, ctx: CGContext, maxPixels: Int) {
        if url.pathExtension.lowercased() == "pdf" {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return }
            let media = page.getBoxRect(.mediaBox)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / media.width, y: rect.height / media.height)
            ctx.translateBy(x: -media.minX, y: -media.minY)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        } else if let image = PDFExporter.printImage(url, maxPixels: maxPixels) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }
}
