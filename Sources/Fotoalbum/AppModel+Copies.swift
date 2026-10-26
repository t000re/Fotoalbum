import AppKit

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
        let items = ids.compactMap { id in url(of: id).map { CopyExporter.Item(source: $0, name: names[id]!, info: info(id)) } }

        let title = "Lager kopier med dato og sted"
        progress = (title, 0, items.count)
        Task {
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
