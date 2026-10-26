import AppKit

/// Omslaget (milepæl 6): smussomslag med bilde på forside og bakside, tittel, og kart på klaffen.
extension AppModel {
    var cover: Cover { book.cover ?? Cover() }

    func updateCover(_ change: (inout Cover) -> Void) {
        ensureBook()
        guard var b = project.book else { return }
        var c = b.cover ?? Cover()
        change(&c)
        b.cover = c
        project.book = b
        scheduleSave()
    }

    /// Sidetallet slik det blir i PDF-en (minst 20 og partall), som avgjør ryggen.
    var printedPageCount: Int {
        var count = max(book.pages.count, Self.minimumPages)
        if count % 2 == 1 { count += 1 }
        return count
    }

    var coverSpec: CoverSpec { CoverSpec.make(format: book.format, paper: cover.paper, pages: printedPageCount) }

    /// Kartet med hele ruten (til klaffen).
    var wholeRouteMap: MapData? {
        let route = (project.route ?? []).map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
            .filter { (24...50).contains($0.lat) && (-125...(-66)).contains($0.lon) }
        guard !route.isEmpty else { return nil }
        return MapData(route: route, here: route.last, visited: Set(route.compactMap(stateCode)), current: nil)
    }

    // MARK: Eget omslag

    /// Velg et omslag laget i Figma eller Photoshop.
    func chooseCustomCover() {
        let panel = NSOpenPanel()
        panel.title = "Velg eget omslag"
        panel.message = "Et bilde (PNG, JPEG, TIFF) eller en PDF i full størrelse med utfallende kant."
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateCover { $0.customFile = url.path; $0.useCustom = true }
    }

    /// Lagrer malen med kutt, bretter og sikre soner som PNG i 300 ppi.
    func saveCoverTemplate() {
        let spec = coverSpec
        let panel = NSSavePanel()
        panel.title = "Lagre omslagsmal"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Omslagsmal \(CoverTemplate.px(spec.pageSize.width))x\(CoverTemplate.px(spec.pageSize.height)) – \(printedPageCount) sider \(cover.paper.name).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CoverTemplate.templateImage(spec), CoverTemplate.writePNG(image, to: url) else {
            alert("Malen ble ikke lagret", "")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyCoverMeasures() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CoverTemplate.text(coverSpec, pages: printedPageCount, paper: cover.paper,
                                                          format: book.format), forType: .string)
    }

    func exportCoverPDF() {
        let cover = cover
        guard cover.frontPhoto != nil || cover.backPhoto != nil || !cover.title.isEmpty || cover.useCustom else { return }
        if cover.useCustom {
            guard let path = cover.customFile, FileManager.default.fileExists(atPath: path) else {
                alert("Fant ikke det egne omslaget", "Velg fila på nytt.")
                return
            }
            if let problem = CoverTemplate.problem(with: URL(fileURLWithPath: path), spec: coverSpec) {
                let a = NSAlert()
                a.messageText = "Omslaget passer ikke helt"
                a.informativeText = problem + " Det blir strukket til riktig størrelse hvis du fortsetter."
                a.addButton(withTitle: "Avbryt")
                a.addButton(withTitle: "Fortsett likevel")
                guard a.runModal() == .alertSecondButtonReturn else { return }
            }
        }
        if printedPageCount > cover.paper.maxPages {
            alert("For mange sider for papiret", "\(cover.paper.name) tåler høyst \(cover.paper.maxPages) sider. Boka har \(printedPageCount).")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Eksporter omslag-PDF"
        panel.message = "Smussomslaget til Blurb PDF to Book. Lag det på nytt hvis sidetallet eller papiret endres."
        panel.prompt = "Eksporter"
        panel.allowedContentTypes = [.pdf]
        let name = project.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Fotobok"
        panel.nameFieldStringValue = "\(name) – omslag.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        let spec = coverSpec
        let sources = [cover.frontPhoto, cover.backPhoto].compactMap { $0 }
            .reduce(into: [String: URL]()) { $0[$1] = url(of: $1) }
        let map = cover.mapOnFlap ? wholeRouteMap : nil
        let pages = printedPageCount
        Task {
            let error = await Task.detached(priority: .userInitiated) {
                PDFExporter.exportCover(cover, spec: spec, sources: sources, routeMap: map, title: name, to: target)
            }.value
            if let error { alert("Omslaget ble ikke laget", error); return }
            alert("Omslag-PDF-en er klar", String(format: "%.0f × %.0f pt for %d sider på %@ (rygg %.0f pt). Sjekk målene mot Blurbs kalkulator før du laster opp.",
                                                 spec.pageSize.width, spec.pageSize.height, pages, cover.paper.name, spec.spineWidth))
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }
}
