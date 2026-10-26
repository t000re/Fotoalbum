import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Observation
import Photos
import Vision

/// Bildelikhet: et «fingeravtrykk» av hvert bilde (Apples Vision, kjører lokalt på Macen – ingenting
/// sendes ut), så appen kan foreslå iPhone-bildene som ligner mest på et analogt bilde.
/// Fingeravtrykkene lagres i Fotoalbum/Likhet, så de bare lages én gang.
@MainActor @Observable
final class SimilarityIndex {
    /// Fremdrift mens fingeravtrykk lages (nil = ferdig).
    private(set) var progress: (done: Int, total: Int)?
    /// Forslagene for det valgte analoge bildet: iPhone-bilder, mest like først.
    private(set) var suggestions: [(asset: PHAsset, distance: Float)] = []
    private(set) var suggestionsFor: String?

    private var analogPrints: [String: VNFeaturePrintObservation] = [:]
    @ObservationIgnored var groupCache: [GroupKey: [[String]]] = [:]
    /// Tekst funnet i de analoge bildene (skilt o.l.), per bilde.
    private(set) var texts: [String: [String]] = [:]
    /// Antall analoge bilder med fingeravtrykk (endres når nye blir ferdige).
    private(set) var analogPrintCount = 0
    func analogPrint(_ id: String) -> VNFeaturePrintObservation? { analogPrints[id] }
    private var phonePrints: [String: VNFeaturePrintObservation] = [:]
    private var indexing: Task<Void, Never>?

    nonisolated private static var folder: URL { AppModel.libraryFolder.appendingPathComponent("Likhet") }

    // MARK: Lage fingeravtrykk

    /// Lager fingeravtrykk for alle analoge bilder og iPhone-bildene i perioden (de som mangler).
    func index(photos: [Photo], phone: PhoneLibrary) {
        indexing?.cancel()
        let assets = phone.days.flatMap(\.assets)
        let manager = phone.imageManager
        indexing = Task {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let analogTodo = photos.filter { analogPrints[$0.id] == nil }
            let phoneTodo = assets.filter { phonePrints[$0.localIdentifier] == nil }
            let total = analogTodo.count + phoneTodo.count
            guard total > 0 else { progress = nil; return }
            var done = 0
            progress = (0, total)
            for photo in analogTodo {
                if Task.isCancelled { return }
                let key = Self.analogKey(photo.url)
                if let print = await Task.detached(priority: .utility, operation: {
                    Self.load(key) ?? Self.analogPrint(photo.url).map { Self.save($0, key); return $0 }
                }).value {
                    analogPrints[photo.id] = print
                    analogPrintCount = analogPrints.count
                }
                texts[photo.id] = await Task.detached(priority: .utility) { Self.text(in: photo.url, key: key) }.value
                done += 1; progress = (done, total)
            }
            for asset in phoneTodo {
                if Task.isCancelled { return }
                let key = Self.phoneKey(asset.localIdentifier)
                var print = await Task.detached(priority: .utility) { Self.load(key) }.value
                if print == nil, let image = await Self.thumbnail(asset, manager: manager) {
                    print = await Task.detached(priority: .utility) {
                        Self.featurePrint(image).map { Self.save($0, key); return $0 }
                    }.value
                }
                if let print { phonePrints[asset.localIdentifier] = print }
                done += 1; progress = (done, total)
            }
            progress = nil
        }
    }

    // MARK: Forslag

    /// Finner de iPhone-bildene som ligner mest på det analoge bildet.
    /// `allowed`: bare iPhone-bilder med disse ID-ene (f.eks. innenfor området); nil = alle.
    func suggest(for id: String?, phone: PhoneLibrary, count: Int = 5, allowed: Set<String>? = nil) {
        suggestionsFor = id
        guard let id, let print = analogPrints[id] else { suggestions = []; return }
        var scored: [(String, Float)] = []
        for (assetID, other) in phonePrints where allowed?.contains(assetID) ?? true {
            var distance: Float = 0
            if (try? print.computeDistance(&distance, to: other)) != nil { scored.append((assetID, distance)) }
        }
        let best = scored.sorted { $0.1 < $1.1 }.prefix(count)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: best.map(\.0), options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        suggestions = best.compactMap { entry in byID[entry.0].map { ($0, entry.1) } }
    }

    var hasPrint: (String) -> Bool { { [analogPrints] in analogPrints[$0] != nil } }

    // MARK: Vision

    /// Versjon av fingeravtrykkene; endres når metoden endres, så gamle lages på nytt.
    nonisolated private static let version = "g1"
    nonisolated(unsafe) private static let ciContext = CIContext()

    /// Fingeravtrykk av bildet i gråtoner med utjevnet lyshet, så fargestikk fra film betyr mindre.
    /// (Testet med «filmversjoner» av testbilder: riktig bilde først 26 av 40 ganger, mot 8 i farger.)
    nonisolated private static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: normalized(image) ?? image, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    nonisolated private static func normalized(_ image: CGImage) -> CGImage? {
        var x = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        let average = x.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: x.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        let gain = 0.5 / max(Double(pixel[0]) / 255, 0.05)
        x = x.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
        ])
        return ciContext.createCGImage(x, from: x.extent)
    }

    nonisolated private static func analogPrint(_ url: URL) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return featurePrint(image)
    }

    /// iPhone-bildet i 512 px (hentes fra iCloud om nødvendig).
    private static func thumbnail(_ asset: PHAsset, manager: PHCachingImageManager) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            options.isSynchronous = false
            manager.requestImage(for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit,
                                 options: options) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    // MARK: Tekst i bildet

    /// Tekst i bildet (Apples tekstgjenkjenning, lokalt). Bare tydelige ord på minst tre tegn.
    /// Lagres ved siden av fingeravtrykket.
    nonisolated private static func text(in url: URL, key: String) -> [String] {
        let file = folder.appendingPathComponent("t" + key + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([String].self, from: data) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2400,
              ] as CFDictionary) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }
            .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.filter(\.isLetter).count >= 3 && seen.insert($0.lowercased()).inserted }
        if let data = try? JSONEncoder().encode(lines) { try? data.write(to: file) }
        return lines
    }

    // MARK: Mellomlager

    /// Nøkkel for et analogt bilde: filnavn, størrelse og endringsdato (nytt avtrykk hvis fila endres).
    nonisolated private static func analogKey(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "a-" + hash("\(version)|\(url.lastPathComponent)|\(size)|\(date)")
    }

    nonisolated private static func phoneKey(_ id: String) -> String { "p-" + hash("\(version)|\(id)") }

    nonisolated private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func load(_ key: String) -> VNFeaturePrintObservation? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(key)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    nonisolated private static func save(_ print: VNFeaturePrintObservation, _ key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) else { return }
        try? data.write(to: folder.appendingPathComponent(key))
    }
}

// MARK: Grupper av like analoge bilder

extension SimilarityIndex {
    /// Grupperer analoge bilder som ligner hverandre (gjennomsnittlig avstand, «average linkage»).
    /// `strictness` 0…1: hvor like bildene må være. Grensen settes ut fra avstandene mellom dine egne
    /// bilder (en andel av alle par), så den ikke avhenger av Visions tallskala.
    /// Returnerer grupper med minst to bilder, største først; bilder uten like er ikke med.
    func groups(of ids: [String], strictness: Double) -> [[String]] {
        let key = GroupKey(ids: ids, strictness: strictness, prints: analogPrintCount)
        if let cached = groupCache[key] { return cached }
        let items = ids.compactMap { id in analogPrint(id).map { (id, $0) } }
        let n = items.count
        guard n > 1 else { return [] }
        // Alle avstander.
        var d = [Float](repeating: 0, count: n * n)
        var all: [Float] = []
        all.reserveCapacity(n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var v: Float = 0
                _ = try? items[i].1.computeDistance(&v, to: items[j].1)
                d[i * n + j] = v; d[j * n + i] = v
                all.append(v)
            }
        }
        all.sort()
        // Streng = bare de aller likeste parene (1 %), løs = opptil 25 % av parene.
        let fraction = 0.25 - 0.24 * min(max(strictness, 0), 1)
        let threshold = all[min(all.count - 1, Int(Double(all.count) * fraction))]

        // Slå sammen de to nærmeste gruppene til avstanden blir for stor.
        var members: [[Int]] = (0..<n).map { [$0] }
        var alive = [Bool](repeating: true, count: n)
        while true {
            var best: (Int, Int, Float)?
            for a in 0..<n where alive[a] {
                for b in (a + 1)..<n where alive[b] {
                    let v = d[a * n + b]
                    if v < (best?.2 ?? threshold) { best = (a, b, v) }
                }
            }
            guard let (a, b, _) = best else { break }
            let sa = Float(members[a].count), sb = Float(members[b].count)
            for k in 0..<n where alive[k] && k != a && k != b {
                let v = (sa * d[a * n + k] + sb * d[b * n + k]) / (sa + sb)
                d[a * n + k] = v; d[k * n + a] = v
            }
            members[a] += members[b]
            alive[b] = false
        }
        let result = (0..<n).filter { alive[$0] && members[$0].count > 1 }
            .map { members[$0].sorted().map { items[$0].0 } }
            .sorted { $0.count > $1.count }
        groupCache[key] = result
        return result
    }
}

struct GroupKey: Hashable {
    let ids: [String]
    let strictness: Double
    let prints: Int
}
