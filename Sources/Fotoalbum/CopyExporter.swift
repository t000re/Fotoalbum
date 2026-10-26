import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lager kopier av skanningene med nye navn (220714_yosemite-national-park_01.jpg) og med dato,
/// sted og beskrivelse skrevet inn i bildet. Originalene røres ikke.
/// Bildedataene kopieres uendret (ingen ny JPEG-komprimering); bare metadata legges til.
enum CopyExporter {
    /// Ett bilde som skal kopieres.
    struct Item {
        let source: URL
        let name: String
        let info: PhotoInfo
        /// Tidssonen for bildets region/land (slått opp før eksporten), når bildet ikke har sin egen.
        var zoneHint: String? = nil
    }

    // MARK: Filnavn

    /// Filnavn for bildene, i tidsrekkefølgen de står i. Flere bilder fra samme dag og sted
    /// nummereres 01, 02 … Bilder uten dato beholder det gamle navnet med «udatert_» foran.
    static func names(for ids: [String], info: (String) -> PhotoInfo) -> [String: String] {
        var counts: [String: Int] = [:]
        var bases: [(id: String, base: String)] = []
        for id in ids {
            let i = info(id)
            let base: String
            if let day = i.day {
                let place = slug(i.place?.name ?? i.regionCode.flatMap { World.region(code: $0)?.name } ?? "")
                base = String(format: "%02d%02d%02d", day.year % 100, day.month, day.day) + "_" + (place.isEmpty ? "ukjent-sted" : place)
            } else {
                base = "udatert_" + slug((id as NSString).deletingPathExtension)
            }
            counts[base, default: 0] += 1
            bases.append((id, base))
        }
        var used: [String: Int] = [:]
        var result: [String: String] = [:]
        for (id, base) in bases {
            used[base, default: 0] += 1
            let digits = counts[base]! > 99 ? 3 : 2
            let ext = (id as NSString).pathExtension.lowercased()
            result[id] = base + "_" + String(format: "%0\(digits)d", used[base]!) + "." + (ext == "jpeg" ? "jpg" : ext)
        }
        return result
    }

    /// «Yosemite National Park» → «yosemite-national-park». Æ, ø og å blir ae, o og a.
    static func slug(_ text: String) -> String {
        let replaced = text.lowercased()
            .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "å", with: "a")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        var result = ""
        for ch in replaced {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { result.append(ch) }
            else if !result.hasSuffix("-") { result.append("-") }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Skriving

    /// Kopierer alle bildene til `folder`. `progress` kalles med antall ferdige.
    /// Returnerer bildene som ikke kunne kopieres.
    static func export(_ items: [Item], to folder: URL, progress: @escaping @Sendable (Int) -> Void) -> [String] {
        var failed: [String] = []
        for (index, item) in items.enumerated() {
            let target = folder.appendingPathComponent(item.name)
            if !write(item, to: target) { failed.append(item.source.lastPathComponent) }
            progress(index + 1)
        }
        return failed
    }

    /// Én kopi: samme bildedata, med metadata flettet inn.
    private static func write(_ item: Item, to target: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(item.source as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return false }
        try? FileManager.default.removeItem(at: target)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata(for: item.info, zoneHint: item.zoneHint),
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
    }

    /// Dato og klokkeslett (EXIF), GPS, stedsnavn og beskrivelse (IPTC), slik Bilder og Lightroom leser dem.
    private static func metadata(for info: PhotoInfo, zoneHint: String?) -> CGImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
            CGImageMetadataSetValueMatchingImageProperty(meta, dictionary, key, value as CFTypeRef)
        }

        if let day = info.day {
            // Klokkeslett fra iPhone-bildet i lokal tid der bildet ble tatt; ellers kl. 12.
            // Tidssone: fra stedsoppslaget, ellers omtrentlig fra kartpunktet, regionen eller landet.
            var zone = TimeZone.current
            if let id = info.timeZone ?? zoneHint, let exact = TimeZone(identifier: id) {
                zone = exact
            } else if let lat = info.place?.latitude, let lon = info.place?.longitude {
                zone = PhoneLibrary.approximateZone(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            } else if let area = info.regionCode.flatMap({ World.region(code: $0) }) ?? info.countryCode.flatMap({ World.country(code: $0) }) {
                zone = PhoneLibrary.approximateZone(CLLocationCoordinate2D(latitude: (area.minLat + area.maxLat) / 2,
                                                                           longitude: (area.minLon + area.maxLon) / 2))
            }
            var dateText = String(format: "%04d:%02d:%02d 12:00:00", day.year, day.month, day.day)
            if let time = info.time {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = zone
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                let text = f.string(from: time)
                // Bare hvis klokkeslettet faktisk er på samme dag som datoen.
                if text.hasPrefix(String(format: "%04d:%02d:%02d", day.year, day.month, day.day)) { dateText = text }
            }
            let seconds = zone.secondsFromGMT(for: info.time ?? day.date)
            let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, dateText)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, dateText)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offset)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, dateText)
        }

        if let place = info.place {
            if let lat = place.latitude, let lon = place.longitude {
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(lat))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, lat >= 0 ? "N" : "S")
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(lon))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, lon >= 0 ? "E" : "W")
            }
            if !place.name.isEmpty {
                set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCSubLocation, place.name)
            }
        }

        // Region (delstat, fylke, provins) og land – også for bilder som bare har region.
        let regionName = info.regionCode.flatMap { World.region(code: $0)?.name }
        let countryCode = info.countryCode ?? info.regionCode.flatMap { World.region(code: $0)?.country }
        let countryName = countryCode.map(World.countryName)
        if let regionName { set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCProvinceState, regionName) }
        if let countryName { set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCountryPrimaryLocationName, countryName) }
        if let countryCode { set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCountryPrimaryLocationCode, countryCode) }

        // Sted, region og land som søkeord, så bildene kan finnes på «Texas» eller «USA» i Bilder/Lightroom.
        var keywords: [String] = []
        for word in [info.place?.name, regionName, countryName].compactMap({ $0 }) where !word.isEmpty && !keywords.contains(word) {
            keywords.append(word)
        }
        if !keywords.isEmpty { set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, keywords) }

        let caption = info.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty {
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, caption)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, caption)
        }
        return meta
    }
}
