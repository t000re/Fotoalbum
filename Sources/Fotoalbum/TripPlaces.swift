import CoreLocation
import Foundation

/// Et sted på turen, funnet ved å samle iPhone-bilder tatt nær hverandre.
struct TripPlace: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var firstDay: Day
    var lastDay: Day
    var photoCount: Int
    /// Har du gitt stedet et eget navn? Da beholdes det når lista lages på nytt.
    var renamed = false

    var point: GeoPoint { GeoPoint(lat: latitude, lon: longitude) }
    var place: Place { Place(name: name, latitude: latitude, longitude: longitude) }

    /// «12.–14. juli» eller «12. juli».
    var dayRange: String {
        if firstDay == lastDay { return firstDay.norwegian }
        let f = DateFormatter()
        f.locale = Locale(identifier: "nb_NO")
        f.dateFormat = firstDay.month == lastDay.month ? "d." : "d. MMM"
        return "\(f.string(from: firstDay.date))–\(lastDay.norwegian)"
    }
}

/// Avstand i kilometer (god nok tilnærming for korte avstander).
func distanceKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let rad = Double.pi / 180
    let x = (b.lon - a.lon) * rad * cos((a.lat + b.lat) / 2 * rad)
    let y = (b.lat - a.lat) * rad
    return sqrt(x * x + y * y) * 6371
}

enum PlaceClustering {
    /// Et sted før det har fått navn.
    struct Cluster {
        var latSum = 0.0, lonSum = 0.0, count = 0
        var firstDay: Day, lastDay: Day
        var center: GeoPoint { GeoPoint(lat: latSum / Double(count), lon: lonSum / Double(count)) }

        init(_ p: GeoPoint, _ day: Day) { firstDay = day; lastDay = day; add(p, day) }
        mutating func add(_ p: GeoPoint, _ day: Day) {
            latSum += p.lat; lonSum += p.lon; count += 1
            firstDay = min(firstDay, day); lastDay = max(lastDay, day)
        }
        mutating func merge(_ o: Cluster) {
            latSum += o.latSum; lonSum += o.lonSum; count += o.count
            firstDay = min(firstDay, o.firstDay); lastDay = max(lastDay, o.lastDay)
        }
    }

    /// Bilder i tidsrekkefølge → steder. Først «opphold»: bilder etter hverandre innen 5 km.
    /// Så slås opphold innen 8 km av hverandre sammen (samme sted besøkt flere ganger).
    static func clusters(_ photos: [(point: GeoPoint, day: Day)]) -> [Cluster] {
        var stays: [Cluster] = []
        for (p, day) in photos {
            if var last = stays.last, distanceKm(last.center, p) < 5 {
                last.add(p, day)
                stays[stays.count - 1] = last
            } else {
                stays.append(Cluster(p, day))
            }
        }
        var places: [Cluster] = []
        for stay in stays {
            if let i = places.firstIndex(where: { distanceKm($0.center, stay.center) < 8 }) {
                places[i].merge(stay)
            } else {
                places.append(stay)
            }
        }
        return places.sorted { $0.firstDay < $1.firstDay }
    }
}
