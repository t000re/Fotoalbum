import MapKit
import Photos
import SwiftUI

/// Hovedvinduet: ett analogt bilde om gangen.
/// Venstre: like iPhone-bilder. Midten: bildet med merkelapper øverst og et glassfelt med forslag nederst.
/// Høyre: område- og datovelger, iPhone-bilder derfra med datooverskrifter, og kart. Nederst: alle bildene.
struct FocusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FocusSimilar()
                    .frame(width: 210)
                Divider()
                Group {
                    if model.focus.isFinished || model.focus.queue.isEmpty {
                        finished
                    } else {
                        FocusStage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                FocusBrowse()
                    .frame(width: 360)
            }
            Divider()
            Filmstrip()
                .frame(height: 96)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var finished: some View {
        ContentUnavailableView {
            Label("Alle bildene har sted og dato", systemImage: "checkmark.circle")
        } description: {
            Text("Klikk et bilde i linja nederst for å se eller endre det.")
        }
    }
}

// MARK: Midten

/// Bildet stort, merkelapper øverst og glassfeltet nederst.
private struct FocusStage: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let focus = model.focus
        let id = focus.current!
        ZStack {
            if let url = model.url(of: id) {
                PhotoImage(url: url, maxPixels: 2400)
                    .padding(.horizontal, 24).padding(.vertical, 70)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            }
            VStack {
                Chips(id: id)
                    .padding(.top, 14)
                Spacer()
                VStack(spacing: 8) {
                    let options = Array(model.focusOptions.prefix(5))
                    if !options.isEmpty {
                        Suggestions(options: options, highlighted: focus.highlighted) { index in
                            model.focus.highlighted = index
                            model.focusConfirm()
                        }
                    }
                    if let message = focus.message {
                        Text(message).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                            .glass(in: Capsule())
                    }
                    field
                }
                .frame(maxWidth: 640)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: focus.step) { fieldFocused = true }
        .onChange(of: focus.index) { fieldFocused = true }
        .onChange(of: model.placeSearch.results) { if focus.edited { model.focusRefreshHighlight(onlyIfNone: true) } }
        .onChange(of: model.areaSearch.results) { if focus.edited { model.focusRefreshHighlight(onlyIfNone: true) } }
    }

    private var field: some View {
        @Bindable var focus = model.focus
        let prompt: String = switch focus.step {
        case .region: "Stat, fylke eller land – f.eks. New Mexico"
        case .area: "Område (valgfritt), f.eks. Blue Ridge Mountains"
        case .place: "Hvor er bildet tatt?"
        case .day: "Når? F.eks. 14.7 eller 14. juli"
        case .caption: "Beskrivelse (valgfritt) – Enter for neste bilde"
        }
        return HStack(spacing: 10) {
            Button { model.focusBack() } label: {
                Image(systemName: "arrow.left").frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glass(in: Circle())
            .help("Tilbake (⇧Enter)")

            TextField(prompt, text: $focus.text, axis: focus.step == .caption ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(focus.step == .caption ? 1...4 : 1...1)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .glass(in: RoundedRectangle(cornerRadius: 22))
                .focused($fieldFocused)
                .onChange(of: focus.text) { if focus.text != focus.loadedText { model.focusTextChanged() } }
                // Enter fanges i onKeyPress under; onSubmit er reserve hvis tasten går forbi (aldri begge).
                .onSubmit { model.focusConfirm() }
                .onKeyPress(.upArrow) { model.focusMoveHighlight(-1); return .handled }
                .onKeyPress(.downArrow) { model.focusMoveHighlight(1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { model.focusBack(); return .handled }
                    if press.modifiers.contains(.option) { return .ignored }  // ⌥Enter: ny linje i beskrivelsen
                    model.focusConfirm()
                    return .handled
                }

            Button { model.focusConfirm() } label: {
                Image(systemName: "arrow.right").frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glass(in: Circle())
            .help("Videre (Enter)")

            if focus.step != .caption {
                Button(focus.step == .area || focus.step == .region ? "Uten" : "Vet ikke") { model.focusDontKnow() }
                    .keyboardShortcut("k")
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glass(in: Capsule())
                    .help(focus.step == .region ? "Uten regionfilter (⌘K)"
                          : focus.step == .area ? "Uten område (⌘K)" : "Vet ikke (⌘K) – finnes igjen under filteret «Vet ikke»")
            }
        }
    }
}

/// Merkelappene øverst: Region · Sted · Dato · Beskrivelse. Klikk for å endre.
private struct Chips: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let i = model.info(id)
        HStack(spacing: 8) {
            chip(.region, "globe", model.regionLabel(i), "Region")
            chip(.place, "mappin", i.place?.name ?? (i.placeIsUnknown ? "Vet ikke" : nil), "Sted")
            chip(.day, "calendar", i.day?.norwegian ?? (i.dayIsUnknown ? "Vet ikke" : nil), "Dato")
            chip(.caption, "text.alignleft", i.caption.isEmpty ? nil : i.caption, "Beskrivelse")
        }
    }

    private func chip(_ step: FocusSession.Step, _ icon: String, _ value: String?, _ placeholder: String) -> some View {
        let active = model.focus.step == step
        return Button {
            model.loadFocusStep(step)
        } label: {
            Label(value ?? placeholder, systemImage: icon)
                .lineLimit(1)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .fontWeight(active ? .semibold : .regular)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(maxWidth: step == .day ? 200 : 320)
        }
        .buttonStyle(.plain)
        .glass(in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor, lineWidth: active ? 2 : 0))
        .help(value.map { "\(placeholder): \($0) – klikk for å endre" } ?? "Legg til \(placeholder.lowercased())")
    }
}

/// Opptil fem forslag over feltet. Markert forslag brukes med Enter.
private struct Suggestions: View {
    let options: [FocusSession.Option]
    let highlighted: Int?
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                HStack {
                    Text(option.title).lineLimit(1)
                    Spacer()
                    Text(option.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(index == highlighted ? Color.accentColor.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(6)
        .glass(in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: Venstre: like bilder

private struct FocusSimilar: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @Environment(SimilarityIndex.self) private var similarity

    var body: some View {
        let region = model.focusPreviewRegion
        VStack(alignment: .leading, spacing: 8) {
            Text("Like bilder").font(.headline)
            if let name = World.filterName(region) {
                Text("innenfor \(name)").font(.caption).foregroundStyle(.secondary)
            }
            if let p = similarity.progress {
                Text("Analyserer \(p.done) av \(p.total)").font(.caption).foregroundStyle(.secondary)
            }
            if similarity.suggestions.isEmpty {
                Text("Ingen forslag").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(similarity.suggestions.enumerated()), id: \.element.asset.localIdentifier) { index, s in
                        PhoneChoice(asset: s.asset, label: "⌃\(index + 1)", detail: String(format: "%.2f", s.distance), aspect: 4 / 3)
                    }
                }
            }
        }
        .padding(12)
        .task(id: SimilarKey(selection: model.focus.current, area: region, shape: nil,
                             // Regn ut på nytt når analysen har kommet et stykke videre, og når den er ferdig.
                             progress: similarity.progress.map { $0.done / 100 } ?? -1,
                             analog: similarity.analogPrintCount + model.regionCacheVersion * 100_000)) {
            similarity.suggest(for: model.focus.current, phone: phone, allowed: model.focusAllowedPhoneIDs)
            if let id = model.focus.current { await model.refreshAreaSuggestions(for: id) }
        }
    }
}

private struct SimilarKey: Hashable {
    let selection: String?
    let area: String?
    let shape: AreaShape?
    let progress: Int
    let analog: Int
}

/// Et iPhone-bilde som kan velges: kopierer sted og dato til det analoge bildet.
struct PhoneChoice: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    let asset: PHAsset
    var label: String?
    var detail: String?
    var aspect: CGFloat = 1
    @State private var copying = false

    var body: some View {
        let matched = model.focus.current.map { model.info($0).phoneID == asset.localIdentifier } ?? false
        VStack(alignment: .leading, spacing: 2) {
            PhoneThumbnail(asset: asset, manager: phone.imageManager, aspect: aspect)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let label {
                        Text(label).font(.caption2.bold()).padding(3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white).padding(4)
                    }
                }
                .overlay { if copying { ProgressView().controlSize(.small) } }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: matched ? 3 : 0))
            if label != nil {
                HStack {
                    Text(asset.creationDate.map { Day($0, timeZone: asset.location.map { PhoneLibrary.approximateZone($0.coordinate) } ?? .current).norwegian } ?? "")
                    Spacer()
                    if let detail { Text(detail).foregroundStyle(.tertiary).monospacedDigit() }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let id = model.focus.current else { return }
            copying = true
            Task {
                await model.copy(from: asset, phone: phone, to: [id])
                copying = false
                model.focusDidFill()
            }
        }
        .help("Bruk sted og dato fra dette bildet")
    }
}

// MARK: Høyre: område, dato, iPhone-bilder og kart

private struct FocusBrowse: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @State private var position: MapCameraPosition = .automatic

    static let maxPhotos = 1000

    var body: some View {
        let focus = model.focus
        // Området, eller 100 km rundt bildets sted hvis det ikke har område.
        let shape = model.focusFilterShape
        let day = model.focusPreviewDay
        let _ = model.regionCacheVersion  // tegn på nytt når regionene for iPhone-bildene er regnet ut
        let groups = photoGroups(shape: shape, day: day)
        VStack(alignment: .leading, spacing: 10) {
            areaPicker
            dayPicker(shape: shape)
            Divider()
            if shape == nil && day == nil {
                Text("Velg en region eller en dag for å se iPhone-bildene derfra.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text("Ingen iPhone-bilder her.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: .sectionHeaders) {
                    Color.clear.frame(height: 0).id("topp")
                    ForEach(groups, id: \.day) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                                ForEach(group.assets, id: \.localIdentifier) { PhoneChoice(asset: $0) }
                            }
                        } header: {
                            HStack {
                                Text(group.day.norwegian).font(.headline)
                                Text("\(group.assets.count)").foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .background(.bar)
                        }
                    }
                }
            }
            // Nytt bilde, ny region eller dag: start øverst i lista.
            .onChange(of: TopKey(photo: focus.current, region: model.focusPreviewRegion, day: day)) {
                proxy.scrollTo("topp", anchor: .top)
            }
            }
            map(shape: shape)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        // Finn formen til området som vises (også mens du blar i forslagene).
    }

    /// Regionvelger: forrige bildes region, bildene rundt, de like bildene, hele landet; eller skriv selv.
    private var areaPicker: some View {
        let focus = model.focus
        let current = World.filterName(model.focusPreviewRegion)
        let options = focus.current.map { Array(model.regionOptions(for: $0, typed: "").prefix(10)) } ?? []
        return HStack {
            Image(systemName: "globe").foregroundStyle(.secondary)
            Menu {
                ForEach(options) { option in
                    Button("\(option.title) – \(option.detail)") { model.focusPickRegion(option.code) }
                }
                Divider()
                Button("Skriv region …") { model.loadFocusStep(.region) }
                Button("Ingen filter") { model.focusPickRegion(nil) }
            } label: {
                Text(current ?? "Alle regioner").lineLimit(1)
            }
            .help("Regionen (stat, fylke, land) filtrerer iPhone-bilder, like bilder og stedsforslag, og står til neste bilde.")
        }
    }

    /// Datovelger: én dag (med ‹ ›) eller alle dager; dagene med iPhone-bilder i området, med antall.
    private func dayPicker(shape: AreaShape?) -> some View {
        let focus = model.focus
        var counts: [Day: Int] = [:]
        let filter = model.focusPreviewRegion
        for group in phone.days {
            let n = group.assets.filter { model.assetMatches($0, filter) }.count
            if n > 0 { counts[group.day] = n }
        }
        let days = counts.keys.sorted()
        return HStack {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Button { step(days, -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(focus.browseDay == nil || days.first.map { focus.browseDay! <= $0 } ?? true)
            Menu {
                Button("Alle dager") { model.focus.browseDay = nil }
                Divider()
                ForEach(days, id: \.self) { day in
                    Button("\(day.norwegian) – \(counts[day]!) bilder") { model.focus.browseDay = day }
                }
            } label: {
                Text(model.focusPreviewDay?.norwegian ?? "Alle dager").lineLimit(1)
            }
            Button { step(days, 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(focus.browseDay == nil || days.last.map { focus.browseDay! >= $0 } ?? true)
        }
    }

    private func step(_ days: [Day], _ direction: Int) {
        guard let current = model.focus.browseDay else { return }
        let next = direction > 0 ? days.first { $0 > current } : days.last { $0 < current }
        if let next { model.focus.browseDay = next }
    }

    /// iPhone-bilder i området (og dagen), gruppert per dag i tidsrekkefølge.
    private func photoGroups(shape: AreaShape?, day: Day?) -> [PhoneLibrary.DayGroup] {
        guard shape != nil || day != nil else { return [] }
        var total = 0
        return phone.days.compactMap { group in
            guard day == nil || group.day == day, total < Self.maxPhotos else { return nil }
            let filter = model.focusPreviewRegion
            let assets = group.assets.filter { model.assetMatches($0, filter) }
            total += assets.count
            return assets.isEmpty ? nil : PhoneLibrary.DayGroup(day: group.day, assets: assets)
        }
    }

    /// Kart: ruten, området og bildets sted.
    private func map(shape: AreaShape?) -> some View {
        let place = model.focus.current.flatMap { model.info($0).place }
        let point = place.flatMap { p in p.latitude.map { GeoPoint(lat: $0, lon: p.longitude!) } }
        return Map(position: $position) {
            if let route = model.project.route, route.count > 1 {
                MapPolyline(coordinates: route.map { .init(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(Color(cgColor: MapRenderer.routeColor), lineWidth: 2)
            }
            ForEach(Array((shape?.rings ?? []).enumerated()), id: \.offset) { _, ring in
                MapPolygon(coordinates: ring.map { .init(latitude: $0.lat, longitude: $0.lon) })
                    .foregroundStyle(.orange.opacity(0.12))
                    .stroke(.orange, lineWidth: 1.5)
            }
            if case .circle(let c, let km) = shape {
                MapCircle(center: .init(latitude: c.lat, longitude: c.lon), radius: km * 1000)
                    .foregroundStyle(.orange.opacity(0.12))
                    .stroke(.orange, lineWidth: 1.5)
            }
            if let point, let name = place?.name {
                Marker(name, coordinate: .init(latitude: point.lat, longitude: point.lon)).tint(.red)
            }
        }
        .onChange(of: ZoomKey(point: point, shape: shape), initial: true) { _, key in
            withAnimation {
                if let shape = key.shape {
                    position = .region(shape.region)
                } else if let p = key.point {
                    position = .region(MKCoordinateRegion(center: .init(latitude: p.lat, longitude: p.lon),
                                                          span: .init(latitudeDelta: 2.5, longitudeDelta: 3)))
                } else {
                    position = .automatic
                }
            }
        }
    }

    private struct ZoomKey: Equatable {
        let point: GeoPoint?
        let shape: AreaShape?
    }

    private struct TopKey: Equatable {
        let photo: String?
        let region: String?
        let day: Day?
    }
}

// MARK: Nederst: bildelinja

/// Alle bildene i rekkefølge: ferdige (krysset ut) til venstre, gjeldende i midten, kommende til høyre.
private struct Filmstrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let focus = model.focus
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(focus.queue.enumerated()), id: \.element) { index, id in
                        cell(index, id)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: focus.index, initial: true) { _, i in
                withAnimation { proxy.scrollTo(min(i, max(focus.queue.count - 1, 0)), anchor: .center) }
            }
        }
    }

    private func cell(_ index: Int, _ id: String) -> some View {
        let current = index == model.focus.index
        let done = model.isFocusDone(id)
        return ZStack {
            if let url = model.url(of: id) {
                PhotoImage(url: url, maxPixels: 220)
            }
        }
        .frame(width: current ? 104 : 84, height: current ? 76 : 60)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(done && !current ? 0.45 : 1)
        .overlay {
            if done && !current {
                Image(systemName: "xmark").font(.title2.weight(.light)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: current ? 3 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.focusJump(to: index) }
        .help(done ? "Ferdig – klikk for å se eller endre" : "Klikk for å gå hit")
    }
}
