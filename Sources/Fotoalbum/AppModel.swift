import AppKit
import Foundation
import Observation
import Photos

/// Ett analogt bilde i mappa.
struct Photo: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
}

/// Appens tilstand: bildene i mappa, hvilket som er valgt, og infoen per bilde.
/// Alt lagres automatisk i ~/Library/Application Support/Fotoalbum/Prosjekt.json.
@MainActor @Observable
final class AppModel {
    enum Sorting: String, CaseIterable { case day = "Tid", roll = "Rull", filename = "Filnavn", similar = "Likhet" }
    enum Filter: String, CaseIterable {
        case all = "Alle"
        case missing = "Mangler dato eller sted"
        case missingDay = "Mangler dato"
        case missingPlace = "Mangler sted"
        case noCaption = "Uten beskrivelse"
        case uncertain = "Usikre"
        case unknown = "Vet ikke"

        func includes(_ i: PhotoInfo) -> Bool {
            switch self {
            case .all: true
            case .missing: i.needsDay || i.needsPlace
            case .missingDay: i.needsDay
            case .missingPlace: i.needsPlace
            case .unknown: i.placeIsUnknown || i.dayIsUnknown
            case .noCaption: i.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .uncertain: i.isUncertain
            }
        }
    }

    /// Et utvalg fra oversikten, f.eks. alle bilder fra «Grand Canyon» eller fra 14. juli.
    struct Subset: Equatable {
        let name: String
        let ids: Set<String>
    }

    private(set) var photos: [Photo] = []
    /// Alt som lagres. Endres via funksjonene her og i AppModel+Book.swift, som lagrer automatisk.
    var project = ProjectFile()
    /// Bildet som vises stort.
    var selection: String? {
        didSet {
            if let selection, !selected.contains(selection) { selected = [selection] }
            if selection != oldValue { compareAsset = nil }
        }
    }
    /// iPhone-bildet som vises ved siden av det analoge for å sammenligne (nil = ingen).
    var compareAsset: PHAsset?

    // Angre/gjør om for dato, sted og beskrivelse: tidligere utgaver av infoen per bilde.
    @ObservationIgnored private var undoStack: [[String: PhotoInfo]] = []
    @ObservationIgnored private var redoStack: [[String: PhotoInfo]] = []
    @ObservationIgnored private var lastUndoPush = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    /// Alle valgte bilder (⌘-klikk og ⇧-klikk velger flere). Dato og sted settes på alle.
    var selected: Set<String> = []
    var sorting: Sorting = .day
    /// Likhet: hvor like bildene i en gruppe må være (0 = løst, 1 = strengt).
    var groupStrictness = 0.6
    /// Når hvert bilde ble skannet (fra fila), for rullrekkefølgen.
    var scanTimes: [String: Date] = [:]
    /// Fokusmodus (ett bilde og ett spørsmål om gangen).
    let focus = FocusSession()
    /// Stedssøk mens du skriver (fokusmodus).
    let placeSearch = PlaceSearch()
    /// Søk etter områder (nasjonalparker o.l.) mens du skriver område.
    let areaSearch = PlaceSearch(areasOnly: true)
    /// Områdeforslag fra kartet per kartpunkt (avrundet), se AppModel+Areas.swift.
    var areaHints: [String: [FocusSession.Option]] = [:]
    /// Steder i nærheten per kartpunkt (alternative stedsnavn), se AppModel+Nearby.swift.
    var nearbyPOIs: [String: [FocusSession.Option]] = [:]
    /// Formen til hvert område (omriss eller sirkel), se AppModel+AreaShapes.swift.
    var areaShapes: [String: AreaShape] = [:]
    /// Region og land per kartpunkt (se AppModel+Region.swift). Endres i bakgrunnen; versjonen
    /// forteller visningene at de skal tegnes på nytt.
    @ObservationIgnored var regionCache: [String: Set<String>] = [:]
    /// Lånt posisjon for iPhone-bilder uten GPS (nærmeste bilde i tid, innen 3 timer).
    @ObservationIgnored var borrowedPoints: [String: GeoPoint] = [:]
    var regionCacheVersion = 0
    /// Bilder som venter på å få regionen sjekket hos Apple (nær grenser), og svar per kartpunkt.
    @ObservationIgnored var regionCheckQueue: [(id: String, point: GeoPoint)] = []
    @ObservationIgnored var regionCheckRunning = false
    @ObservationIgnored var geocodedRegions: [String: RegionPair] = [:]
    /// Landene på turen (se visitedCountries), husket per rutelengde.
    @ObservationIgnored var visitedCountryCache: (count: Int, countries: Set<String>)?
    /// iPhone-biblioteket (settes ved oppstart), til forslagene i fokusmodus.
    @ObservationIgnored var phone: PhoneLibrary?
    /// Bildeliketsindeksen (settes ved oppstart), til gruppene i rutenettet.
    @ObservationIgnored var similarity: SimilarityIndex?
    var filter: Filter = .all
    /// Vises bare et utvalg (fra oversikten)? nil = alle.
    var subset: Subset?

    enum Mode: String, CaseIterable { case photos = "Bilder", focus = "Fokus", book = "Bok" }
    var mode: Mode = .focus
    /// Valgt side i boka.
    var selectedPage: UUID?
    /// Viser omslaget i stedet for et oppslag.
    var showingCover = false
    /// Fremdrift mens stedslista får navn (nil = ikke i gang).
    var placesProgress: (done: Int, total: Int)?
    /// Fremdrift for eksport (kopier eller PDF). nil = ikke i gang.
    var progress: (title: String, done: Int, total: Int)?

    func url(of id: String) -> URL? { photos.first { $0.id == id }?.url }

    /// Teksten under et bilde i boka: «Grand Canyon · 14. juli 2022» og beskrivelsen.
    func caption(_ id: String) -> Caption {
        let i = info(id)
        let heading = [placeLabel(i), i.day?.norwegian].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Caption(heading: heading, body: i.caption.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stedet slik bokteksten skal vise det. (Område er tatt ut av appen; valget «Bildetekst» i Bok
    /// gjelder bare hvis det settes eksplisitt.)
    func placeLabel(_ i: PhotoInfo) -> String? {
        guard let choice = project.book?.placeText else { return (i.place?.name ?? "").nilIfEmpty }
        let area = (i.area ?? "").isEmpty ? nil : i.area
        let place = (i.place?.name ?? "").isEmpty ? nil : i.place?.name
        switch choice {
        case .both: return [area, place].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .area: return area ?? place
        case .place: return place ?? area
        }
    }

    /// Bildene slik de vises i rutenettet: sortert og filtrert.
    var visiblePhotos: [Photo] {
        var list = photos
        if let subset { list = list.filter { subset.ids.contains($0.id) } }
        if filter != .all { list = list.filter { filter.includes(info($0.id)) } }
        if sorting == .day {
            let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            list = chronology(of: list.map(\.id)).flatMap { $0.runs.flatMap(\.ids) }.compactMap { byID[$0] }
        } else if sorting == .roll {
            let rank = Dictionary(uniqueKeysWithValues: rollOrder.enumerated().map { ($1, $0) })
            list.sort { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        } else if sorting == .similar {
            let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            let groups = similarGroups(of: list.map(\.id))
            let grouped = Set(groups.flatMap { $0 })
            list = groups.flatMap { $0 }.compactMap { byID[$0] } + list.filter { !grouped.contains($0.id) }
        }
        return list
    }

    var selectedPhoto: Photo? { photos.first { $0.id == selection } }
    /// Bilder som er ferdige: har sted og dato, eller er merket «vet ikke».
    var completeCount: Int { photos.filter { let i = info($0.id); return !i.needsDay && !i.needsPlace }.count }

    // MARK: Lagring

    /// Mappa prosjektet lagres i. FOTOALBUM_BIBLIOTEK kan peke et annet sted ved testing.
    nonisolated static var libraryFolder: URL {
        if let custom = ProcessInfo.processInfo.environment["FOTOALBUM_BIBLIOTEK"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotoalbum")
    }
    /// Hvert prosjekt er en fil i Prosjekter-mappa: <id>.json.
    nonisolated static var projectsFolder: URL { libraryFolder.appendingPathComponent("Prosjekter") }
    nonisolated static func projectURL(_ id: UUID) -> URL { projectsFolder.appendingPathComponent("\(id.uuidString).json") }
    /// Husker hvilket prosjekt som var åpent sist.
    nonisolated static var currentPointer: URL { libraryFolder.appendingPathComponent("Gjeldende prosjekt.txt") }
    /// Fila fra før det fantes flere prosjekter. Leses én gang inn som første prosjekt og blir liggende urørt.
    nonisolated static var legacyProjectURL: URL { libraryFolder.appendingPathComponent("Prosjekt.json") }

    /// Prosjektet som er åpent.
    private(set) var projectID = UUID()
    var projectName: String { project.name ?? "Uten navn" }

    @ObservationIgnored var saveTask: Task<Void, Never>?

    init() {
        // Sist åpne prosjekt …
        if let text = try? String(contentsOf: Self.currentPointer, encoding: .utf8),
           let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let file = Self.readProject(Self.projectURL(id)) {
            load(file, id: id)
            return
        }
        // … ellers det gamle enkeltprosjektet, som blir første prosjekt …
        if var file = Self.readProject(Self.legacyProjectURL) {
            file.name = file.name ?? file.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Mitt fotoalbum"
            load(file, id: UUID())
            saveNow()
            return
        }
        // … ellers et nytt, tomt prosjekt.
        var empty = ProjectFile()
        empty.name = "Nytt prosjekt"
        load(empty, id: UUID())
    }

    /// Leser en prosjektfil. Kan den ikke leses, tas en kopi før noe kan skrives over.
    nonisolated static func readProject(_ url: URL) -> ProjectFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ProjectFile.self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
            let backup = libraryFolder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (kunne ikke leses) \(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            NSLog("Prosjektfila kunne ikke leses: \(error). Kopi: \(backup.path)")
            return nil
        }
    }

    /// Bytter til et prosjekt: nullstiller alt som hører til det forrige.
    func load(_ file: ProjectFile, id: UUID) {
        saveTask?.cancel()
        project = file
        projectID = id
        photos = []
        selection = nil
        selected = []
        subset = nil
        filter = .all
        mode = .focus
        selectedPage = nil
        showingCover = false
        compareAsset = nil
        scanTimes = [:]
        focus.queue = []
        focus.index = 0
        undoStack = []
        redoStack = []
        if let folder = file.folder { loadPhotos(from: URL(fileURLWithPath: folder)) }
        backfillRegions()
        for (id, info) in project.photos where info.regionManual != true {
            if let lat = info.place?.latitude, let lon = info.place?.longitude { enqueueRegionCheck(id, at: GeoPoint(lat: lat, lon: lon)) }
        }
        try? FileManager.default.createDirectory(at: Self.libraryFolder, withIntermediateDirectories: true)
        try? id.uuidString.write(to: Self.currentPointer, atomically: true, encoding: .utf8)
    }

    /// Lagrer et halvt sekund etter siste endring, så vi ikke skriver for hvert tastetrykk.
    /// Region og land for et kartpunkt.
    static func fillRegion(_ i: inout PhotoInfo, at p: GeoPoint) {
        let region = World.region(at: p)
        i.regionCode = region?.code
        i.countryCode = region?.country ?? World.country(at: p)?.code
    }

    /// «New Mexico, USA» for bildet (eller bare landet), hvis kjent.
    func regionLabel(_ i: PhotoInfo) -> String? {
        if let code = i.regionCode { return World.filterName(code) }
        if let country = i.countryCode { return World.countryName(country) }
        return nil
    }

    /// Bilder med kartpunkt som mangler region/land, får det (én gang, uten angring).
    func backfillRegions() {
        for (id, info) in project.photos where info.regionCode == nil && info.countryCode == nil {
            guard let lat = info.place?.latitude, let lon = info.place?.longitude else { continue }
            var i = info
            Self.fillRegion(&i, at: GeoPoint(lat: lat, lon: lon))
            project.photos[id] = i
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.projectsFolder, withIntermediateDirectories: true)
            try encoder.encode(project).write(to: Self.projectURL(projectID), options: .atomic)
        } catch {
            NSLog("Kunne ikke lagre prosjektet: \(error)")
        }
    }

    // MARK: Mappa

    /// Lar deg velge mappa med skanninger.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Velg"
        panel.message = "Velg mappa med de skannede bildene"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.folder = url.path
        loadPhotos(from: url)
        saveNow()
    }

    /// Leser bildefilene som ligger rett i mappa (ikke undermapper), sortert som i Finder.
    private func loadPhotos(from folder: URL) {
        let types: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png", "heic"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        photos = files
            .filter { types.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Photo.init)
        if selection == nil || selectedPhoto == nil { selection = photos.first?.id }
        loadScanTimes()
    }

    // MARK: Info per bilde

    func info(_ id: String) -> PhotoInfo { project.photos[id] ?? PhotoInfo() }

    func update(_ id: String, _ change: (inout PhotoInfo) -> Void) {
        // Endringer tett etter hverandre (skriving, flere bilder på én gang) angres samlet.
        if Date().timeIntervalSince(lastUndoPush) > 1.0 {
            undoStack.append(project.photos)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack = []
        }
        lastUndoPush = Date()
        var i = info(id)
        let oldPoint = i.place.flatMap { p in p.latitude.map { ($0, p.longitude ?? 0) } }
        change(&i)
        // Nytt kartpunkt: region og land fra kartet. Har du valgt regionen selv, står den til stedet byttes.
        var refine: GeoPoint?
        if let lat = i.place?.latitude, let lon = i.place?.longitude {
            let moved = oldPoint == nil || oldPoint! != (lat, lon)
            if moved || (i.regionCode == nil && i.countryCode == nil) {
                Self.fillRegion(&i, at: GeoPoint(lat: lat, lon: lon))
                i.regionManual = nil
                refine = GeoPoint(lat: lat, lon: lon)
            }
        }
        project.photos[id] = i.isEmpty ? nil : i
        // Nær en grense: sjekk delstaten hos Apple (grensene i appen er forenklet).
        if let refine { enqueueRegionCheck(id, at: refine) }
        if let day = i.day { project.lastDay = day }
        if let place = i.place, !place.name.isEmpty {
            project.lastPlaceName = place.name
            project.lastPlace = place
        }
        if let area = i.area, !area.isEmpty { project.lastArea = area }
        scheduleSave()
    }

    /// Grupper av like bilder blant `ids` (tom hvis bildene ikke er analysert ennå).
    func similarGroups(of ids: [String]) -> [[String]] {
        _ = similarity?.analogPrintCount  // oppdater når nye fingeravtrykk er klare
        return similarity?.groups(of: ids, strictness: groupStrictness) ?? []
    }

    // MARK: Angre

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project.photos)
        project.photos = previous
        lastUndoPush = .distantPast
        scheduleSave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project.photos)
        project.photos = next
        lastUndoPush = .distantPast
        scheduleSave()
    }

    // MARK: Oversikt

    /// Viser bare disse bildene i rutenettet, og velger det første.
    func show(_ name: String, ids: Set<String>) {
        subset = Subset(name: name, ids: ids)
        filter = .all
        if let first = visiblePhotos.first?.id { selected = [first]; selection = first }
    }

    /// Alle stedsnavn i bruk, med bildene som har dem.
    var placeNames: [(name: String, ids: Set<String>)] {
        var groups: [String: Set<String>] = [:]
        for (id, info) in project.photos where photos.contains(where: { $0.id == id }) {
            if let name = info.place?.name, !name.isEmpty { groups[name, default: []].insert(id) }
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, groups[$0]!) }
    }

    /// Gir alle bilder med stedsnavnet `old` det nye navnet. Koordinatene beholdes.
    /// Finnes navnet fra før, slås de to stedene sammen.
    func renamePlace(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        for (id, info) in project.photos where info.place?.name == old {
            update(id) { $0.place?.name = name }
        }
        if project.lastPlace?.name == old { project.lastPlace?.name = name; project.lastPlaceName = name }
        if let subset, subset.name == old { self.subset = Subset(name: name, ids: subset.ids) }
    }

    /// Valgte bilder i rutenett-rekkefølge.
    var selectedIDs: [String] { visiblePhotos.map(\.id).filter(selected.contains) }

    /// Setter dato og/eller sted på alle valgte bilder. Mangler en av dem, beholdes den gamle.
    /// Er bare ett bilde valgt, går vi videre til neste (hvis det er slått på).
    func apply(day: Day?, place: Place?, time: Date? = nil, timeZone: String? = nil, source: Source,
               phoneID: String? = nil, to ids: [String]? = nil) {
        let targets = ids ?? selectedIDs
        guard !targets.isEmpty else { return }
        // I fokusmodus styrer køen hva som kommer etterpå, så da går vi ikke videre her.
        let next = targets.count == 1 && advanceAfterCopy && mode != .focus ? photoAfter(targets[0]) : nil
        for id in targets {
            update(id) {
                if let day { $0.day = day }
                if let place { $0.place = place }
                $0.source = source
                $0.phoneID = phoneID
                $0.time = time
                $0.timeZone = timeZone
            }
        }
        project.lastTime = time
        project.lastTimeZone = timeZone
        if let next { selection = next; selected = [next] }
    }

    /// Samme dato og sted som du brukte sist.
    func applySameAsLast() {
        guard project.lastDay != nil || project.lastPlace != nil else { return }
        let area = project.lastArea
        let targets = selectedIDs
        apply(day: project.lastDay, place: project.lastPlace, time: project.lastTime,
              timeZone: project.lastTimeZone, source: .previous)
        if let area { for id in targets { update(id) { $0.area = area } } }
    }

    var advanceAfterCopy: Bool {
        get { project.advanceAfterCopy ?? true }
        set { project.advanceAfterCopy = newValue; scheduleSave() }
    }

    /// Perioden iPhone-bildene hentes fra. Standard er hele 2022 til du snevrer den inn.
    var tripStart: Day {
        get { project.tripStart ?? Day(year: 2022, month: 1, day: 1) }
        set { project.tripStart = newValue; scheduleSave() }
    }
    var tripEnd: Day {
        get { project.tripEnd ?? Day(year: 2022, month: 12, day: 31) }
        set { project.tripEnd = newValue; scheduleSave() }
    }

    /// Neste bilde i rutenettet etter dette. Med filteret «Mangler» forsvinner bildet fra lista
    /// når det får dato og sted, så vi finner neste før vi endrer noe.
    private func photoAfter(_ id: String) -> String? {
        let list = visiblePhotos.map(\.id)
        guard let index = list.firstIndex(of: id) else { return nil }
        return index + 1 < list.count ? list[index + 1] : nil
    }

    // MARK: Velge

    /// Klikk i rutenettet: vanlig klikk velger ett, ⌘ legger til/fjerner, ⇧ velger et område.
    func click(_ id: String, command: Bool, shift: Bool) {
        if command {
            if selected.contains(id), selected.count > 1 {
                selected.remove(id)
                if selection == id { selection = selectedIDs.first }
            } else {
                selected.insert(id)
                selection = id
            }
        } else if shift, let anchor = selection {
            let list = visiblePhotos.map(\.id)
            if let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: id) {
                selected.formUnion(list[min(a, b)...max(a, b)])
            }
        } else {
            selected = [id]
            selection = id
        }
    }

    /// Datoen et bilde uten dato foreslås å få: siste dato du brukte, ellers 1. juli 2022.
    var suggestedDay: Day { project.lastDay ?? Day(year: 2022, month: 7, day: 1) }

    // MARK: Bla

    func selectNext(_ step: Int) {
        let list = visiblePhotos
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selection } ?? -step
        let id = list[min(max(index + step, 0), list.count - 1)].id
        selected = [id]
        selection = id
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
