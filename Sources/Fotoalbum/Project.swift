import Foundation

/// En kalenderdag uten klokkeslett. Lagres som «2022-07-14», så tidssoner aldri flytter datoen.
struct Day: Codable, Hashable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// Dagen et tidspunkt faller på i en tidssone (standard: Mac-ens).
    /// Et iPhone-bilde tatt kl. 20 i California er neste dag i norsk tid, så tidssonen er viktig.
    init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Kl. 12 denne dagen, for datovelgeren.
    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// Norsk format, f.eks. «7. okt. 2022».
    var norwegian: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nb_NO")
        f.dateFormat = "d. MMM y"
        return f.string(from: date)
    }

    static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ugyldig dato: \(text)"))
        }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }
}

/// Et sted: navnet som står i boka, og koordinater hvis vi har dem (fra et iPhone-bilde).
struct Place: Codable, Hashable {
    var name: String
    var latitude: Double?
    var longitude: Double?
}

/// Hvor dato og sted kom fra. Nyttig for å se hva som er sikkert og hva som er gjettet.
enum Source: String, Codable {
    case manual      // skrevet inn
    case iPhone      // kopiert fra et iPhone-bilde
    case previous    // samme som forrige bilde
    case roll        // fylt inn fra bildene rundt på rullen
}

/// Det appen vet om ett analogt bilde. Selve bildefila endres aldri.
struct PhotoInfo: Codable, Hashable {
    var day: Day? { didSet { if day != nil { unknownDay = nil } } }
    var place: Place? { didSet { if place != nil { unknownPlace = nil } } }
    var caption: String = ""
    /// Overordnet område, f.eks. «Blue Ridge Mountains» (stedet kan da være «Sylva»). Valgfritt.
    var area: String?
    /// Region (stat, fylke, provins: ISO 3166-2, f.eks. «US-NM») og land (ISO 3166-1, «US»).
    /// Fylles inn fra stedets kartpunkt; ellers fra det du velger i Region-steget.
    var regionCode: String?
    var countryCode: String?
    var source: Source?
    /// iPhone-bildet dato og sted ble kopiert fra (Bilder-appens ID), så det kan markeres.
    var phoneID: String?
    /// Tidspunktet til iPhone-bildet (omtrent når det analoge bildet ble tatt). Brukes bare til
    /// rekkefølgen innen en dag og til hvor langt ruten på kartet har kommet.
    var time: Date?
    /// Tidssonen der bildet ble tatt (f.eks. «America/Los_Angeles»), fra stedsoppslaget.
    var timeZone: String?
    /// Merket som usikker (dato eller sted kan være feil), med et valgfritt notat.
    var uncertain: Bool?
    var note: String?

    /// «Jeg vet ikke»: du har sett på bildet og vet ikke stedet/datoen. Settes tilbake når du gir en verdi.
    var unknownPlace: Bool?
    var unknownDay: Bool?

    var isUncertain: Bool { uncertain ?? false }
    var placeIsUnknown: Bool { unknownPlace ?? false }
    var dayIsUnknown: Bool { unknownDay ?? false }
    /// Mangler sted/dato og er ikke merket «vet ikke».
    var needsPlace: Bool { place == nil && !placeIsUnknown }
    var needsDay: Bool { day == nil && !dayIsUnknown }
    var isEmpty: Bool { day == nil && place == nil && caption.isEmpty && !isUncertain && (note ?? "").isEmpty
        && !placeIsUnknown && !dayIsUnknown
        && (area ?? "").isEmpty && regionCode == nil && countryCode == nil }
}

/// Prosjektfila: hvilken mappe skanningene ligger i, og info per bilde (nøkkel = filnavnet).
/// Bytter du filnavn (f.eks. ny eksport fra Lightroom), mister bildene koblingen til infoen sin.
struct ProjectFile: Codable {
    /// Prosjektets navn (vises i tittellinja og prosjektlista).
    var name: String?
    var folder: String?
    var photos: [String: PhotoInfo] = [:]
    var lastPlaceName: String?
    var lastDay: Day?
    /// Sist brukte sted og tidspunkt, for «Samme som sist».
    var lastPlace: Place?
    var lastArea: String?
    var lastTime: Date?
    var lastTimeZone: String?
    /// Ruten fra iPhone-bildenes GPS, i tidsrekkefølge. Brukes av kartet i boka.
    var route: [RoutePoint]?
    /// Stedene på turen, funnet fra iPhone-bildenes GPS (stedslista).
    var tripPlaces: [TripPlace]?
    /// Perioden iPhone-bildene hentes fra.
    var tripStart: Day?
    var tripEnd: Day?
    /// Gå videre til neste bilde etter kopiering.
    var advanceAfterCopy: Bool?
    /// Fotoboka. Lages første gang du åpner Bok.
    var book: Book?
}

/// Ett punkt på ruten: hvor og når et iPhone-bilde ble tatt.
struct RoutePoint: Codable, Hashable {
    var time: Date
    var latitude: Double
    var longitude: Double
}
