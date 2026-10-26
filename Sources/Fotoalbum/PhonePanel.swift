import Photos
import SwiftUI

/// Panelet med iPhone-bildene fra turen, gruppert per dag.
/// Klikk på et bilde kopierer dato og sted til de valgte analoge bildene.
struct PhonePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @Environment(SimilarityIndex.self) private var similarity
    /// «Bilder» eller «Steder».
    @AppStorage("iPhoneFane") private var tab = "bilder"

    var body: some View {
        VStack(spacing: 0) {
            switch phone.access {
            case .unknown:
                ContentUnavailableView {
                    Label("iPhone-bilder", systemImage: "iphone")
                } description: {
                    Text("Appen trenger tilgang til Bilder for å vise iPhone-bildene fra turen. Den bare leser – ingenting endres, og ingenting sendes ut.")
                } actions: {
                    Button("Gi tilgang til Bilder") {
                        Task { await phone.requestAccess(); reload() }
                    }
                }
            case .denied:
                ContentUnavailableView {
                    Label("Ingen tilgang til Bilder", systemImage: "lock")
                } description: {
                    Text("Slå på Fotoalbum under Systeminnstillinger → Personvern og sikkerhet → Bilder, og start appen på nytt.")
                } actions: {
                    Button("Åpne Systeminnstillinger") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    }
                }
            case .granted:
                header
                Picker("Vis", selection: $tab) {
                    Text("Bilder").tag("bilder")
                    Text("Steder på turen").tag("steder")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8).padding(.bottom, 6)
                if tab == "steder" {
                    Divider()
                    TripPlacesList()
                } else {
                    SuggestionStrip()
                    Divider()
                    PhoneSearch()
                    Divider()
                    PhoneDays()
                }
                Divider()
                footer
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.projectID) {
            phone.clearArea()
            reload()
        }
    }

    private func reload() {
        phone.load(from: model.tripStart, to: model.tripEnd)
        guard phone.access == .granted else { return }
        model.setRoute(phone.route)
        // Fingeravtrykk for bildelikhet (bare de som mangler; resten ligger lagret).
        similarity.index(photos: model.photos, phone: phone)
        // Stedslista lages første gang (og når den er tom).
        if model.tripPlaces.isEmpty, !phone.located.isEmpty, model.placesProgress == nil {
            Task { await model.buildTripPlaces(from: phone) }
        }
        // Analoge bilder koblet til et iPhone-bilde før klokkeslettet ble lagret, får det nå.
        let missing = model.project.photos.filter { $0.value.phoneID != nil && $0.value.time == nil }
        let dates = phone.creationDates(for: missing.compactMap(\.value.phoneID))
        for (id, info) in missing {
            if let date = dates[info.phoneID!] { model.update(id) { $0.time = date } }
        }
    }

    /// Perioden: fra–til.
    private var header: some View {
        HStack {
            Text("Turen").font(.headline)
            DatePicker("Fra", selection: dayBinding(\.tripStart), displayedComponents: .date)
                .labelsHidden()
            Text("–")
            DatePicker("Til", selection: dayBinding(\.tripEnd), displayedComponents: .date)
                .labelsHidden()
            Spacer()
            let shown = phone.visibleDays.reduce(0) { $0 + $1.assets.count }
            Text(phone.area == nil ? "\(phone.count) bilder" : "\(shown) av \(phone.count) bilder")
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .datePickerStyle(.field)
        .environment(\.locale, Locale(identifier: "nb_NO"))
        .padding(8)
    }

    private func dayBinding(_ key: ReferenceWritableKeyPath<AppModel, Day>) -> Binding<Date> {
        Binding(get: { model[keyPath: key].date },
                set: { model[keyPath: key] = Day($0); reload() })
    }

    private var footer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Samme som sist") { model.applySameAsLast() }
                    .disabled(model.project.lastDay == nil && model.project.lastPlace == nil)
                Text([model.project.lastDay?.norwegian, model.project.lastPlace?.name]
                        .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            Toggle("Gå til neste bilde etter kopiering", isOn: $model.advanceAfterCopy)
            Text("Klikk et iPhone-bilde for å kopiere dato og sted til \(model.selected.count > 1 ? "de \(model.selected.count) valgte bildene" : "det valgte bildet"). ⌘D: samme som sist.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

/// Dagene med iPhone-bilder. Ruller automatisk til datoen til det valgte analoge bildet,
/// eller til sist brukte dato.
private struct PhoneDays: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @State private var copying: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: .sectionHeaders) {
                    ForEach(phone.visibleDays) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                                ForEach(group.assets, id: \.localIdentifier) { asset in
                                    cell(asset)
                                }
                            }
                            .padding(.horizontal, 8)
                        } header: {
                            HStack {
                                Text(group.day.norwegian).font(.headline)
                                Text("\(group.assets.count)").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.bar)
                        }
                        .id(group.day)
                    }
                }
            }
            .overlay {
                if phone.visibleDays.isEmpty { Text(phone.area == nil ? "Ingen iPhone-bilder i perioden" : "Ingen iPhone-bilder i området").foregroundStyle(.secondary) }
            }
            .onAppear { scroll(proxy) }
            .onChange(of: model.selection) { scroll(proxy) }
            .onChange(of: phone.count) { scroll(proxy) }
            .onChange(of: phone.areaName) {
                // Nytt område: start øverst, på første dag med bilder derfra.
                if let first = phone.visibleDays.first?.day { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    private func cell(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let matched = model.selection.map { model.info($0).phoneID == id } ?? false
        return PhoneThumbnail(asset: asset, manager: phone.imageManager)
            .overlay(alignment: .bottomTrailing) {
                if asset.location == nil {
                    Image(systemName: "location.slash.fill")
                        .font(.caption2).padding(3)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white).padding(3)
                        .help("Uten sted – bare datoen kopieres")
                }
            }
            .overlay {
                if copying == id { ProgressView().controlSize(.small) }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: matched ? 3 : 0))
            .contentShape(Rectangle())
            .onTapGesture { copy(asset) }
            .contextMenu { Button("Sammenlign med det analoge bildet") { model.compareAsset = asset } }
            .help(time(of: asset))
    }

    /// Kopierer dato og sted fra iPhone-bildet til bildene som var valgt da du klikket.
    private func copy(_ asset: PHAsset) {
        let targets = model.selectedIDs
        guard !targets.isEmpty, copying == nil else { return }
        copying = asset.localIdentifier
        Task {
            await model.copy(from: asset, phone: phone, to: targets)
            copying = nil
        }
    }

    private func time(of asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "nb_NO")
        f.dateFormat = "HH:mm"
        f.timeZone = asset.location.map { PhoneLibrary.approximateZone($0.coordinate) } ?? .current
        return "Kl. \(f.string(from: date)) (omtrent lokal tid)" + (asset.location == nil ? " · uten sted" : "")
    }

    /// Ruller til dagen til det valgte bildet, eller nærmeste dag etter.
    private func scroll(_ proxy: ScrollViewProxy) {
        let target = model.selection.flatMap { model.info($0).day } ?? model.project.lastDay
        guard let target, let day = phone.visibleDays.first(where: { $0.day >= target })?.day ?? phone.visibleDays.last?.day else { return }
        proxy.scrollTo(day, anchor: .top)
    }
}
