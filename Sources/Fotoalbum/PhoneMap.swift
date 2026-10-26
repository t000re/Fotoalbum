import MapKit
import SwiftUI

/// Søkefelt og kart over iPhone-bildene. Søk på et sted («Montana») eller zoom kartet,
/// så viser panelet bare bildene derfra.
struct PhoneSearch: View {
    @Environment(PhoneLibrary.self) private var phone
    @AppStorage("visKart") private var showMap = true
    @State private var text = ""
    @State private var notFound = false
    @State private var position: MapCameraPosition = .automatic
    /// Settes når vi flytter kartet selv (etter søk), så navnet på området beholdes.
    @State private var movedByCode = false
    @State private var lastRegion: MKCoordinateRegion?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Søk etter sted, f.eks. Montana", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if let name = phone.areaName {
                    Button {
                        phone.clearArea()
                        text = ""
                    } label: {
                        Label(name, systemImage: "xmark.circle.fill").lineLimit(1)
                    }
                    .help("Vis alle bildene igjen")
                }
                Toggle(isOn: $showMap) { Image(systemName: "map") }
                    .toggleStyle(.button)
                    .help("Vis eller skjul kartet")
            }
            if notFound {
                Text("Fant ikke «\(text)»").font(.caption).foregroundStyle(.secondary)
            }
            if showMap { map }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }

    private var map: some View {
        Map(position: $position) {
            ForEach(phone.mapPoints) { point in
                Annotation("", coordinate: point.coordinate, anchor: .center) {
                    let size = 8 + min(14, log2(Double(point.count)) * 2.5)
                    Circle()
                        .fill(Color.accentColor.opacity(0.85))
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                        .frame(width: size, height: size)
                        .onTapGesture { zoom(to: point.coordinate) }
                        .help("\(point.count) bilder")
                }
            }
            if let place = selectedPlace, let lat = place.latitude, let lon = place.longitude {
                Marker(place.name, coordinate: .init(latitude: lat, longitude: lon)).tint(.red)
            }
        }
        .mapControls { MapZoomStepper() }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            if phone.area == nil {
                Button("Vis bare bilder herfra") {
                    guard let lastRegion else { return }
                    phone.area = lastRegion
                    phone.areaName = "Kartutsnittet"
                }
                .padding(6)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            lastRegion = context.region
            guard phone.area != nil else { return }
            phone.area = context.region
            if !movedByCode { phone.areaName = "Kartutsnittet" }
            movedByCode = false
        }
    }

    @Environment(AppModel.self) private var model
    /// Stedet til det valgte analoge bildet, vist som rød nål.
    private var selectedPlace: Place? { model.selection.flatMap { model.info($0).place } }

    private func search() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { phone.clearArea(); return }
        Task {
            notFound = !(await phone.search(query))
            if let area = phone.area, !notFound {
                movedByCode = true
                withAnimation { position = .region(area) }
            }
        }
    }

    /// Klikk på en prikk: zoom inn dit og vis bare bildene derfra.
    private func zoom(to coordinate: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(center: coordinate, span: .init(latitudeDelta: 0.3, longitudeDelta: 0.4))
        phone.area = region
        phone.areaName = "Kartutsnittet"
        movedByCode = true
        withAnimation { position = .region(region) }
    }
}
