import Foundation

/// Rekkefølgen bildene ble tatt i: dag for dag, og innen dagen etter klokkeslett
/// (fra iPhone-bildet de ble koblet til). Bildene samles i steder: et nytt sted begynner
/// når stedsnavnet skifter.
struct PlaceRun: Identifiable {
    let id: String
    let name: String?
    var ids: [String]
}

struct DaySection: Identifiable {
    let day: Day?
    let runs: [PlaceRun]
    var id: String { day.map { "\($0.year)-\($0.month)-\($0.day)" } ?? "uten-dato" }
    var count: Int { runs.reduce(0) { $0 + $1.ids.count } }
}

extension AppModel {
    /// Bildene `ids` ordnet i dager og steder. Bilder uten dato kommer sist.
    func chronology(of ids: [String]) -> [DaySection] {
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let byDay = Dictionary(grouping: ids) { info($0).day }
        let days = byDay.keys.compactMap { $0 }.sorted().map(Optional.some) + (byDay[nil] == nil ? [] : [nil])

        return days.map { day in
            let items = byDay[day]!
            // Først bildene med klokkeslett, i tidsrekkefølge.
            let timed = items.filter { info($0).time != nil }.sorted {
                let a = info($0).time!, b = info($1).time!
                return a == b ? order[$0]! < order[$1]! : a < b
            }
            var runs: [PlaceRun] = []
            for id in timed {
                let name = info(id).place?.name
                // NB: ikke «runs.last?.name == name»: uten steder ennå og uten stedsnavn blir det nil == nil.
                if let last = runs.last, last.name == name { runs[runs.count - 1].ids.append(id) }
                else { runs.append(PlaceRun(id: "\(day.map { "\($0)" } ?? "")-\(runs.count)", name: name, ids: [id])) }
            }
            // Så bildene uten klokkeslett: inn hos første sted med samme navn, ellers nye steder
            // (bilder uten sted helt til slutt).
            let untimed = items.filter { info($0).time == nil }.sorted { order[$0]! < order[$1]! }
            let untimedGroups = Dictionary(grouping: untimed) { info($0).place?.name }
            let names = untimedGroups.keys.sorted { a, b in
                switch (a, b) {
                case let (x?, y?): return untimed.firstIndex { info($0).place?.name == x }! < untimed.firstIndex { info($0).place?.name == y }!
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            for name in names {
                let group = untimedGroups[name]!
                if let index = runs.firstIndex(where: { $0.name == name }) {
                    runs[index].ids += group
                } else {
                    runs.append(PlaceRun(id: "\(day.map { "\($0)" } ?? "")-\(runs.count)", name: name, ids: group))
                }
            }
            return DaySection(day: day, runs: runs)
        }
    }
}
