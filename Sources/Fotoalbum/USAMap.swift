import CoreGraphics
import Foundation

/// Et punkt på jorda (grader).
struct GeoPoint: Hashable {
    var lat: Double
    var lon: Double
}

/// En delstat med omriss fra Natural Earth (forenklet, se tools/make-states.py).
struct USState {
    let name: String
    let code: String
    let rings: [[GeoPoint]]

    /// Alle 50 stater + DC, lastet én gang fra Resources/usa-states.json.
    static let all: [USState] = {
        guard let url = Bundle.module.url(forResource: "usa-states", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raw.map { USState(name: $0.name, code: $0.code,
                                 rings: $0.rings.map { $0.map { GeoPoint(lat: $0[1], lon: $0[0]) } }) }
    }()

    /// Fastlands-USA (uten Alaska og Hawaii), som kartet viser.
    static let lower48 = all.filter { $0.code != "AK" && $0.code != "HI" }

    /// Staten et punkt ligger i, eller nil (utenfor USA). Omrisset er forenklet, så punkter helt
    /// ute ved kysten kan havne litt utenfor: da brukes nærmeste stat innen ca. 30 km.
    static func at(_ p: GeoPoint) -> USState? {
        if let inside = all.first(where: { state in state.rings.contains { ring in contains(ring, p) } }) {
            return inside
        }
        let squeeze = cos(p.lat * .pi / 180)
        var best: (state: USState, distance: Double)?
        for state in all {
            for ring in state.rings {
                for q in ring {
                    let d = hypot(q.lat - p.lat, (q.lon - p.lon) * squeeze)
                    if d < (best?.distance ?? 0.3) { best = (state, d) }
                }
            }
        }
        return best?.state
    }

    /// Punkt i polygon (strålemetoden).
    static func contains(_ ring: [GeoPoint], _ p: GeoPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat),
               p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private struct Raw: Decodable {
        let name: String
        let code: String
        let rings: [[[Double]]]
    }
}

/// En geografisk region (fjellkjede, ørken, slette …) fra Natural Earth, se tools/make-regions.py.
struct USRegion {
    let name: String
    let kind: String
    /// Høyere = mindre og mer presis region (Blue Ridge Mountains 5, Appalachian Mountains 2).
    let rank: Int
    let rings: [[GeoPoint]]

    static let all: [USRegion] = {
        guard let url = Bundle.module.url(forResource: "usa-regions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raw.map { USRegion(name: $0.name, kind: $0.kind, rank: $0.rank,
                                  rings: $0.rings.map { $0.map { GeoPoint(lat: $0[1], lon: $0[0]) } }) }
            // Bare regioner som (for det meste) ligger i USA: midtpunktet må være i en delstat.
            .filter { region in
                let points = region.rings.flatMap { $0 }
                guard !points.isEmpty else { return false }
                let center = GeoPoint(lat: points.map(\.lat).reduce(0, +) / Double(points.count),
                                      lon: points.map(\.lon).reduce(0, +) / Double(points.count))
                return USState.at(center) != nil
            }
    }()

    /// Regionene et punkt ligger i, den mest presise først.
    static func containing(_ p: GeoPoint) -> [USRegion] {
        all.filter { region in region.rings.contains { USState.contains($0, p) } }
            .sorted { $0.rank > $1.rank }
    }

    /// Typen på norsk («fjellkjede», «ørken» …).
    var kindName: String {
        switch kind {
        case "Range/mtn": "fjellområde"
        case "Desert": "ørken"
        case "Plain": "slette"
        case "Plateau": "platå"
        case "Valley": "dal"
        case "Gorge": "canyon"
        case "Basin": "basseng"
        case "Coast": "kyst"
        case "Pen/cape": "halvøy"
        case "Foothills": "åslandskap"
        case "Lake": "innsjøer"
        case "Delta": "delta"
        default: "region"
        }
    }

    private struct Raw: Decodable {
        let name: String
        let kind: String
        let rank: Int
        let rings: [[[Double]]]
    }
}

/// Det kartet på en side skal vise: ruten så langt, hvor vi er, og hvilke stater vi har vært i.
struct MapData: Hashable {
    var route: [GeoPoint]
    var here: GeoPoint?
    var visited: Set<String>   // statkoder
    var current: String?       // statkode
}

/// Tegner et enkelt, litt håndtegnet USA-kart med ruten.
enum MapRenderer {
    // Farger: grå strek for statene, varm rød for ruten. Justeres etter Figma-skissen.
    static let lineColor = CGColor(gray: 0.45, alpha: 1)
    static let visitedFill = CGColor(gray: 0.93, alpha: 1)
    static let currentFill = CGColor(srgbRed: 0.96, green: 0.88, blue: 0.80, alpha: 1)
    static let routeColor = CGColor(srgbRed: 0.78, green: 0.22, blue: 0.13, alpha: 1)

    /// Albers-projeksjon (likearealkonisk) med standardparametre for USA. Gir kjent USA-form.
    static func project(_ p: GeoPoint) -> CGPoint {
        let rad = Double.pi / 180
        let phi1 = 29.5 * rad, phi2 = 45.5 * rad, phi0 = 37.5 * rad, lambda0 = -96.0 * rad
        let n = (sin(phi1) + sin(phi2)) / 2
        let c = cos(phi1) * cos(phi1) + 2 * n * sin(phi1)
        let rho0 = sqrt(c - 2 * n * sin(phi0)) / n
        let rho = sqrt(c - 2 * n * sin(p.lat * rad)) / n
        let theta = n * (p.lon * rad - lambda0)
        return CGPoint(x: rho * sin(theta), y: rho0 - rho * cos(theta))
    }

    /// Fastlands-USA sine grenser i projeksjonen.
    private static let bounds: CGRect = {
        let points = USState.lower48.flatMap { $0.rings.flatMap { $0 } }.map(project)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }()

    /// Forholdet bredde/høyde for kartet.
    static var aspect: CGFloat { bounds.width / bounds.height }

    /// Tegner kartet i `rect` (Core Graphics-koordinater, y oppover).
    static func draw(_ map: MapData, in rect: CGRect, ctx: CGContext) {
        guard !USState.lower48.isEmpty else { return }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let offset = CGPoint(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
        func toPage(_ p: GeoPoint) -> CGPoint {
            let q = project(p)
            return CGPoint(x: q.x * scale + offset.x, y: q.y * scale + offset.y)
        }

        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Statene: fyll for besøkte og nåværende, så en tynn, litt skjelven strek rundt alle.
        for (index, state) in USState.lower48.enumerated() {
            for (ringIndex, ring) in state.rings.enumerated() {
                let path = wobbly(ring.map(toPage), amount: 0.5, seed: Double(index * 7 + ringIndex))
                if state.code == map.current || map.visited.contains(state.code) {
                    ctx.addPath(path)
                    ctx.setFillColor(state.code == map.current ? currentFill : visitedFill)
                    ctx.fillPath()
                }
                ctx.addPath(path)
                ctx.setStrokeColor(lineColor)
                ctx.setLineWidth(0.35)
                ctx.strokePath()
            }
        }

        // Ruten så langt: uten punkter tettere enn 1 pt, mykt avrundet, litt skjelven.
        var points: [CGPoint] = []
        for p in map.route.map(toPage) where rect.insetBy(dx: -2, dy: -2).contains(p) {
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1 { continue }
            points.append(p)
        }
        if points.count > 1 {
            ctx.addPath(wobbly(smooth(points), amount: 0.4, seed: 99, closed: false))
            ctx.setStrokeColor(routeColor)
            ctx.setLineWidth(1.0)
            ctx.strokePath()
        }

        // Her er vi: rød prikk med hvit kant.
        if let here = map.here ?? map.route.last {
            let p = toPage(here)
            let r: CGFloat = 2.4
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: p.x - r - 0.8, y: p.y - r - 0.8, width: 2 * r + 1.6, height: 2 * r + 1.6))
            ctx.setFillColor(routeColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.restoreGState()
    }

    /// Lager en linje som ser håndtegnet ut: tettere punkter forskjøvet litt sidelengs med en
    /// rolig bølge. Samme `seed` gir alltid samme strek, så kartet ikke endrer seg mellom sider.
    private static func wobbly(_ points: [CGPoint], amount: CGFloat, seed: Double, closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        let source = closed ? points + [points[0]] : points
        var distance: CGFloat = 0
        var first = true
        for i in 0..<(source.count - 1) {
            let a = source[i], b = source[i + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(length / 2))
            let normal = length > 0 ? CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length) : .zero
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                let d = Double(distance + length * t)
                let wobble = amount * CGFloat(sin(d * 0.35 + seed) * 0.6 + sin(d * 0.13 + seed * 1.7) * 0.4)
                let p = CGPoint(x: a.x + (b.x - a.x) * t + normal.x * wobble,
                                y: a.y + (b.y - a.y) * t + normal.y * wobble)
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
            }
            distance += length
        }
        if closed { path.closeSubpath() } else { path.addLine(to: source.last!) }
        return path
    }

    /// Runder av hjørnene i ruten (Chaikin, to ganger).
    private static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        var result = points
        for _ in 0..<2 {
            guard result.count > 2 else { break }
            var next = [result[0]]
            for i in 0..<(result.count - 1) {
                let a = result[i], b = result[i + 1]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            next.append(result.last!)
            result = next
        }
        return result
    }
}
