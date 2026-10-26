import Photos
import SwiftUI

/// «Ligner mest»: de fem iPhone-bildene som ligner mest på det valgte analoge bildet.
/// Klikk, eller ⌃1–⌃5, kopierer dato og sted fra forslaget.
struct SuggestionStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    @Environment(SimilarityIndex.self) private var similarity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ligner mest").font(.headline)
                Spacer()
                if let p = similarity.progress {
                    Text("Analyserer bilder \(p.done) av \(p.total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 60)
                }
            }
            if similarity.suggestions.isEmpty {
                Text(similarity.progress == nil ? "Ingen forslag for dette bildet." : "Forslagene kommer når bildene er analysert.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 30, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(similarity.suggestions.enumerated()), id: \.element.asset.localIdentifier) { index, s in
                        SuggestionCell(asset: s.asset, number: index + 1, distance: s.distance)
                    }
                }
            }
        }
        .padding(8)
        .task(id: Key(selection: model.selection, indexing: similarity.progress == nil, count: phone.count,
                      shape: model.selection.flatMap { model.areaShape(for: $0) })) {
            if let id = model.selection { await model.resolveAreaShape(model.info(id).area) }
            similarity.suggest(for: model.selection, phone: phone, allowed: model.allowedPhoneIDs(for: model.selection))
        }
    }

    private struct Key: Hashable { let selection: String?; let indexing: Bool; let count: Int; let shape: AreaShape? }
}

private struct SuggestionCell: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneLibrary.self) private var phone
    let asset: PHAsset
    let number: Int
    let distance: Float
    @State private var copying = false

    var body: some View {
        let matched = model.selection.map { model.info($0).phoneID == asset.localIdentifier } ?? false
        VStack(spacing: 2) {
            PhoneThumbnail(asset: asset, manager: phone.imageManager)
                .frame(minWidth: 50, maxWidth: 90)
                .overlay(alignment: .topLeading) {
                    Text("\(number)").font(.caption2.bold()).padding(3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(2)
                }
                .overlay { if copying { ProgressView().controlSize(.small) } }
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: matched ? 3 : 0))
            Text(asset.creationDate.map { Day($0, timeZone: asset.location.map { PhoneLibrary.approximateZone($0.coordinate) } ?? .current).norwegian } ?? "")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // Avstanden fra Vision: lavere = mer likt. Ikke en prosent.
            Text(String(format: "%.2f", distance)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { use() }
        .contextMenu {
            Button("Bruk (⌃\(number))") { use() }
            Button("Sammenlign (⌥⌃\(number))") { model.compareAsset = asset }
        }
        .help("Kopier dato og sted fra dette bildet (⌃\(number)). Høyreklikk for å sammenligne. Tallet er avstanden: lavere = mer likt.")
    }

    private func use() {
        copying = true
        Task {
            await model.copy(from: asset, phone: phone, to: model.selectedIDs)
            copying = false
        }
    }
}
