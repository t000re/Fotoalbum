import Foundation
import Observation

/// Fokusmodus: ett bilde og ett spørsmål om gangen (sted → dato → beskrivelse), styrt med tastaturet.
@MainActor @Observable
final class FocusSession {
    enum Step: Int, CaseIterable {
        case region, area, place, day, caption
        var title: String {
            switch self {
            case .region: "Hvilken stat, fylke eller region?"
            case .place: "Hvor er bildet tatt?"
            case .area: "Hvilket område?"
            case .day: "Når er bildet tatt?"
            case .caption: "Beskrivelse"
            }
        }
        var name: String {
            switch self {
            case .region: "Region"
            case .place: "Sted"
            case .area: "Område"
            case .day: "Dato"
            case .caption: "Beskrivelse"
            }
        }
    }

    /// Ett forslag i lista under feltet.
    struct Option: Identifiable, Hashable {
        let title: String
        let detail: String
        var place: Place?
        var day: Day?
        /// Treff fra Apples stedssøk (har ikke kartpunkt før det velges). Undertittelen, f.eks. «MT, USA».
        var searchSubtitle: String?
        /// Region-steget: filterkoden («US-NM» eller «land:US»).
        var code: String?
        var id: String { title + "|" + detail }
    }

    /// Bildene som gås gjennom (de som manglet sted eller dato da fokusmodus startet).
    var queue: [String] = []
    var index = 0
    var step: Step = .place
    /// Teksten i feltet.
    var text = ""
    /// Markert forslag (↑↓), eller nil = bruk det som er skrevet.
    var highlighted: Int?
    var message: String?
    /// Du har skrevet i feltet siden steget startet (da filtreres forslagene).
    var edited = false
    /// Teksten appen fylte inn da steget startet (endringer bort fra den regnes som skriving).
    var loadedText = ""
    /// Dagen iPhone-bildene til høyre er filtrert på (nil = alle dager).
    /// Regionen (eller landet, «land:US») bildene filtreres på. Blir stående til neste bilde.
    var browseRegion: String?
    var browseDay: Day?
    /// Bildet stegene sist ble lastet for (for å vite når et nytt bilde vises).
    var loadedPhoto: String?

    var current: String? { queue.indices.contains(index) ? queue[index] : nil }
    var isFinished: Bool { index >= queue.count }
}

/// Tolker en dato du skriver: «14.7», «14.07.2022», «14. juli», «14 jul», «2022-07-14».
enum DayParser {
    static func parse(_ text: String, defaultYear: Int) -> Day? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        // ÅÅÅÅ-MM-DD
        let iso = t.split(separator: "-").compactMap { Int($0) }
        if iso.count == 3, iso[0] > 1900 { return valid(iso[0], iso[1], iso[2]) }
        // D.M eller D.M.ÅÅÅÅ (også med / eller mellomrom)
        let numbers = t.split(whereSeparator: { ".-/ ".contains($0) }).compactMap { Int($0) }
        let words = t.split(whereSeparator: { ".-/ ".contains($0) }).filter { Int($0) == nil }
        if words.isEmpty, numbers.count >= 2 {
            let year = numbers.count >= 3 ? (numbers[2] < 100 ? 2000 + numbers[2] : numbers[2]) : defaultYear
            return valid(year, numbers[1], numbers[0])
        }
        // D. måned [år]
        if let dayNumber = numbers.first, let word = words.first, let month = month(String(word)) {
            let year = numbers.count >= 2 ? (numbers[1] < 100 ? 2000 + numbers[1] : numbers[1]) : defaultYear
            return valid(year, month, dayNumber)
        }
        return nil
    }

    private static func month(_ word: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "mai", "jun", "jul", "aug", "sep", "okt", "nov", "des"]
        let english = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let w = String(word.prefix(3))
        return (names.firstIndex(of: w) ?? english.firstIndex(of: w)).map { $0 + 1 }
    }

    private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Day? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        guard let date = Calendar(identifier: .gregorian).date(from: c),
              Calendar(identifier: .gregorian).component(.day, from: date) == d else { return nil }
        return Day(year: y, month: m, day: d)
    }
}
