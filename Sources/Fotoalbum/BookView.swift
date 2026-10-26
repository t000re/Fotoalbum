import SwiftUI

/// Boka: oppslagene til venstre, valgt oppslag stort i midten, valgt side til høyre.
struct BookView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            SpreadList()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            Group {
                if model.showingCover { CoverDetail() } else { SpreadDetail() }
            }
            .frame(minWidth: 500)
            Group {
                if model.showingCover { CoverInspector() } else { PageInspector() }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        .onAppear {
            model.ensureBook()
            if model.selectedPage == nil { model.selectedPage = model.book.pages.first?.id }
        }
    }
}

// MARK: Sidebilder

/// Én side tegnet med PageRenderer (samme som PDF-en). Tegnes på nytt når innholdet endres.
struct PageImage: View {
    @Environment(AppModel.self) private var model
    let page: BookPage
    let pixelWidth: Int

    @State private var image: CGImage?

    var body: some View {
        let format = model.book.format
        let captions = Dictionary(uniqueKeysWithValues: page.photos.map { ($0, model.caption($0)) })
        let urls = page.photos.compactMap { id in model.url(of: id).map { (id, $0) } }
        let index = model.book.pages.firstIndex { $0.id == page.id } ?? 0
        let map = model.showsMap(index) ? model.mapData(index) : nil
        ZStack {
            Color.white
            if let image { Image(decorative: image, scale: 1).resizable() }
        }
        .aspectRatio(format.trim.width / format.trim.height, contentMode: .fit)
        .task(id: RenderKey(page: page, captions: captions, map: map, format: format.id, width: pixelWidth,
                            isRight: Book.isRight(index))) {
            // Bildene i passe størrelse: ca. 1,5 ganger sidebredden i piksler.
            var images: [String: CGImage] = [:]
            for (id, url) in urls {
                images[id] = await Thumbnails.load(url, maxPixels: max(300, pixelWidth * 3 / 2))
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                PageRenderer.image(page, format: format, isRight: Book.isRight(index), pixelWidth: pixelWidth, showBleed: false,
                                   images: images, captions: captions, map: map)
            }.value
            image = rendered
        }
    }

    private struct RenderKey: Hashable {
        let page: BookPage
        let captions: [String: Caption]
        let map: MapData?
        let format: String
        let width: Int
        let isRight: Bool
    }
}

/// Et oppslag: venstre og høyre side. Tom plass der det ikke er side (først og sist).
struct SpreadView: View {
    @Environment(AppModel.self) private var model
    let spread: [Int?]
    let pixelWidth: Int
    var onTapPage: ((BookPage) -> Void)?

    var body: some View {
        let pages = model.book.pages
        let format = model.book.format
        HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { side in
                if let index = spread[side], pages.indices.contains(index) {
                    let page = pages[index]
                    PageImage(page: page, pixelWidth: pixelWidth)
                        .overlay {
                            if page.id == model.selectedPage {
                                Rectangle().stroke(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onTapPage?(page) }
                } else {
                    Color.clear.aspectRatio(format.trim.width / format.trim.height, contentMode: .fit)
                }
            }
        }
    }
}

// MARK: Oppslagsliste

private struct SpreadList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let spreads = model.book.spreads
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    VStack(spacing: 3) {
                        CoverImage(pixelWidth: 500)
                            .overlay { if model.showingCover { Rectangle().stroke(Color.accentColor, lineWidth: 2) } }
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .onTapGesture { model.showingCover = true }
                        Text("Omslag").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(spreads.indices, id: \.self) { i in
                        VStack(spacing: 3) {
                            SpreadView(spread: spreads[i], pixelWidth: 200) {
                                model.selectedPage = $0.id
                                model.showingCover = false
                            }
                                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            Text(label(spreads[i])).font(.caption).foregroundStyle(.secondary)
                        }
                        .id(i)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selectedPage) {
                if let i = currentSpread(spreads) { withAnimation { proxy.scrollTo(i) } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func label(_ spread: [Int?]) -> String {
        let numbers = spread.compactMap { $0.map { $0 + 1 } }
        return numbers.count == 2 ? "Side \(numbers[0])–\(numbers[1])" : "Side \(numbers.first ?? 0)"
    }

    private func currentSpread(_ spreads: [[Int?]]) -> Int? {
        let pages = model.book.pages
        return spreads.firstIndex { $0.contains { i in i.map { pages[$0].id == model.selectedPage } ?? false } }
    }
}

// MARK: Stort oppslag

private struct SpreadDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let spreads = model.book.spreads
        let current = currentSpread(spreads)
        VStack {
            if let current {
                SpreadView(spread: spreads[current], pixelWidth: 1400) { model.selectedPage = $0.id }
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button { go(spreads, current - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(current == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Text("Oppslag \(current + 1) av \(spreads.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button { go(spreads, current + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(current + 1 >= spreads.count)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.bottom, 12)
            } else {
                Text("Boka er tom").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func currentSpread(_ spreads: [[Int?]]) -> Int? {
        let pages = model.book.pages
        return spreads.firstIndex { $0.contains { i in i.map { pages[$0].id == model.selectedPage } ?? false } }
            ?? (spreads.isEmpty ? nil : 0)
    }

    private func go(_ spreads: [[Int?]], _ i: Int) {
        guard spreads.indices.contains(i), let index = spreads[i].compactMap({ $0 }).first else { return }
        model.selectedPage = model.book.pages[index].id
    }
}

// MARK: Valgt side

private struct PageInspector: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRebuild = false

    var body: some View {
        let pages = model.book.pages
        Form {
            if let index = pages.firstIndex(where: { $0.id == model.selectedPage }) {
                let page = pages[index]
                Section("Side \(index + 1) av \(pages.count)") {
                    Picker("Mal", selection: Binding(get: { page.layout },
                                                     set: { model.setLayout($0, for: page.id) })) {
                        ForEach(PageLayout.allCases, id: \.self) { layout in
                            Label(layout.name, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    HStack {
                        Button("← Flytt") { model.movePage(page.id, by: -1) }.disabled(index == 0)
                        Button("Flytt →") { model.movePage(page.id, by: 1) }.disabled(index + 1 == pages.count)
                        if page.photos.count == 2 {
                            Button("Bytt bildene") { model.swapPhotos(on: page.id) }
                        }
                    }
                }
                Section("Kart") {
                    Picker("Kart", selection: Binding(get: { page.map }, set: { model.setMap($0, for: page.id) })) {
                        Text("Automatisk").tag(MapChoice?.none)
                        Text("Vis").tag(MapChoice?.some(.show))
                        Text("Skjul").tag(MapChoice?.some(.hide))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(mapNote(index, page))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Bilder på siden") {
                    ForEach(page.photos, id: \.self) { id in
                        PhotoRow(id: id) {
                            Menu {
                                Button("Bruk på forsiden") { model.updateCover { $0.frontPhoto = id } }
                                Button("Bruk på baksiden") { model.updateCover { $0.backPhoto = id } }
                                Divider()
                                Button("Ta ut av boka") { model.removeFromBook(id) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    if page.layout == .fullBleed {
                        Text("Utfallende sider har ingen tekst i dette utkastet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let missing = model.photosNotInBook
            if !missing.isEmpty {
                Section("Nye bilder, ikke i boka (\(missing.count))") {
                    Button("Legg alle inn etter dato") { missing.forEach(model.addToBook) }
                }
            }
            let excluded = model.excludedPhotos
            if !excluded.isEmpty {
                Section("Tatt ut av boka (\(excluded.count))") {
                    ForEach(excluded, id: \.self) { id in
                        PhotoRow(id: id) {
                            Button("Legg inn igjen") { model.addToBook(id) }
                        }
                    }
                }
            }
            Section {
                Button("Bygg boka på nytt fra datoene …") { confirmRebuild = true }
            } footer: {
                Text("Én side per bilde, i dato-rekkefølge. Malene og flyttingene du har gjort, forsvinner.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Bygge boka på nytt?", isPresented: $confirmRebuild) {
            Button("Bygg på nytt", role: .destructive) {
                model.rebuildBook()
                model.selectedPage = model.book.pages.first?.id
            }
        } message: {
            Text("Alle sider får ett bilde med marg, i dato-rekkefølge. Bilder du har tatt ut, holdes fortsatt utenfor.")
        }
    }
}

extension PageInspector {
    /// Forklaring under kartvalget.
    func mapNote(_ index: Int, _ page: BookPage) -> String {
        let state = model.state(of: page).flatMap { code in USState.all.first { $0.code == code }?.name }
        if model.project.route?.isEmpty ?? true {
            return "Ruten hentes fra iPhone-bildene. Åpne Bilder-visningen med tilgang til Bilder, og sett datoene for turen."
        }
        switch page.map {
        case .show: return "Kartet vises på denne siden."
        case .hide: return "Kartet er skjult på denne siden."
        case nil:
            if model.isNewState(index), let state { return "Vises: første side i \(state)." }
            if let state { return "Vises ikke: fortsatt i \(state). Kart kommer automatisk ved ny stat." }
            return "Siden har ikke kartpunkt, så staten er ukjent."
        }
    }
}

/// Lite bilde med sted/dato og en knapp.
struct PhotoRow<Action: View>: View {
    @Environment(AppModel.self) private var model
    let id: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        let caption = model.caption(id)
        HStack {
            if let url = model.url(of: id) {
                PhotoImage(url: url, maxPixels: 120).frame(width: 48, height: 36)
            }
            VStack(alignment: .leading) {
                Text(caption.heading.isEmpty ? "Uten sted og dato" : caption.heading).lineLimit(1)
                if !caption.body.isEmpty {
                    Text(caption.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            action()
        }
    }
}
