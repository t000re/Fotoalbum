import MapKit
import SwiftUI

/// «Steder på turen»: stedene fra iPhone-bildenes GPS, i rekkefølge. Klikk «Bruk» for å gi de valgte
/// analoge bildene stedet, eller «Vis» for å se iPhone-bildene derfra.
struct TripPlacesList: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @AppStorage("iPhoneFane") private var tab = "bilder"
    @State private var filter = ""
    @State private var editing: UUID?
    @State private var newName = ""

    var body: some View {
        let places = model.tripPlaces.filter {
            filter.isEmpty || $0.name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        VStack(spacing: 0) {
            HStack {
                TextField("Filtrer steder", text: $filter).textFieldStyle(.roundedBorder)
                if let progress = model.placesProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 60)
                    Text("\(progress.done)/\(progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Button { Task { await model.buildTripPlaces(from: phone) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Lag lista på nytt fra iPhone-bildene (navn du har gitt selv, beholdes)")
                }
            }
            .padding(8)
            List {
                ForEach(places) { place in
                    row(place)
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.tripPlaces.isEmpty && model.placesProgress == nil {
                    Text("Ingen steder ennå. Sett datoene for turen øverst.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ place: TripPlace) -> some View {
        let current = model.selection.flatMap { model.info($0).place?.name } == place.name
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if editing == place.id {
                    TextField("Navn", text: $newName)
                        .onSubmit { model.renameTripPlace(place.id, to: newName); editing = nil }
                        .onExitCommand { editing = nil }
                } else {
                    Text(place.name).fontWeight(current ? .bold : .regular)
                        .onTapGesture(count: 2) { newName = place.name; editing = place.id }
                }
                Text("\(place.dayRange) · \(place.photoCount) bilder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Vis") {
                phone.area = MKCoordinateRegion(center: .init(latitude: place.latitude, longitude: place.longitude),
                                                span: .init(latitudeDelta: 0.3, longitudeDelta: 0.4))
                phone.areaName = place.name
                tab = "bilder"
            }
            .help("Vis iPhone-bildene derfra")
            Button("Bruk") { model.applyTripPlace(place) }
                .disabled(model.selected.isEmpty)
                .help(place.firstDay == place.lastDay
                      ? "Gi de valgte bildene stedet (og datoen, hvis de mangler den)"
                      : "Gi de valgte bildene stedet")
        }
        .contextMenu {
            Button("Gi nytt navn …") { newName = place.name; editing = place.id }
        }
    }
}
