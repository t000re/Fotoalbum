import AppKit

/// «Eksporter bok-PDF»: innmaten som én PDF etter Blurbs krav (milepæl 5). Omslaget kommer i milepæl 6.
extension AppModel {
    /// Blurb krever minst 20 sider og et partall. Mangler det, fylles det på med tomme sider til slutt.
    static let minimumPages = 20

    func exportBookPDF() {
        ensureBook()
        let pages = book.pages
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Eksporter bok-PDF"
        panel.message = "Innmaten til Blurb PDF to Book. Omslaget lages for seg."
        panel.prompt = "Eksporter"
        panel.allowedContentTypes = [.pdf]
        let name = project.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Fotobok"
        panel.nameFieldStringValue = "\(name) – innmat.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        // Tomme sider til slutt: opp til 20, og så til partall.
        var count = max(pages.count, Self.minimumPages)
        if count % 2 == 1 { count += 1 }
        let blanks = count - pages.count

        let format = book.format
        let jobs: [PDFExporter.Job] = (0..<count).map { index in
            guard index < pages.count else {
                return PDFExporter.Job(page: BookPage(layout: .single, photos: []), isRight: Book.isRight(index),
                                       sources: [:], captions: [:], map: nil)
            }
            let page = pages[index]
            return PDFExporter.Job(
                page: page, isRight: Book.isRight(index),
                sources: Dictionary(uniqueKeysWithValues: page.photos.compactMap { id in url(of: id).map { (id, $0) } }),
                captions: Dictionary(uniqueKeysWithValues: page.photos.map { ($0, caption($0)) }),
                map: showsMap(index) ? mapData(index) : nil)
        }

        let title = "Lager bok-PDF"
        progress = (title, 0, jobs.count)
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                PDFExporter.export(jobs, format: format, title: name, to: target) { done in
                    Task { @MainActor in self.progress = (title, done, jobs.count) }
                }
            }.value
            progress = nil
            if let error {
                alert("PDF-en ble ikke laget", error)
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int).map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? ""
            var text = "\(count) sider i \(format.name), \(size)."
            if blanks > 0 { text += " \(blanks) tomme sider er lagt til på slutten (Blurb krever minst 20 sider og partall)." }
            alert("Bok-PDF-en er klar", text)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
