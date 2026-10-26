import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lager innmat-PDF-en til Blurb: én PDF-side per bokside, med trim- og bleed-boks, bildene i
/// 300 ppi (eller originalen hvis den er mindre) lagret som JPEG, og tekst i 100 % svart.
/// Sidene tegnes med PageRenderer, akkurat som i forhåndsvisningen.
enum PDFExporter {
    /// Én side som skal i PDF-en.
    struct Job {
        let page: BookPage
        let isRight: Bool
        let sources: [String: URL]
        let captions: [String: Caption]
        let map: MapData?
    }

    static let printPPI: CGFloat = 300

    /// Skriver PDF-en. Returnerer feilmelding, eller nil når alt gikk bra.
    static func export(_ jobs: [Job], format: BookFormat, title: String, to url: URL,
                       progress: @escaping @Sendable (Int) -> Void) -> String? {
        var media = CGRect(origin: .zero, size: format.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Fotoalbum"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            return "Kunne ikke lage PDF-fila."
        }
        let b = BookFormat.bleed
        for (index, job) in jobs.enumerated() {
            // Kuttet: på høyresider helt til venstre (ryggen), på venstresider etter utfallende kant.
            let trim = CGRect(x: job.isRight ? 0 : b, y: b, width: format.trim.width, height: format.trim.height)
            let boxes: [CFString: Any] = [
                kCGPDFContextMediaBox: data(media),
                kCGPDFContextBleedBox: data(media),
                kCGPDFContextTrimBox: data(trim),
            ]
            ctx.beginPDFPage(boxes as CFDictionary)
            autoreleasepool {
                let images = loadImages(for: job, format: format)
                PageRenderer.draw(job.page, format: format, isRight: job.isRight, in: ctx,
                                  images: images, captions: job.captions, map: job.map)
            }
            ctx.endPDFPage()
            progress(index + 1)
        }
        ctx.closePDF()
        return nil
    }

    /// Omslaget som én PDF-side med kutt- og bleed-boks.
    static func exportCover(_ cover: Cover, spec: CoverSpec, sources: [String: URL], routeMap: MapData?,
                            title: String, to url: URL) -> String? {
        var media = CGRect(origin: .zero, size: spec.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title + " – omslag", kCGPDFContextCreator: "Fotoalbum"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            return "Kunne ikke lage PDF-fila."
        }
        let trim = media.insetBy(dx: CoverSpec.bleed, dy: CoverSpec.bleed)
        ctx.beginPDFPage([kCGPDFContextMediaBox: data(media), kCGPDFContextBleedBox: data(media),
                          kCGPDFContextTrimBox: data(trim)] as CFDictionary)
        // Bildene fyller forside/bakside med utfallende kant: 300 ppi av den største siden.
        let needed = Int((max(spec.panel.width, spec.panel.height) + 2 * CoverSpec.bleed) / 72 * printPPI * 1.4)
        var images: [String: CGImage] = [:]
        for (id, source) in sources { images[id] = printImage(source, maxPixels: needed) }
        CoverRenderer.draw(cover, spec: spec, in: ctx, images: images, routeMap: routeMap,
                           customMaxPixels: CoverTemplate.px(spec.pageSize.width))
        ctx.endPDFPage()
        ctx.closePDF()
        return nil
    }

    private static func data(_ rect: CGRect) -> CFData {
        var r = rect
        return withUnsafeBytes(of: &r) { Data($0) } as CFData
    }

    // MARK: Bilder i trykkoppløsning

    /// Bildene på siden, skalert til 300 ppi i den størrelsen de får på siden.
    private static func loadImages(for job: Job, format: BookFormat) -> [String: CGImage] {
        // Bildeforholdet trengs for å vite hvor stort hvert bilde blir; det leses uten å åpne bildet.
        var aspects: [String: CGFloat] = [:]
        for (id, url) in job.sources {
            if let size = pixelSize(url) { aspects[id] = size.width / size.height }
        }
        let layout = PageGeometry.layout(for: job.page, format: format, isRight: job.isRight,
                                         showMap: job.map != nil, aspect: { aspects[$0] ?? 1.5 })
        var images: [String: CGImage] = [:]
        for slot in layout.slots {
            guard let url = job.sources[slot.photo], let a = aspects[slot.photo] else { continue }
            // Størrelsen bildet tegnes i (utfallende bilder er større enn rammen og beskjæres).
            var drawn = slot.photoRect.size
            if slot.fill {
                drawn = drawn.width / drawn.height > a
                    ? CGSize(width: drawn.width, height: drawn.width / a)
                    : CGSize(width: drawn.height * a, height: drawn.height)
            }
            let needed = Int((max(drawn.width, drawn.height) / 72 * printPPI).rounded(.up))
            images[slot.photo] = printImage(url, maxPixels: needed)
        }
        return images
    }

    /// Bildets størrelse i piksler, rett vei (etter EXIF-retning).
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Bildet til trykk: originalen hvis den er en sRGB-JPEG som ikke er større enn nødvendig
    /// (da legges JPEG-dataene rett inn i PDF-en), ellers nedskalert, gjort om til sRGB og lagret
    /// som JPEG i høy kvalitet.
    static func printImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier

        if isJPEG, orientation == 1, max(w, h) <= maxPixels,
           let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
           original.colorSpace?.name == CGColorSpace.sRGB {
            return original
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(w, h)),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let srgb = toSRGB(scaled) ?? scaled

        // Som JPEG, så PDF-en ikke blir enorm.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return srgb }
        CGImageDestinationAddImage(destination, srgb, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let jpegSource = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else { return srgb }
        return jpeg
    }

    /// Gjør om til sRGB (Blurb vil ha sRGB eller CMYK).
    private static func toSRGB(_ image: CGImage) -> CGImage? {
        if image.colorSpace?.name == CGColorSpace.sRGB { return image }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
