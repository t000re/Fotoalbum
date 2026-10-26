import CoreLocation
import Foundation

/// Region og land fra Apples stedsoppslag.
struct RegionPair: Hashable {
    let region: String?
    let country: String?
}

/// Grensene i appen er forenklet, så et punkt nær en grense (Manhattan ved Hudson-elva) kan havne i feil
/// delstat. For slike bilder spør vi Apples stedsoppslag om delstaten (bare kartpunktet sendes).
/// Én om gangen med litt pause, fordi Apple begrenser antall oppslag per minutt.
extension AppModel {
    /// Legger bildet i køen hvis punktet er nær en grense (flere regioner innen 5 km).
    func enqueueRegionCheck(_ id: String, at p: GeoPoint) {
        let regions = filterCodes(p).filter { !$0.hasPrefix("land:") }
        guard regions.count > 1 else { return }
        regionCheckQueue.append((id, p))
        guard !regionCheckRunning else { return }
        regionCheckRunning = true
        Task { await runRegionChecks() }
    }

    private func runRegionChecks() async {
        while !regionCheckQueue.isEmpty {
            let (id, p) = regionCheckQueue.removeFirst()
            let key = Self.regionKey(p)
            var pair = geocodedRegions[key]
            if pair == nil {
                pair = await Self.lookUpRegionAtApple(p)
                if let pair { geocodedRegions[key] = pair }
                try? await Task.sleep(for: .milliseconds(1300))
            }
            // Bare hvis bildet fortsatt har samme kartpunkt og du ikke har valgt regionen selv.
            guard let pair, pair.region != nil || pair.country != nil,
                  var info = project.photos[id], info.regionManual != true,
                  info.place?.latitude == p.lat, info.place?.longitude == p.lon,
                  info.regionCode != pair.region || info.countryCode != pair.country else { continue }
            info.regionCode = pair.region ?? info.regionCode
            info.countryCode = pair.country ?? info.countryCode
            project.photos[id] = info
            scheduleSave()
        }
        regionCheckRunning = false
    }

    /// Delstat/fylke og land for et punkt fra Apple, oversatt til regionkodene i appen.
    nonisolated static func lookUpRegionAtApple(_ p: GeoPoint) async -> RegionPair? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: p.lat, longitude: p.lon), preferredLocale: Locale(identifier: "en_US")).first,
              let country = placemark.isoCountryCode else { return nil }
        guard let admin = placemark.administrativeArea, !admin.isEmpty else { return RegionPair(region: nil, country: country) }
        // USA, Canada, Australia o.l.: forkortelse («NY» → «US-NY»). Ellers: navnet i samme land.
        if let byCode = World.region(code: "\(country)-\(admin)") { return RegionPair(region: byCode.code, country: country) }
        let byName = World.regions.first {
            $0.country == country && $0.name.compare(admin, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return RegionPair(region: byName?.code, country: country)
    }
}
