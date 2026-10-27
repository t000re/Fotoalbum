import SwiftUI

/// Hovedvinduet: fokusvisningen (ett bilde om gangen). Bilder- og Bok-visningene er skjult inntil videre.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @Environment(SimilarityIndex.self) private var similarity
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.project.folder == nil {
                ContentUnavailableView {
                    Label("Ingen bilder ennå", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Velg mappa med de skannede bildene. Bildene endres ikke.")
                } actions: {
                    Button("Velg mappe …") { model.chooseFolder() }
                }
            } else if model.folderMissing {
                ContentUnavailableView {
                    Label("Finner ikke mappa med skanningene", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Prosjektet bruker «\(URL(fileURLWithPath: model.project.folder ?? "").lastPathComponent)», men den finnes ikke på denne Mac-en. Er den flyttet, så finn den igjen. Legg den i iCloud Drive, så finner de andre Mac-ene den også. Datoer, steder og beskrivelser er tatt vare på.")
                } actions: {
                    Button("Finn mappa …") { model.chooseFolder() }
                }
            } else if phone.access == .unknown {
                ContentUnavailableView {
                    Label("iPhone-bilder", systemImage: "iphone")
                } description: {
                    Text("Appen trenger tilgang til Bilder for å vise iPhone-bildene fra turen. Den bare leser – ingenting endres, og ingenting sendes ut.")
                } actions: {
                    Button("Gi tilgang til Bilder") { Task { await phone.requestAccess() } }
                }
            } else if phone.access == .denied {
                ContentUnavailableView {
                    Label("Ingen tilgang til Bilder", systemImage: "lock")
                } description: {
                    Text("Slå på Fotoalbum under Systeminnstillinger → Personvern og sikkerhet → Bilder, og start appen på nytt.")
                } actions: {
                    Button("Åpne Systeminnstillinger") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    }
                }
            } else {
                FocusView()
            }
        }
        // Last iPhone-bildene på nytt når prosjektet, turens datoer eller tilgangen endres.
        .task(id: LoadKey(project: model.projectID, start: model.tripStart, end: model.tripEnd,
                          granted: phone.access == .granted, photos: model.photos.count)) {
            reload()
        }
        .sheet(isPresented: .constant(model.progress != nil)) {
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 10) {
                    Text(progress.title).font(.headline)
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) av \(progress.total)").monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 360)
            }
        }
        .navigationTitle(model.projectName)
        .navigationSubtitle(model.project.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Ingen mappe valgt")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ProjectsMenu(model: model)
                    Button("Nytt prosjekt …") { model.newProject() }
                    Button("Gi nytt navn …") { model.renameProject() }
                    Button("Lagre kopi …") { model.duplicateProject() }
                } label: {
                    Label("Prosjekter", systemImage: "folder")
                }
                .help("Prosjekter: åpne, lag nytt, gi nytt navn eller lagre kopi")
            }
            ToolbarItemGroup {
                TripDates()
                Text("\(model.completeCount) av \(model.photos.count) ferdige")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button { openWindow(id: "overview") } label: {
                    Label("Oversikt", systemImage: "list.bullet.rectangle")
                }
                .help("Oversikt over dager, steder og områder (⌘1)")
            }
        }
    }

    private struct LoadKey: Hashable {
        let project: UUID
        let start: Day
        let end: Day
        let granted: Bool
        let photos: Int
    }

    /// iPhone-bildene i turens periode, ruten, stedslista, fingeravtrykk for like bilder, og køen.
    private func reload() {
        guard phone.access == .granted, model.project.folder != nil else { return }
        phone.load(from: model.tripStart, to: model.tripEnd)
        model.setRoute(phone.route)
        // Analoge bilder koblet til et iPhone-bilde før klokkeslettet ble lagret, får det nå.
        let missing = model.project.photos.filter { $0.value.phoneID != nil && $0.value.time == nil }
        let dates = phone.creationDates(for: missing.compactMap(\.value.phoneID))
        for (id, info) in missing {
            if let date = dates[info.phoneID!] { model.update(id) { $0.time = date } }
        }
        if model.tripPlaces.isEmpty, !phone.located.isEmpty, model.placesProgress == nil {
            Task { await model.buildTripPlaces(from: phone) }
        }
        similarity.index(photos: model.photos, phone: phone)
        model.precomputeRegions(phone: phone)
        if model.focus.queue.count != model.photos.count || model.focus.queue.isEmpty { model.startFocus() }
    }
}

/// Turens periode (iPhone-bildene hentes herfra).
private struct TripDates: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("Turen").foregroundStyle(.secondary)
            DatePicker("Fra", selection: binding(\.tripStart), displayedComponents: .date).labelsHidden()
            Text("–")
            DatePicker("Til", selection: binding(\.tripEnd), displayedComponents: .date).labelsHidden()
        }
        .datePickerStyle(.field)
        .environment(\.locale, Locale(identifier: "nb_NO"))
        .help("Perioden iPhone-bildene hentes fra")
    }

    private func binding(_ key: ReferenceWritableKeyPath<AppModel, Day>) -> Binding<Date> {
        Binding(get: { model[keyPath: key].date }, set: { model[keyPath: key] = Day($0) })
    }
}

/// Verktøylinja i Bok: format og antall sider, med Blurbs krav.
private struct BookToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.book.pages.count
        if count < 20 {
            Label("Blurb krever minst 20 sider", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if count > 240 {
            Label(count > 440 ? "Over 440 sider: for mange for Blurb" : "Over 240 sider: ikke alle papirtyper",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        Text("\(count) sider").monospacedDigit().foregroundStyle(.secondary)
            .help(count % 2 == 1 ? "Oddetall: en tom side legges til på slutten ved eksport" : "")
        Picker("Bildetekst", selection: Binding(get: { model.book.placeText ?? .both }, set: { model.setPlaceText($0) })) {
            ForEach(PlaceText.allCases, id: \.self) { Text($0.name).tag($0) }
        }
        .help("Hva bildeteksten viser: område og sted, bare område eller bare sted")
        Picker("Format", selection: Binding(get: { model.book.formatID }, set: { model.setFormat($0) })) {
            ForEach(BookFormat.all) { Text($0.name).tag($0.id) }
        }
    }
}

/// Alle bildene som små miniatyrer. Klikk velger; piltastene blar når rutenettet har fokus.
struct PhotoGrid: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10,
                          pinnedViews: .sectionHeaders) {
                    if model.sorting == .day {
                        // Tid: dager og steder med overskrifter. Overskriften blir stående mens du ruller.
                        let byID = Dictionary(uniqueKeysWithValues: model.photos.map { ($0.id, $0) })
                        ForEach(model.chronology(of: model.visiblePhotos.map(\.id))) { section in
                            ForEach(Array(section.runs.enumerated()), id: \.element.id) { index, run in
                                Section {
                                    ForEach(run.ids.compactMap { byID[$0] }) { cell($0) }
                                } header: {
                                    RunHeader(section: section, run: run, first: index == 0)
                                }
                            }
                        }
                    } else if model.sorting == .similar {
                        // Likhet: grupper av like bilder, så bildene uten like.
                        let visible = model.visiblePhotos
                        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
                        let groups = model.similarGroups(of: visible.map(\.id))
                        let grouped = Set(groups.flatMap { $0 })
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, ids in
                            Section {
                                ForEach(ids.compactMap { byID[$0] }) { cell($0) }
                            } header: {
                                GroupHeader(title: "Gruppe \(index + 1)", ids: ids)
                            }
                        }
                        let rest = visible.filter { !grouped.contains($0.id) }
                        if !rest.isEmpty {
                            Section {
                                ForEach(rest) { cell($0) }
                            } header: {
                                GroupHeader(title: "Uten like bilder", ids: rest.map(\.id))
                            }
                        }
                    } else {
                        ForEach(model.visiblePhotos) { cell($0) }
                    }
                }
                .padding([.horizontal, .bottom], 10)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) { model.selectNext(1); return .handled }
            .onKeyPress(.leftArrow) { model.selectNext(-1); return .handled }
            .onChange(of: model.selection) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: nil) }
            }
            .overlay {
                if model.visiblePhotos.isEmpty {
                    Text(model.filter != .all ? "Ingen bilder mangler dette 🎉" : "Ingen bilder her")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cell(_ photo: Photo) -> some View {
        GridCell(photo: photo, selected: model.selected.contains(photo.id), primary: photo.id == model.selection)
            .id(photo.id)
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                model.click(photo.id, command: flags.contains(.command), shift: flags.contains(.shift))
                focused = true
            }
    }
}

/// Overskrift over et sted i lista: dagen (stor ved første sted den dagen) og stedet.
private struct RunHeader: View {
    @Environment(AppModel.self) private var model
    let section: DaySection
    let run: PlaceRun
    let first: Bool
    /// Området til stedet (fra første bilde som har det).
    private var area: String? { run.ids.lazy.compactMap { model.info($0).area }.first { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if first {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.day?.norwegian ?? "Uten dato").font(.title3.bold())
                    Text("\(section.count) bilder").foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "mappin").foregroundStyle(.secondary)
                if let area = area { Text(area).font(.headline).foregroundStyle(.secondary) }
                Text(run.name ?? "Uten sted").font(.headline).foregroundStyle(run.name == nil ? .secondary : .primary)
                if !first, let day = section.day {
                    Text(day.norwegian).foregroundStyle(.secondary)
                }
                Text("\(run.ids.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// Én rute: miniatyren, og små merker for dato og sted (fylt når de er satt).
private struct GridCell: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let selected: Bool
    let primary: Bool

    var body: some View {
        let info = model.info(photo.id)
        VStack(spacing: 4) {
            PhotoImage(url: photo.url, maxPixels: 300)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Image(systemName: info.day == nil ? "calendar" : "calendar.circle.fill")
                    .foregroundStyle(info.day == nil ? Color.secondary : Color.accentColor)
                Image(systemName: info.place == nil ? "mappin" : "mappin.circle.fill")
                    .foregroundStyle(info.place == nil ? Color.secondary : Color.accentColor)
                if info.placeIsUnknown || info.dayIsUnknown {
                    Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                        .help(info.placeIsUnknown && info.dayIsUnknown ? "Vet ikke sted og dato"
                              : info.placeIsUnknown ? "Vet ikke stedet" : "Vet ikke datoen")
                }
                if info.isUncertain {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                        .help(info.note ?? "Usikker")
                }
                Text(info.day?.norwegian ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .padding(5)
        .background(selected ? Color.accentColor.opacity(primary ? 0.35 : 0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(photo.id)
    }
}

/// Overskrift over en gruppe like bilder, med knapp for å velge hele gruppen
/// (så du kan gi alle samme dato og sted på én gang).
private struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let title: String
    let ids: [String]

    var body: some View {
        let infos = ids.map { model.info($0) }
        let places = Set(infos.compactMap { $0.place?.name })
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text("\(ids.count) bilder").foregroundStyle(.secondary)
            if !places.isEmpty {
                Text(places.sorted().joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Velg gruppen") {
                model.selected = Set(ids)
                model.selection = ids.first
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
