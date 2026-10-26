import SwiftUI

/// Omslaget tegnet med CoverRenderer (samme som PDF-en), med utfallende kant.
struct CoverImage: View {
    @Environment(AppModel.self) private var model
    let pixelWidth: Int
    @State private var image: CGImage?

    var body: some View {
        let cover = model.cover
        let spec = model.coverSpec
        let map = cover.mapOnFlap ? model.wholeRouteMap : nil
        let urls = [cover.frontPhoto, cover.backPhoto].compactMap { $0 }.compactMap { id in model.url(of: id).map { (id, $0) } }
        // Endringsdatoen til det egne omslaget, så forhåndsvisningen oppdateres når du lagrer over fila.
        let modified = cover.customFile.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        ZStack {
            Color.white
            if let image { Image(decorative: image, scale: 1).resizable() }
        }
        .aspectRatio(spec.pageSize.width / spec.pageSize.height, contentMode: .fit)
        .task(id: Key(cover: cover, spec: spec, map: map, width: pixelWidth, modified: modified)) {
            var images: [String: CGImage] = [:]
            // Hver flate er ca. en tredel av bredden.
            for (id, url) in urls { images[id] = await Thumbnails.load(url, maxPixels: max(300, pixelWidth / 2)) }
            image = await Task.detached(priority: .userInitiated) {
                CoverRenderer.image(cover, spec: spec, pixelWidth: pixelWidth, images: images, routeMap: map)
            }.value
        }
    }

    private struct Key: Hashable {
        let cover: Cover
        let spec: CoverSpec
        let map: MapData?
        let width: Int
        let modified: Date?
    }
}

/// Omslaget stort, med brettlinjer og kutt markert (bare på skjermen).
struct CoverDetail: View {
    @Environment(AppModel.self) private var model
    @State private var showGuides = true

    var body: some View {
        let spec = model.coverSpec
        VStack {
            CoverImage(pixelWidth: 3000)
                .overlay {
                    if showGuides {
                        GeometryReader { geo in
                            let s = geo.size.width / spec.pageSize.width
                            let b = CoverSpec.bleed
                            Path { p in
                                p.addRect(CGRect(x: b * s, y: b * s, width: spec.trim.width * s, height: spec.trim.height * s))
                                for x in [spec.back.minX, spec.spine.minX, spec.spine.maxX, spec.front.maxX] {
                                    p.move(to: CGPoint(x: (x + b) * s, y: 0))
                                    p.addLine(to: CGPoint(x: (x + b) * s, y: geo.size.height))
                                }
                            }
                            .stroke(Color.pink.opacity(0.7), style: StrokeStyle(lineWidth: 0.75, dash: [4, 3]))
                        }
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 18) {
                Text("Klaff · Bakside · Rygg · Forside · Klaff").foregroundStyle(.secondary)
                Toggle("Vis kutt og bretter", isOn: $showGuides)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// Innstillinger for omslaget: lag det i appen, eller lag det selv og lim inn et bilde.
struct CoverInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cover = model.cover
        Form {
            Section("Omslag") {
                Picker("Omslag", selection: Binding(get: { cover.useCustom }, set: { v in model.updateCover { $0.useCustom = v } })) {
                    Text("Lag i appen").tag(false)
                    Text("Eget bilde").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if cover.useCustom {
                customSections
            } else {
                appSections
            }
            paperSection
            MeasureSection()
            Section {
                Button("Eksporter omslag-PDF …") { model.exportCoverPDF() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Laget i appen

    @ViewBuilder private var appSections: some View {
        let cover = model.cover
        Section("Tittel") {
            TextField("Tittel", text: Binding(get: { cover.title }, set: { t in model.updateCover { $0.title = t } }))
            TextField("Undertittel", text: Binding(get: { cover.subtitle }, set: { t in model.updateCover { $0.subtitle = t } }),
                      prompt: Text("F.eks. Juli 2022"))
            Picker("Tekstfarge", selection: Binding(get: { cover.whiteTitle }, set: { v in model.updateCover { $0.whiteTitle = v } })) {
                Text("Hvit").tag(true)
                Text("Svart").tag(false)
            }
            .pickerStyle(.segmented)
        }
        Section("Bilder") {
            coverPhoto("Forside", cover.frontPhoto) { model.updateCover { $0.frontPhoto = nil } }
            coverPhoto("Bakside", cover.backPhoto) { model.updateCover { $0.backPhoto = nil } }
            Text("Velg bilder i boka: klikk ••• ved et bilde på en side og velg «Bruk på forsiden» eller «Bruk på baksiden».")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Klaffer") {
            Toggle("Kart med hele ruten på bakre klaff", isOn: Binding(get: { cover.mapOnFlap },
                                                                   set: { v in model.updateCover { $0.mapOnFlap = v } }))
        }
    }

    private func coverPhoto(_ title: String, _ id: String?, remove: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if let id, let url = model.url(of: id) {
                HStack {
                    PhotoImage(url: url, maxPixels: 160).frame(width: 64, height: 44)
                    Button("Fjern", action: remove)
                }
            } else {
                Text("Ikke valgt").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Eget bilde

    @ViewBuilder private var customSections: some View {
        let cover = model.cover
        Section {
            if let path = cover.customFile {
                let url = URL(fileURLWithPath: path)
                LabeledContent("Fil", value: url.lastPathComponent)
                if !FileManager.default.fileExists(atPath: path) {
                    Label("Fila finnes ikke lenger. Velg den på nytt.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let problem = CoverTemplate.problem(with: url, spec: model.coverSpec) {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Størrelsen passer.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            Button(cover.customFile == nil ? "Velg bilde eller PDF …" : "Velg en annen fil …") { model.chooseCustomCover() }
        } header: {
            Text("Eget omslag")
        } footer: {
            Text("Lag omslaget i Figma eller Photoshop i full størrelse med utfallende kant (se målene under), og eksporter som PNG, JPEG, TIFF eller PDF. Appen leser fila på nytt hver gang, så du kan lagre over den.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Papir

    @ViewBuilder private var paperSection: some View {
        let cover = model.cover
        Section("Papir") {
            Picker("Papir", selection: Binding(get: { cover.paper }, set: { p in model.updateCover { $0.paper = p } })) {
                ForEach(Paper.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            LabeledContent("Sider i PDF-en", value: "\(model.printedPageCount)")
            if model.printedPageCount > cover.paper.maxPages {
                Label("\(cover.paper.name) tåler høyst \(cover.paper.maxPages) sider", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Velg samme papir når du bestiller hos Blurb. Ryggen endres med sidetallet, så lag omslaget når boka er ferdig.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Målene til omslaget for gjeldende sidetall og papir, i piksler (300 ppi), millimeter og punkter.
private struct MeasureSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let spec = model.coverSpec
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(CoverTemplate.measures(spec)) { m in
                    GridRow {
                        Text(m.name)
                        Text(m.pxText).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(m.mmText).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            HStack {
                Button("Lagre mal (PNG) …") { model.saveCoverTemplate() }
                Button("Kopier målene") { model.copyCoverMeasures() }
            }
        } header: {
            Text("Mål for eget omslag")
        } footer: {
            Text("Lag dokumentet i \(CoverTemplate.px(spec.pageSize.width)) × \(CoverTemplate.px(spec.pageSize.height)) px, 300 ppi, sRGB. Malen har kutt, bretter og sikre soner; legg den øverst som eget lag og skjul den før du eksporterer. Rekkefølge fra venstre: bakre klaff, bakside, rygg, forside, fremre klaff.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
