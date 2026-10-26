import Photos
import SwiftUI

/// Valgt bilde stort, med dato, sted og beskrivelse under.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let photo = model.selectedPhoto {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    PhotoImage(url: photo.url, maxPixels: 2000)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let asset = model.compareAsset {
                        ComparePanel(asset: asset)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.85))
                PhotoFields(id: photo.id)
                    .id(photo.id)  // nye felter for hvert bilde, så teksten ikke henger igjen
            }
        } else {
            Text("Velg et bilde").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Feltene for ett bilde. Alt lagres automatisk mens du skriver.
private struct PhotoFields: View {
    @Environment(AppModel.self) private var model
    let id: String
    @FocusState private var placeFocused: Bool
    /// Stedsnavnet er endret siden kartpunktet sist ble satt.
    @State private var placeEdited = false
    @State private var lookingUp = false
    @State private var lookupNote: String?
    /// Bildene som var valgt da du begynte å skrive stedet (så oppslaget ikke havner på et annet bilde).
    @State private var editTargets: Set<String> = []

    var body: some View {
        let info = model.info(id)
        Form {
            if model.selected.count > 1 {
                Label("Dato og sted settes på alle \(model.selected.count) valgte bilder. Beskrivelsen gjelder bare dette.",
                      systemImage: "square.stack")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LabeledContent("Dato") {
                if let day = info.day {
                    HStack {
                        DatePicker("Dato", selection: dayBinding(day), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .environment(\.locale, Locale(identifier: "nb_NO"))
                        Text(day.norwegian).foregroundStyle(.secondary)
                        Spacer()
                        Button("Fjern") { forSelected { $0.day = nil } }
                    }
                } else {
                    let suggested = model.suggestedDay
                    Button("Sett dato (\(suggested.norwegian))") {
                        forSelected { $0.day = suggested; $0.source = .manual }
                    }
                }
            }
            HStack {
                TextField("Sted", text: placeBinding, prompt: Text(model.project.lastPlaceName ?? "F.eks. Grand Canyon"))
                    .focused($placeFocused)
                    .onSubmit { commitPlace() }
                    // Litt forsinket, så et klikk på et forslag rekker å registreres før lista forsvinner.
                    .onChange(of: placeFocused) { _, focused in
                        if !focused {
                            Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                if !placeFocused { commitPlace() }
                            }
                        }
                    }
                if lookingUp {
                    ProgressView().controlSize(.small)
                } else if let place = info.place {
                    Image(systemName: place.latitude == nil ? "mappin.slash" : "mappin.and.ellipse")
                        .foregroundStyle(place.latitude == nil ? .orange : .secondary)
                        .help(place.latitude == nil ? "Uten kartpunkt: trykk Enter i feltet for å slå opp stedet" : "Har kartpunkt")
                }
                if let place = info.place, let lat = place.latitude, let lon = place.longitude {
                    PlaceAlternatives(latitude: lat, longitude: lon) { name in
                        forSelected { $0.place?.name = name }
                    }
                }
            }
            // Forslag mens du skriver: steder du har brukt, steder fra iPhone, så søketreff fra Apple.
            let typed = info.place?.name ?? ""
            let suggestions = placeEdited
                ? Array(model.rankedPlaceOptions(typed: typed).filter { $0.title != typed }.prefix(8)) : []
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions) { s in
                        Button {
                            choose(s)
                        } label: {
                            HStack {
                                Image(systemName: s.searchSubtitle != nil ? "magnifyingglass"
                                      : s.place?.latitude == nil ? "mappin.slash" : "mappin")
                                    .foregroundStyle(.secondary)
                                Text(s.title)
                                Spacer()
                                Text(s.detail).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.callout)
            }
            if let lookupNote {
                Text(lookupNote).font(.caption).foregroundStyle(.secondary)
            }
            AreaField(id: id) { change in forSelected(change) }
            LabeledContent("Beskrivelse") {
                TextEditor(text: captionBinding)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            }
            RollNeighbors(id: id)
            TextInPhoto(id: id)
            HStack {
                Toggle("Usikker", isOn: Binding(get: { model.info(id).isUncertain },
                                                set: { v in model.update(id) { $0.uncertain = v ? true : nil } }))
                    .help("Merk bildet hvis dato eller sted kan være feil. Vis alle usikre med filteret «Usikre».")
                if info.isUncertain {
                    TextField("Notat", text: Binding(get: { model.info(id).note ?? "" },
                                                     set: { t in model.update(id) { $0.note = t.isEmpty ? nil : t } }),
                              prompt: Text("Hva er usikkert?"))
                }
            }
            HStack {
                Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Forrige") { model.selectNext(-1) }
                Button("Neste") { model.selectNext(1) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    /// Endringer i dato og sted gjelder alle valgte bilder (minst dette).
    private func forSelected(_ change: (inout PhotoInfo) -> Void) {
        for target in Set(model.selectedIDs + [id]) { model.update(target, change) }
    }

    private func dayBinding(_ current: Day) -> Binding<Date> {
        Binding(get: { current.date },
                set: { new in
                    forSelected {
                        // Ny dag: klokkeslettet fra iPhone-bildet stemmer ikke lenger.
                        if $0.day != Day(new) { $0.time = nil }
                        $0.day = Day(new)
                        $0.source = .manual
                    }
                })
    }

    /// Valgt forslag: navn og kartpunkt.
    /// Valgt forslag. Søketreff fra Apple får kartpunkt hentet først.
    private func choose(_ option: FocusSession.Option) {
        let targets = editTargets.isEmpty ? Set(model.selectedIDs + [id]) : editTargets
        placeEdited = false
        editTargets = []
        lookupNote = nil
        model.placeSearch.query = ""
        if let subtitle = option.searchSubtitle {
            lookingUp = true
            Task {
                let place = await model.placeSearch.resolve(title: option.title, subtitle: subtitle) ?? Place(name: option.title)
                lookingUp = false
                for target in targets { model.update(target) { $0.place = place; $0.source = .manual } }
            }
            return
        }
        guard let place = option.place else { return }
        for target in targets { model.update(target) { $0.place = place; $0.source = .manual } }
        if place.latitude == nil { commitPlace(force: true) }
    }

    /// Etter du har skrevet et sted (Enter eller klikk ut av feltet): finn kartpunkt for navnet.
    /// Et kjent sted fra turen eller et navn du har brukt får samme kartpunkt; ellers brukes Apples
    /// stedssøk (bare navnet sendes).
    private func commitPlace(force: Bool = false) {
        guard placeEdited || force, let name = model.info(id).place?.name, !name.isEmpty else { return }
        placeEdited = false
        let targets = editTargets.isEmpty ? Set(model.selectedIDs + [id]) : editTargets
        editTargets = []
        func setForTargets(_ change: (inout PhotoInfo) -> Void) {
            for target in targets where model.info(target).place?.name == name { model.update(target, change) }
        }
        if let known = model.placeSuggestions(for: name).first(where: { $0.name == name && $0.latitude != nil }) {
            setForTargets { $0.place = known }
            lookupNote = nil
            return
        }
        lookingUp = true
        Task {
            let point = await AppModel.lookUpCoordinates(name)
            lookingUp = false
            // Bare bilder som fortsatt har navnet (ikke endret igjen mens vi søkte).
            setForTargets {
                $0.place?.latitude = point?.lat
                $0.place?.longitude = point?.lon
            }
            lookupNote = point == nil ? "Fant ikke «\(name)» på kartet. Stedet får ikke kartpunkt." : nil
        }
    }

    /// Mens du skriver beholdes kartpunktet; det oppdateres når du er ferdig (se commitPlace).
    /// Tomt navn fjerner stedet.
    private var placeBinding: Binding<String> {
        Binding(get: { model.info(id).place?.name ?? "" },
                set: { name in
                    if !placeEdited { editTargets = Set(model.selectedIDs + [id]) }
                    placeEdited = true
                    model.placeSearch.query = name
                    forSelected {
                        if name.isEmpty { $0.place = nil; return }
                        var place = $0.place ?? Place(name: "")
                        place.name = name
                        $0.place = place
                        $0.source = .manual
                    }
                })
    }

    private var captionBinding: Binding<String> {
        Binding(get: { model.info(id).caption }, set: { text in model.update(id) { $0.caption = text } })
    }
}

/// Meny med andre navn for samme koordinater («Half Dome», «Yosemite National Park», «CA» …).
private struct PlaceAlternatives: View {
    @Environment(PhoneLibrary.self) private var phone
    let latitude: Double
    let longitude: Double
    let choose: (String) -> Void
    @State private var names: [String] = []

    var body: some View {
        Menu {
            if names.isEmpty { Text("Henter …") }
            ForEach(names, id: \.self) { name in Button(name) { choose(name) } }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Andre navn for stedet")
        .task(id: "\(latitude),\(longitude)") {
            names = await phone.nameAlternatives(latitude: latitude, longitude: longitude)
        }
    }
}

/// iPhone-bildet stort ved siden av det analoge, med knapper for å bruke det eller lukke.
struct ComparePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    let asset: PHAsset
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Bruk dette") {
                    let targets = model.selectedIDs
                    Task { await model.copy(from: asset, phone: phone, to: targets) }
                }
                Button("Lukk") { model.compareAsset = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            phone.imageManager.requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                            contentMode: .aspectFit, options: options) { result, _ in
                if let result { image = result }
            }
        }
    }
}

/// Forslag fra bildene rundt på rullen: nærmeste bilde med dato eller sted før og etter.
private struct RollNeighbors: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let info = model.info(id)
        let n = model.rollNeighbors(of: id)
        let before = n.before.map { (model.info($0.id), $0.steps) }
        let after = n.after.map { (model.info($0.id), $0.steps) }
        if info.day == nil || info.place == nil, before != nil || after != nil {
            LabeledContent("På rullen") {
                VStack(alignment: .leading, spacing: 4) {
                    if let b = before, let a = after, b.0.day == a.0.day, b.0.place?.name == a.0.place?.name {
                        row("Bildene før og etter", b.0)
                    } else {
                        if let b = before { row(b.1 == 1 ? "Bildet før" : "\(b.1) bilder før", b.0) }
                        if let a = after { row(a.1 == 1 ? "Bildet etter" : "\(a.1) bilder etter", a.0) }
                    }
                }
            }
            .help(model.scanTimes.isEmpty ? "Rekkefølgen er etter filnavn (ingen skannetid i filene)."
                                           : "Rekkefølgen er etter skannetiden i filene.")
        }
    }

    private func row(_ label: String, _ other: PhotoInfo) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Text([other.day?.norwegian, other.place?.name].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
            Spacer()
            Button("Bruk") {
                model.apply(day: other.day, place: other.place, source: .roll)
            }
            .controlSize(.small)
        }
    }
}

/// Tekst funnet i bildet (skilt, motellnavn …), med søk etter stedet teksten nevner.
private struct TextInPhoto: View {
    @Environment(AppModel.self) private var model
    @Environment(SimilarityIndex.self) private var similarity
    let id: String
    @State private var searching: String?
    @State private var found: (text: String, place: Place?)?

    var body: some View {
        let lines = Array((similarity.texts[id] ?? []).prefix(4))
        if !lines.isEmpty {
            LabeledContent("Tekst i bildet") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.self) { line in
                        HStack {
                            Text("«\(line)»").lineLimit(1)
                            Spacer()
                            if searching == line {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Søk sted") { search(line) }.controlSize(.small)
                            }
                        }
                    }
                    if let found {
                        if let place = found.place {
                            HStack {
                                Text("Fant: \(place.name)").foregroundStyle(.secondary)
                                Spacer()
                                Button("Bruk") { model.apply(day: nil, place: place, source: .manual) }.controlSize(.small)
                            }
                        } else {
                            Text("Fant ikke noe sted for «\(found.text)».").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func search(_ text: String) {
        searching = text
        Task {
            let place = await AppModel.lookUpPlace(text)
            searching = nil
            found = (text, place)
        }
    }
}

/// Område over stedet (f.eks. «Blue Ridge Mountains» over «Sylva»), med forslag mens du skriver.
private struct AreaField: View {
    @Environment(AppModel.self) private var model
    let id: String
    let forSelected: ((inout PhotoInfo) -> Void) -> Void
    @State private var edited = false

    var body: some View {
        let current = model.info(id).area ?? ""
        let options = edited ? Array(model.areaOptions(for: id, typed: current).filter { $0.title != current }.prefix(6))
                             : (current.isEmpty ? Array(model.areaOptions(for: id, typed: "").prefix(4)) : [])
        TextField("Område", text: Binding(get: { model.info(id).area ?? "" },
                                         set: { text in
                                             edited = true
                                             forSelected { $0.area = text.isEmpty ? nil : text }
                                         }),
                  prompt: Text("Valgfritt, f.eks. Blue Ridge Mountains"))
            .onSubmit { edited = false }
            .task(id: model.info(id).place) { await model.loadAreaHints(for: id) }
        if !options.isEmpty {
            HStack(spacing: 6) {
                Text(edited ? "Forslag:" : "Område?").font(.caption).foregroundStyle(.secondary)
                ForEach(options) { option in
                    Button(option.title) {
                        forSelected { $0.area = option.title }
                        edited = false
                    }
                    .controlSize(.small)
                    .help(option.detail)
                }
            }
        }
    }
}
