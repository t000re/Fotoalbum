import Foundation
import ImageIO

/// Rullrekkefølge: bildene i den rekkefølgen de ble skannet (skannetid i fila, ellers filnavn).
/// Analoge bilder ligger i rekkefølge på rullen, så bilder uten dato og sted kan få forslag fra
/// bildene rundt seg.
extension AppModel {
    /// Leser skannetiden for alle bildene (i bakgrunnen). Kalles når mappa er lest.
    func loadScanTimes() {
        let photos = photos
        Task {
            let times = await Task.detached(priority: .utility) {
                var result: [String: Date] = [:]
                for photo in photos { if let t = Self.scanTime(photo.url) { result[photo.id] = t } }
                return result
            }.value
            scanTimes = times
        }
    }

    /// Når bildet ble skannet: EXIF-opptakstid, ellers TIFF-tid. (Ikke filens endringsdato, den
    /// er fra eksporten.)
    nonisolated static func scanTime(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard var text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? exif?[kCGImagePropertyExifDateTimeDigitized]
                          ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
        // Brøkdeler av sekund, så bilder skannet i samme sekund holder rekkefølgen.
        if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String { text += "." + sub }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = text.contains(".") ? "yyyy:MM:dd HH:mm:ss.SSS" : "yyyy:MM:dd HH:mm:ss"
        return f.date(from: String(text.prefix(text.contains(".") ? 23 : 19)))
    }

    /// Bildene i rullrekkefølge: med skannetid først (i tidsrekkefølge), så resten etter filnavn.
    var rollOrder: [String] {
        let ids = photos.map(\.id)  // allerede sortert etter filnavn
        let timed = ids.filter { scanTimes[$0] != nil }.sorted { scanTimes[$0]! < scanTimes[$1]! }
        return timed + ids.filter { scanTimes[$0] == nil }
    }

    /// Nærmeste bilde med dato eller sted før og etter på rullen (innen 6 bilder).
    func rollNeighbors(of id: String) -> (before: (id: String, steps: Int)?, after: (id: String, steps: Int)?) {
        let order = rollOrder
        guard let index = order.firstIndex(of: id) else { return (nil, nil) }
        func find(_ step: Int) -> (String, Int)? {
            var i = index + step, steps = 1
            while order.indices.contains(i), steps <= 6 {
                let info = info(order[i])
                if info.day != nil || info.place != nil { return (order[i], steps) }
                i += step; steps += 1
            }
            return nil
        }
        return (find(-1), find(1))
    }

    /// Fyller inn dato og sted på bilder som ligger mellom to bilder med samme dato og sted på rullen
    /// (og mangler begge deler selv). Returnerer antall bilder som ble fylt inn.
    @discardableResult
    func fillBetweenEqualNeighbors() -> Int {
        let order = rollOrder
        var filled = 0
        var lastKnown: (index: Int, day: Day?, place: Place?)?
        for (i, id) in order.enumerated() {
            let info = info(id)
            guard info.day != nil || info.place != nil else { continue }
            if let last = lastKnown, i - last.index > 1, last.day == info.day, last.place?.name == info.place?.name,
               info.day != nil, info.place != nil {
                for gap in order[(last.index + 1)..<i] where self.info(gap).day == nil && self.info(gap).place == nil {
                    let area = (self.info(order[last.index]).area == info.area) ? info.area : nil
                    update(gap) { $0.day = info.day; $0.place = last.place; $0.area = area; $0.source = .roll }
                    filled += 1
                }
            }
            lastKnown = (i, info.day, info.place)
        }
        return filled
    }
}
