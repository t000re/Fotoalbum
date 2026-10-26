import ImageIO
import SwiftUI

/// Lager nedskalerte versjoner av bildene (raskt, uten å lese hele fila inn i full størrelse)
/// og husker dem i minnet så rutenettet blir raskt å rulle i.
enum Thumbnails {
    private static let cache = NSCache<NSString, CGImage>()

    static func load(_ url: URL, maxPixels: Int) async -> CGImage? {
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { make(url, maxPixels: maxPixels) }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func make(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // snu riktig vei etter EXIF-retning
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Viser et bilde i en gitt størrelse; grå flate mens det lastes.
struct PhotoImage: View {
    let url: URL
    let maxPixels: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) { image = await Thumbnails.load(url, maxPixels: maxPixels) }
    }
}
