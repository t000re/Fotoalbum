import Foundation

/// Logikken i fokusmodus: hvilke bilder, hvilke forslag, og hva Enter/⇧Enter gjør.
extension AppModel {
    /// Hvor langt fra stedet iPhone-bilder regnes med, både for bildene til høyre og datoforslagene.
    /// Litt margin, siden stedsnavnet kan være en by eller park mens bildet er tatt et stykke unna.
    static let focusRadiusKm: Double = 100

    // MARK: Start og bla

    /// Alle bildene i rullrekkefølge. Starter på det valgte bildet hvis det mangler noe, ellers på det
    /// første som mangler sted eller dato.
    func startFocus() {
        let queue = rollOrder
        focus.queue = queue
        if let s = selection, let i = queue.firstIndex(of: s), !isFocusDone(s) {
            focus.index = i
        } else {
            focus.index = queue.firstIndex { !isFocusDone($0) } ?? 0
        }
        mode = .focus
        loadFirstMissingStep()
    }

    /// Bildet har sted og dato (eller «vet ikke»).
    func isFocusDone(_ id: String) -> Bool { let i = info(id); return !i.needsPlace && !i.needsDay }

    /// Hopp til et bilde (fra bildelinja).
    func focusJump(to index: Int) {
        guard focus.queue.indices.contains(index) else { return }
        focus.index = index
        loadFirstMissingStep()
    }

    /// Første steg bildet mangler, i rekkefølgen Region → Sted → Dato → Beskrivelse.
    /// Regionen spørres om når bildet mangler sted (har det sted, er regionen kjent fra kartet).
    /// `askRegion: false` etter at du nettopp har svart på regionen.
    func loadFirstMissingStep(askRegion: Bool = true) {
        guard let id = focus.current else { return }
        let i = info(id)
        if askRegion, i.needsPlace || i.needsDay, i.place?.latitude == nil { loadFocusStep(.region); return }
        loadFocusStep(i.needsPlace ? .place : i.needsDay ? .day : .caption)
    }

    func endFocus() {
        mode = .photos
    }

    /// Går til et steg for gjeldende bilde, med feltet fylt med det bildet har fra før.
    func loadFocusStep(_ step: FocusSession.Step) {
        focus.step = step
        focus.message = nil
        focus.edited = false
        focus.highlighted = nil
        guard let id = focus.current else { return }
        if selection != id { selection = id; selected = [id] }
        let i = info(id)
        if focus.loadedPhoto != id {
            // Nytt bilde: regionen står (fra forrige bilde) med mindre bildet har sin egen;
            // høyre side viser alle dager (datovelgeren er et filter du velger selv).
            focus.loadedPhoto = id
            if let own = photoFilter(i) { focus.browseRegion = own }
            focus.browseDay = nil
        }
        switch step {
        case .region: focus.text = ""
        case .place: focus.text = i.place?.name ?? ""
        case .area: focus.text = i.area ?? ""
        case .day: focus.text = i.day?.norwegian ?? ""
        case .caption: focus.text = i.caption
        }
        focus.loadedText = focus.text
        placeSearch.query = ""
        areaSearch.query = ""
        placeSearch.prefer(focusFilterShape?.region)
        // Region: forrige bildes region (eller den fra bildene rundt) markeres, så Enter godtar den.
        if step == .region, !focusOptions.isEmpty { focus.highlighted = 0 }
        if step == .area { Task { await refreshAreaSuggestions(for: id) } }
        if step == .place || step == .area, let lat = i.place?.latitude, let lon = i.place?.longitude {
            Task { await loadNearbyPlaces(GeoPoint(lat: lat, lon: lon)) }
        }
    }

    /// Henter områdeforslag (også fra de like iPhone-bildene når de er klare) og markerer det beste
    /// hvis ingenting er markert ennå.
    func refreshAreaSuggestions(for id: String) async {
        await loadAreaHints(for: id)
        guard focus.current == id, focus.step == .area, !focus.edited, focus.highlighted == nil,
              let first = focusOptions.first else { return }
        if first.detail.contains("rullen") || first.detail.contains("nærheten") || first.detail.contains("fra kartet") {
            focus.highlighted = 0
        }
    }

    /// Neste bilde som mangler sted eller dato (etter dette). Ingen igjen: «Ferdig».
    func focusNextPhoto() {
        let next = focus.queue.indices.first { $0 > focus.index && !isFocusDone(focus.queue[$0]) }
        focus.index = next ?? focus.queue.count
        loadFirstMissingStep()
    }

    func focusPreviousPhoto() {
        guard focus.index > 0 else { return }
        focus.index -= 1
        loadFocusStep(.caption)
    }

    // MARK: Forslag

    /// Forslagene under feltet for steget du står på.
    var focusOptions: [FocusSession.Option] {
        guard let id = focus.current else { return [] }
        switch focus.step {
        case .region: return regionOptions(for: id, typed: focus.edited ? focus.text.trimmingCharacters(in: .whitespaces) : "")
        case .place: return placeOptions(for: id)
        case .area: return areaOptions(for: id, typed: focus.edited ? focus.text.trimmingCharacters(in: .whitespaces) : "")
        case .day: return dayOptions(for: id)
        case .caption: return []
        }
    }

    private func placeOptions(for id: String) -> [FocusSession.Option] {
        let typed = focus.edited ? focus.text.trimmingCharacters(in: .whitespaces) : ""
        var first: [(Place?, String)] = []
        // Har bildet kartpunkt: stedet det har nå, og andre navn i nærheten (behold kartpunktet).
        if typed.isEmpty, let place = info(id).place, let lat = place.latitude, let lon = place.longitude {
            first.append((place, "nå"))
            for option in nearbyPlaces(GeoPoint(lat: lat, lon: lon)) { first.append((option.place, option.detail)) }
        }
        if typed.isEmpty {
            // Tomt felt: bildene rundt på rullen og sist brukt først.
            let n = rollNeighbors(of: id)
            if let b = n.before { first.append((info(b.id).place, b.steps == 1 ? "bildet før på rullen" : "\(b.steps) bilder før på rullen")) }
            if let a = n.after { first.append((info(a.id).place, a.steps == 1 ? "bildet etter på rullen" : "\(a.steps) bilder etter på rullen")) }
            first.append((project.lastPlace, "sist brukt"))
        }
        return rankedPlaceOptions(typed: typed, first: first, insideFilter: focusPreviewRegion)
    }

    /// Stedsforslag i prioritert rekkefølge: `first` (f.eks. bildene rundt på rullen), så steder du har
    /// brukt i prosjektet (mest brukt først), så steder på turen fra iPhone, så søketreff fra Apple for
    /// det du har skrevet. Brukes både i fokusmodus og i stedsfeltet i Bilder-visningen.
    /// `inside`: bare brukte steder og steder på turen innenfor området (søketreff vises uansett).
    func rankedPlaceOptions(typed: String, first: [(Place?, String)] = [], insideFilter filter: String? = nil) -> [FocusSession.Option] {
        var options: [FocusSession.Option] = []
        func isInside(_ place: Place?) -> Bool {
            guard let filter else { return true }
            guard let lat = place?.latitude, let lon = place?.longitude else { return false }
            return filterMatches(GeoPoint(lat: lat, lon: lon), filter)
        }
        func add(_ place: Place?, _ detail: String) {
            guard let place, !place.name.isEmpty, isInside(place),
                  !options.contains(where: { $0.title.caseInsensitiveCompare(place.name) == .orderedSame }) else { return }
            options.append(.init(title: place.name, detail: detail, place: place))
        }
        func matches(_ name: String) -> Bool {
            typed.isEmpty || name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func startsWith(_ name: String) -> Bool { name.lowercased().hasPrefix(typed.lowercased()) }

        for (place, detail) in first { add(place, detail) }
        // Steder du allerede har brukt, med kartpunkt fra et bilde som har det.
        let used = placeNames.filter { matches($0.name) }
            .sorted { a, b in
                if startsWith(a.name) != startsWith(b.name) { return startsWith(a.name) }
                return a.ids.count > b.ids.count
            }
        for entry in used {
            let withPoint = entry.ids.compactMap { info($0).place }.first { $0.latitude != nil }
            add(withPoint ?? Place(name: entry.name), entry.ids.count == 1 ? "brukt på 1 bilde" : "brukt på \(entry.ids.count) bilder")
        }
        // Stedene på turen fra iPhone-bildene.
        for trip in tripPlaces.filter({ matches($0.name) }).sorted(by: { startsWith($0.name) && !startsWith($1.name) }) {
            add(trip.place, "iPhone · \(trip.dayRange)")
        }
        // Søketreff fra Apple.
        if !typed.isEmpty {
            for result in placeSearch.results
            where !options.contains(where: { $0.title.caseInsensitiveCompare(result.title) == .orderedSame }) {
                options.append(.init(title: result.title, detail: result.subtitle, searchSubtitle: result.subtitle))
            }
        }
        return options
    }

    private func dayOptions(for id: String) -> [FocusSession.Option] {
        let i = info(id)
        var days: [(Day, String)] = []
        func add(_ day: Day?, _ detail: String) {
            guard let day, !days.contains(where: { $0.0 == day }) else { return }
            days.append((day, detail))
        }
        // Dagene du var i nærheten av stedet (iPhone-bilder innen radiusen).
        if let lat = i.place?.latitude, let lon = i.place?.longitude, let phone {
            let here = GeoPoint(lat: lat, lon: lon)
            var counts: [Day: Int] = [:]
            for p in phone.located where distanceKm(p.point, here) < Self.focusRadiusKm { counts[p.day, default: 0] += 1 }
            for day in counts.keys.sorted() {
                add(day, "\(counts[day]!) iPhone-bilder innen \(Int(Self.focusRadiusKm)) km")
            }
        }
        // Uten sted, men med område: dagene med iPhone-bilder i området.
        if i.place?.latitude == nil, let filter = focusPreviewRegion, let phone {
            var counts: [Day: Int] = [:]
            for p in phone.located where filterMatches(p.point, filter) { counts[p.day, default: 0] += 1 }
            for day in counts.keys.sorted() { add(day, "\(counts[day]!) iPhone-bilder i regionen") }
        }
        let n = rollNeighbors(of: id)
        if let b = n.before { add(info(b.id).day, "bildet før på rullen") }
        if let a = n.after { add(info(a.id).day, "bildet etter på rullen") }
        add(project.lastDay, "sist brukt")
        let typedText = focus.edited ? focus.text.trimmingCharacters(in: .whitespaces) : ""
        if !typedText.isEmpty, let phone {
            // Når du skriver: alle dagene på turen med iPhone-bilder kan foreslås.
            var counts: [Day: Int] = [:]
            for p in phone.located { counts[p.day, default: 0] += 1 }
            for day in counts.keys.sorted() { add(day, "\(counts[day]!) iPhone-bilder") }
        }
        var options = days.map { FocusSession.Option(title: $0.0.norwegian, detail: $0.1, day: $0.0) }
        if !typedText.isEmpty {
            // Bare dager som passer det du skriver («20», «juli», «20. jul»).
            let words = typedText.lowercased().split(whereSeparator: { " .".contains($0) })
            options = options.filter { option in
                let title = option.title.lowercased()
                return words.allSatisfy { word in
                    title.split(whereSeparator: { " .".contains($0) }).contains { $0.hasPrefix(word) }
                }
            }
        }
        // Skriver du en hel dato, vises den først.
        if focus.edited, let typed = DayParser.parse(focus.text, defaultYear: tripStart.year) {
            options.removeAll { $0.day == typed }
            options.insert(.init(title: typed.norwegian, detail: "skrevet inn", day: typed), at: 0)
        }
        return options
    }

    /// Stedet kartet og iPhone-bildene skal vise: markert forslag, ellers bildets sted.
    var focusCandidate: Place? {
        let options = focusOptions
        if focus.step == .place, let h = focus.highlighted, options.indices.contains(h) { return options[h].place }
        return focus.current.flatMap { info($0).place }
    }

    func focusMoveHighlight(_ step: Int) {
        let count = focusOptions.count
        guard count > 0 else { return }
        let next = (focus.highlighted ?? -1) + step
        focus.highlighted = next < 0 ? nil : min(next, count - 1)
    }

    /// Når du skriver: marker første forslag hvis det begynner med det du har skrevet.
    func focusTextChanged() {
        focus.edited = true
        focus.message = nil
        if focus.step == .place { placeSearch.query = focus.text }
        if focus.step == .area { areaSearch.query = focus.text }
        focusRefreshHighlight()
    }

    /// Markerer første forslag hvis det begynner med det du har skrevet (også når søketreff kommer
    /// litt etter at du har skrevet). Rører ikke en markering du har flyttet med piltastene.
    func focusRefreshHighlight(onlyIfNone: Bool = false) {
        if onlyIfNone, focus.highlighted != nil { return }
        let typed = focus.text.trimmingCharacters(in: .whitespaces).lowercased()
        let options = focusOptions
        if focus.step == .day {
            // Bare når det du skriver er en gyldig dato (den står da først i lista).
            focus.highlighted = typed.isEmpty || options.isEmpty ? nil : 0
        } else {
            focus.highlighted = !typed.isEmpty && (options.first?.title.lowercased().hasPrefix(typed) ?? false) ? 0 : nil
        }
    }

    // MARK: Enter og ⇧Enter

    func focusConfirm() {
        guard let id = focus.current else { return }
        let options = focusOptions
        var chosen = focus.highlighted.flatMap { options.indices.contains($0) ? options[$0] : nil }
        switch focus.step {
        case .region:
            let typed = focus.text.trimmingCharacters(in: .whitespaces)
            let code = chosen?.code ?? options.first { $0.title.lowercased().hasPrefix(typed.lowercased()) && !typed.isEmpty }?.code
            if code == nil, !typed.isEmpty {
                focus.message = "Fant ingen region som heter «\(typed)». Velg i lista, eller ⌘K for uten."
                return
            }
            focus.browseRegion = code
            // Regionen du velger, lagres på bildet og vinner over den fra kartpunktet.
            if let code { setRegion(code, for: id) }
            loadFirstMissingStep(askRegion: false)
        case .place:
            let typed = focus.text.trimmingCharacters(in: .whitespaces)
            // Ingenting markert, men et forslag heter akkurat det du har skrevet: bruk det (med kartpunkt).
            if chosen == nil, focus.edited, !typed.isEmpty {
                chosen = options.first { $0.title.caseInsensitiveCompare(typed) == .orderedSame }
            }
            if let result = chosen, result.searchSubtitle != nil {
                // Søketreff: hent kartpunktet først, så datoforslagene blir riktige.
                focus.message = "Henter kartpunkt for \(result.title) …"
                Task {
                    let place = await placeSearch.resolve(title: result.title, subtitle: result.searchSubtitle ?? "")
                    guard focus.current == id, focus.step == .place else { return }
                    apply(day: nil, place: place ?? Place(name: result.title), source: .manual, to: [id])
                        loadFocusStep(.day)
                }
                return
            }
            if let place = chosen?.place {
                apply(day: nil, place: place, source: .manual, to: [id])
            } else if !typed.isEmpty, typed != info(id).place?.name {
                // Skrevet inn: kjent sted får kartpunktet sitt, ellers slås det opp.
                let known = placeSuggestions(for: typed).first { $0.name == typed && $0.latitude != nil }
                apply(day: nil, place: known ?? Place(name: typed), source: .manual, to: [id])
                if known == nil {
                    Task {
                        guard let point = await Self.lookUpCoordinates(typed) else { return }
                        if info(id).place?.name == typed {
                            update(id) { $0.place?.latitude = point.lat; $0.place?.longitude = point.lon }
                        }
                    }
                }
            } else if info(id).place == nil {
                focus.message = "Skriv eller velg et sted. ⌘↓ hopper over bildet."
                return
            }
            loadFocusStep(.day)
        case .area:
            let typed = focus.text.trimmingCharacters(in: .whitespaces)
            let name = chosen?.title ?? typed
            if name != (info(id).area ?? "") {
                update(id) { $0.area = name.isEmpty ? nil : name }
            }
            // Område er en frivillig merkelapp: tilbake til det bildet mangler.
            loadFirstMissingStep(askRegion: false)
        case .day:
            let typed = DayParser.parse(focus.text, defaultYear: tripStart.year)
            if let day = chosen?.day ?? typed {
                if info(id).day != day {
                    update(id) { $0.day = day; $0.time = nil; $0.source = .manual }
                }
            } else if info(id).day == nil || !focus.text.isEmpty && focus.text != info(id).day?.norwegian {
                focus.message = "Skriv en dato som 14.7 eller 14. juli, eller velg i lista."
                return
            }
            loadFocusStep(.caption)
        case .caption:
            let text = focus.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != info(id).caption { update(id) { $0.caption = text } }
            focusNextPhoto()
        }
    }

    /// «Jeg vet ikke»: merker stedet eller datoen som ukjent og går videre. Bildet kommer ikke tilbake
    /// i køen neste gang, men finnes under filteret «Vet ikke».
    func focusDontKnow() {
        guard let id = focus.current else { return }
        switch focus.step {
        case .region:
            // Ingen filter.
            focus.browseRegion = nil
            loadFirstMissingStep(askRegion: false)
        case .area:
            // Ikke noe område.
            if info(id).area != nil { update(id) { $0.area = nil } }
            loadFirstMissingStep(askRegion: false)
        case .place:
            update(id) { $0.place = nil; $0.unknownPlace = true }
            loadFocusStep(.day)
        case .day:
            update(id) { $0.day = nil; $0.time = nil; $0.unknownDay = true }
            loadFocusStep(.caption)
        case .caption:
            focusNextPhoto()
        }
    }

    func focusBack() {
        switch focus.step {
        case .region: focusPreviousPhoto()
        case .area: loadFirstMissingStep(askRegion: false)
        case .place: info(focus.current ?? "").place?.latitude == nil ? loadFocusStep(.region) : focusPreviousPhoto()
        case .day: loadFocusStep(.place)
        case .caption: loadFocusStep(.day)
        }
    }

    /// Etter kopiering fra et iPhone-bilde (like bilder, iPhone-bildene, ⌘D): sted og dato er satt.
    /// Mangler området, går vi dit (forslagene kommer da fra stedet); ellers til beskrivelsen.
    func focusDidFill() {
        guard mode == .focus, let id = focus.current else { return }
        if let own = photoFilter(info(id)) { focus.browseRegion = own }
        loadFocusStep(.caption)
    }

    /// Området sidene skal vise: i Område-steget det markerte forslaget (eller det du skriver),
    /// ellers bildets eget område, ellers det du har valgt til høyre.
    var focusPreviewArea: String? {
        if focus.step == .area {
            let options = focusOptions
            if let h = focus.highlighted, options.indices.contains(h) { return options[h].title }
            let typed = focus.text.trimmingCharacters(in: .whitespaces)
            if focus.edited, !typed.isEmpty { return typed }
        }
        return focus.current.flatMap { info($0).area }
    }

    /// Dagen sidene skal vise: i Dato-steget den markerte (eller skrevne) datoen, ellers den valgte til høyre.
    var focusPreviewDay: Day? {
        if focus.step == .day {
            let options = focusOptions
            if let h = focus.highlighted, options.indices.contains(h), let day = options[h].day { return day }
            if focus.edited, let typed = DayParser.parse(focus.text, defaultYear: tripStart.year) { return typed }
        }
        return focus.browseDay
    }

    /// Området til merkelappen som form (for kartet mens du redigerer område).
    var focusAreaShape: AreaShape? { areaShape(focusPreviewArea) }
}
