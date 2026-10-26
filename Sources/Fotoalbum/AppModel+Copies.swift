import AppKit
import CoreLocation

/// «Eksporter kopier med dato og sted»: nye filer med navn som 220714_yosemite-national-park_01.jpg
/// og metadata i bildet. Originalene røres ikke.
extension AppModel {
    func exportCopies() {
        guard let folder = project.folder.map(URL.init(fileURLWithPath:)), !photos.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Eksporter kopier med dato og sted"
        panel.message = "Velg navn og plassering for en ny mappe med kopiene. Originalene endres ikke."
        panel.prompt = "Eksporter"
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.nameFieldStringValue = folder.lastPathComponent + " – med dato og sted"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        guard target.standardizedFileURL != folder.standardizedFileURL else {
            alert("Velg en annen mappe", "Kopiene kan ikke legges i samme mappe som originalene.")
            return
        }

        // Finnes mappa og har filer, flyttes de gamle til papirkurven (kan hentes tilbake).
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if !existing.isEmpty {
            let confirm = NSAlert()
            confirm.messageText = "Mappa er ikke tom"
            confirm.informativeText = "«\(target.lastPathComponent)» har \(existing.count) filer fra før. De flyttes til papirkurven og erstattes av nye kopier."
            confirm.addButton(withTitle: "Erstatt")
            confirm.addButton(withTitle: "Avbryt")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            for file in existing { try? fm.trashItem(at: file, resultingItemURL: nil) }
        }
        do { try fm.createDirectory(at: target, withIntermediateDirectories: true) } catch {
            alert("Kunne ikke lage mappa", error.localizedDescription)
            return
        }

        // I tidsrekkefølge, så nummereringen følger rekkefølgen bildene ble tatt i.
        let ids = chronology(of: photos.map(\.id)).flatMap { $0.runs.flatMap(\.ids) }
        let names = CopyExporter.names(for: ids, info: info)
        var items = ids.compactMap { id in url(of: id).map { CopyExporter.Item(source: $0, name: names[id]!, info: info(id)) } }

        let title = "Lager kopier med dato og sted"
        Task {
            // Riktig tidssone (med sommertid) for bilder som ikke har sin egen, én gang per region/land.
            let hints = await exportZoneHints(for: items.map(\.info))
            for i in items.indices { items[i].zoneHint = Self.zoneKey(items[i].info).flatMap { hints[$0] } }
            progress = (title, 0, items.count)
            let items = items
            let failed = await Task.detached(priority: .userInitiated) {
                CopyExporter.export(items, to: target) { done in
                    Task { @MainActor in self.progress = (title, done, items.count) }
                }
            }.value
            progress = nil
            if !failed.isEmpty {
                alert("\(failed.count) bilder ble ikke kopiert", failed.prefix(10).joined(separator: "\n"))
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// MARK: Tidssoner for eksporten

extension AppModel {
    /// Nøkkelen et bilde slår opp tidssonen på: regionen, ellers landet.
    nonisolated static func zoneKey(_ i: PhotoInfo) -> String? {
        guard i.timeZone == nil, i.day != nil else { return nil }
        return i.regionCode ?? i.countryCode.map { "land:\($0)" }
    }

    /// Slår opp tidssonen for hver region/land bildene ligger i (Apples stedsoppslag, bare et kartpunkt
    /// sendes), med et bilde i regionen som punkt hvis det finnes, ellers midten av regionen.
    /// Én om gangen med pause, og husket mellom eksportene.
    func exportZoneHints(for infos: [PhotoInfo]) async -> [String: String] {
        var points: [String: GeoPoint] = [:]
        for i in infos {
            guard let key = Self.zoneKey(i), exportZoneCache[key] == nil else { continue }
            if let lat = i.place?.latitude, let lon = i.place?.longitude { points[key] = GeoPoint(lat: lat, lon: lon) }
            else if points[key] == nil, let area = World.filterArea(key) {
                points[key] = GeoPoint(lat: (area.minLat + area.maxLat) / 2, lon: (area.minLon + area.maxLon) / 2)
            }
        }
        let title = "Finner tidssoner"
        var done = 0
        for (key, p) in points {
            progress = (title, done, points.count)
            if let zone = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon)).first?.timeZone {
                exportZoneCache[key] = zone.identifier
            }
            done += 1
            if done < points.count { try? await Task.sleep(for: .milliseconds(1200)) }
        }
        return exportZoneCache
    }
}
