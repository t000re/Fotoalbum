import MapKit
import SwiftUI

/// Eget vindu med oversikt: hvor langt du har kommet, bildene per dag og per sted, og et kart.
/// Klikk på en dag eller et sted viser bare de bildene i hovedvinduet.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.days

    enum Tab: String, CaseIterable { case days = "Dager", places = "Steder", map = "Kart" }

    var body: some View {
        VStack(spacing: 0) {
            Progress()
                .padding(12)
            Picker("Vis", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            switch tab {
            case .days: DaysList()
            case .places: PlacesList()
            case .map: AnalogMap()
            }
        }
        .frame(minWidth: 380, minHeight: 500)
    }
}

/// Hvor mange av bildene som har dato, sted og beskrivelse.
private struct Progress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let infos = model.photos.map { model.info($0.id) }
        let total = max(infos.count, 1)
        VStack(alignment: .leading, spacing: 6) {
            row("Dato", infos.filter { $0.day != nil }.count, total, .missingDay)
            row("Sted", infos.filter { $0.place != nil }.count, total, .missingPlace)
            row("Beskrivelse", infos.filter { !AppModel.Filter.noCaption.includes($0) }.count, total, .noCaption)
        }
    }

    /// Én linje: navn, stolpe, «312 av 390», og en knapp som viser de som mangler.
    private func row(_ title: String, _ done: Int, _ total: Int, _ filter: AppModel.Filter) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            ProgressView(value: Double(done), total: Double(total))
            Text("\(done) av \(model.photos.count)").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Button("Vis mangler") {
                model.subset = nil
                model.filter = filter
                model.selectNext(0)
            }
            .disabled(done == model.photos.count)
        }
    }
}

/// Dagene med analoge bilder: dato, antall og stedene den dagen.
private struct DaysList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.photos.map(\.id)) { model.info($0).day }
        let days = groups.keys.compactMap { $0 }.sorted()
        List {
            ForEach(days, id: \.self) { day in
                let ids = groups[day]!
                Button {
                    model.show(day.norwegian, ids: Set(ids))
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(day.norwegian).frame(width: 110, alignment: .leading)
                        Text(places(ids)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Text("\(ids.count)").monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let undated = groups[nil] {
                Button {
                    model.show("Uten dato", ids: Set(undated))
                } label: {
                    HStack {
                        Text("Uten dato").italic()
                        Spacer()
                        Text("\(undated.count)").monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay { if days.isEmpty && groups[nil] == nil { Text("Ingen bilder").foregroundStyle(.secondary) } }
    }

    /// Stedene en dag, i rekkefølgen de er mest brukt.
    private func places(_ ids: [String]) -> String {
        let names = ids.compactMap { model.info($0).place?.name }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value > $1.value }.map(\.key).joined(separator: ", ")
    }
}

/// Alle stedsnavn i bruk. Navnet kan endres her, og gjelder da alle bildene med det navnet.
/// Skriver du et navn som finnes fra før, slås stedene sammen.
private struct PlacesList: View {
    @Environment(AppModel.self) private var model
    @State private var searching = false
    @State private var result: String?

    var body: some View {
        let places = model.placeNames
        let missing = model.placesWithoutCoordinates
        List {
            Text("Endre et navn for å endre det på alle bildene. Bruk samme navn som et annet sted for å slå dem sammen.")
                .font(.caption).foregroundStyle(.secondary)
            if !missing.isEmpty || result != nil {
                HStack {
                    if !missing.isEmpty {
                        Label("\(missing.count) steder uten kartpunkt", systemImage: "mappin.slash").foregroundStyle(.orange)
                        Spacer()
                        if searching { ProgressView().controlSize(.small) }
                        Button("Finn kartpunkt") {
                            searching = true
                            Task {
                                let r = await model.findMissingCoordinates()
                                searching = false
                                result = r.missing.isEmpty ? "Fant kartpunkt for \(r.found) steder."
                                    : "Fant \(r.found). Ikke funnet: \(r.missing.joined(separator: ", ")) – prøv et tydeligere navn."
                            }
                        }
                        .disabled(searching)
                    }
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach(places, id: \.name) { place in
                PlaceRow(name: place.name, ids: place.ids)
            }
            let areas = model.areaNames
            if !areas.isEmpty {
                Section("Områder") {
                    ForEach(areas, id: \.name) { area in
                        AreaRow(name: area.name, ids: area.ids)
                    }
                }
            }
        }
        .overlay { if places.isEmpty { Text("Ingen steder ennå").foregroundStyle(.secondary) } }
    }
}

private struct PlaceRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let ids: Set<String>
    @State private var text = ""

    var body: some View {
        let days = ids.compactMap { model.info($0).day }.sorted()
        HStack {
            TextField("Sted", text: $text)
                .textFieldStyle(.plain)
                .onSubmit { model.renamePlace(name, to: text) }
            Text(dayRange(days)).foregroundStyle(.secondary).lineLimit(1)
            Text("\(ids.count)").monospacedDigit().frame(width: 30, alignment: .trailing)
            Button("Vis") { model.show(name, ids: ids) }
        }
        .onAppear { text = name }
        .onChange(of: name) { text = name }
    }

    private func dayRange(_ days: [Day]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return first == last ? first.norwegian : "\(first.norwegian) – \(last.norwegian)"
    }
}

/// Kart over stedene de analoge bildene har fått. Klikk på et sted for å vise bildene derfra.
private struct AnalogMap: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let places = model.placeNames.compactMap { place -> (name: String, ids: Set<String>, c: CLLocationCoordinate2D)? in
            // Koordinatene fra første bilde med koordinater for dette navnet.
            for id in place.ids {
                if let p = model.info(id).place, let lat = p.latitude, let lon = p.longitude {
                    return (place.name, place.ids, .init(latitude: lat, longitude: lon))
                }
            }
            return nil
        }
        let withoutCoordinates = model.placeNames.count - places.count
        Map {
            ForEach(places, id: \.name) { place in
                Annotation(place.name, coordinate: place.c) {
                    Text("\(place.ids.count)")
                        .font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .onTapGesture { model.show(place.name, ids: place.ids) }
                }
            }
        }
        .mapControls { MapZoomStepper() }
        .overlay(alignment: .bottom) {
            if withoutCoordinates > 0 {
                Text("\(withoutCoordinates) steder er skrevet inn for hånd og har ikke kartpunkt")
                    .font(.caption).padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
    }
}

/// Et område i oversikten: navnet kan endres (gjelder alle bildene i området).
private struct AreaRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let ids: [String]
    @State private var text = ""

    var body: some View {
        let places = Set(ids.compactMap { model.info($0).place?.name }).sorted()
        HStack {
            Image(systemName: "mountain.2").foregroundStyle(.secondary)
            TextField("Område", text: $text)
                .textFieldStyle(.plain)
                .onSubmit { model.renameArea(name, to: text) }
            Text(places.prefix(3).joined(separator: ", ") + (places.count > 3 ? " …" : ""))
                .foregroundStyle(.secondary).lineLimit(1)
            Text("\(ids.count)").monospacedDigit().frame(width: 30, alignment: .trailing)
            Button("Vis") { model.show(name, ids: Set(ids)) }
        }
        .onAppear { text = name }
        .onChange(of: name) { text = name }
    }
}
