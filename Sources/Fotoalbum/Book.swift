import CoreGraphics
import Foundation

/// Et Blurb-format. Mål i punkter (72 per tomme), fra Blurbs «PDF to Book Specifications»
/// (blurb.com/make/pdf_to_book/booksize_calculator, sjekket 23. okt. 2026). Merk at kuttet er litt
/// mindre enn navnet: «10×8» er 9,5 × 8 tommer.
struct BookFormat: Identifiable, Hashable {
    let id: String
    let name: String
    /// Siden etter kutting.
    let trim: CGSize

    /// Utfallende kant: 1/8 tomme på topp, bunn og ytterkant. Ingen mot ryggen.
    static let bleed: CGFloat = 9
    /// Tekst og viktige ting holdes minst 1/4 tomme innenfor kuttet …
    static let safe: CGFloat = 18
    /// … og minst 5/8 tomme fra ryggen.
    static let safeBinding: CGFloat = 45

    /// Hele PDF-siden: kuttet + utfallende kant (ytterkant, topp og bunn).
    var pageSize: CGSize { CGSize(width: trim.width + Self.bleed, height: trim.height + 2 * Self.bleed) }

    static let all = [
        BookFormat(id: "landscape-10x8", name: "Standard liggende 10×8", trim: CGSize(width: 684, height: 576)),
        BookFormat(id: "portrait-8x10", name: "Standard stående 8×10", trim: CGSize(width: 576, height: 720)),
        BookFormat(id: "square-7x7", name: "Liten kvadratisk 7×7", trim: CGSize(width: 486, height: 477)),
        BookFormat(id: "square-12x12", name: "Stor kvadratisk 12×12", trim: CGSize(width: 846, height: 846)),
        BookFormat(id: "landscape-13x11", name: "Stor liggende 13×11", trim: CGSize(width: 900, height: 765)),
    ]

    static func with(id: String) -> BookFormat { all.first { $0.id == id } ?? all[0] }
}

/// Malene en side kan ha.
enum PageLayout: String, Codable, CaseIterable {
    case single     // ett bilde med hvit marg og tekst under
    case two        // to bilder side om side, tekst under hvert
    case fullBleed  // ett bilde over hele siden, til kanten

    var name: String {
        switch self {
        case .single: "Ett bilde med marg"
        case .two: "To bilder"
        case .fullBleed: "Utfallende"
        }
    }
    var symbol: String {
        switch self {
        case .single: "photo"
        case .two: "rectangle.split.2x1"
        case .fullBleed: "rectangle.fill"
        }
    }
    var photoCount: Int { self == .two ? 2 : 1 }
}

/// Bildeteksten: «Område · Sted», bare området eller bare stedet.
enum PlaceText: String, Codable, CaseIterable {
    case both, area, place
    var name: String {
        switch self {
        case .both: "Område · Sted"
        case .area: "Bare område"
        case .place: "Bare sted"
        }
    }
}

/// Kart på siden: automatisk (når vi kommer til en ny stat), alltid eller aldri.
enum MapChoice: String, Codable, CaseIterable {
    case show, hide
}

/// Én side i boka: malen og hvilke bilder (filnavn) som står på den.
struct BookPage: Codable, Hashable, Identifiable {
    var id = UUID()
    var layout: PageLayout
    var photos: [String]
    /// nil = automatisk: kart når siden er den første i en ny stat.
    var map: MapChoice?
}

/// Boka: format, sidene i rekkefølge, og bilder du har tatt ut av boka.
struct Book: Codable {
    var formatID = BookFormat.all[0].id
    var pages: [BookPage] = []
    var excluded: Set<String> = []
    var cover: Cover?
    /// Hva bildeteksten viser av område og sted. nil = begge.
    var placeText: PlaceText?

    var format: BookFormat { BookFormat.with(id: formatID) }

    /// Side 1, 3, 5 … (indeks 0, 2, 4 …) er høyresider.
    static func isRight(_ index: Int) -> Bool { index % 2 == 0 }

    /// Oppslagene slik boka åpnes: side 1 alene til høyre, så par (2–3, 4–5 …).
    /// Hvert oppslag er [venstre, høyre], der nil betyr ingen side.
    var spreads: [[Int?]] {
        guard !pages.isEmpty else { return [] }
        var result: [[Int?]] = [[nil, 0]]
        var i = 1
        while i < pages.count {
            result.append([i, i + 1 < pages.count ? i + 1 : nil])
            i += 2
        }
        return result
    }
}

// MARK: Plassering på siden

/// Hvor ett bilde og teksten dets står på siden. Mål i punkter fra øvre venstre hjørne av kuttet.
struct Slot {
    let photo: String
    let photoRect: CGRect
    /// true: bildet fyller rammen og beskjæres (utfallende). false: hele bildet vises.
    let fill: Bool
    let captionRect: CGRect?
}

/// Mål i punkter fra øvre venstre hjørne av kuttet. Venstre- og høyresider er speilvendt:
/// marg mot ryggen (innermarg) er større, og utfallende bilder går bare ut over ytterkanten.
enum PageGeometry {
    static let outerMargin: CGFloat = 0.6 * 72
    static let innerMargin: CGFloat = 0.75 * 72   // minst 45 pt (Blurbs sikre sone mot ryggen)
    static let topMargin: CGFloat = 0.6 * 72
    static let bottomMargin: CGFloat = 0.6 * 72
    static let captionSpace: CGFloat = 0.75 * 72  // plass til sted/dato + tre linjer beskrivelse
    static let captionGap: CGFloat = 7
    static let gutter: CGFloat = 0.25 * 72

    /// Kartets størrelse på siden.
    static let mapSize = CGSize(width: 1.45 * 72, height: 0.9 * 72)

    /// Bildene, og kartet hvis siden skal ha det. Kartet står under bildet til høyre
    /// (på utfallende sider nede til høyre på et hvitt felt), og teksten ved siden av blir smalere.
    static func layout(for page: BookPage, format: BookFormat, isRight: Bool, showMap: Bool,
                       aspect: (String) -> CGFloat) -> (slots: [Slot], map: CGRect?) {
        var result = slots(for: page, format: format, isRight: isRight, aspect: aspect)
        guard showMap, let last = result.last else { return (result, nil) }
        let size = format.trim
        if page.layout == .fullBleed {
            // I det ytre nedre hjørnet.
            let inset = BookFormat.safe + 0.15 * 72
            let x = isRight ? size.width - inset - mapSize.width : inset
            return (result, CGRect(x: x, y: size.height - inset - mapSize.height,
                                   width: mapSize.width, height: mapSize.height))
        }
        let map = CGRect(x: last.photoRect.maxX - mapSize.width, y: last.photoRect.maxY + captionGap + 2,
                         width: mapSize.width, height: mapSize.height)
        if let caption = last.captionRect, caption.maxX > map.minX - 10 {
            var narrower = caption
            narrower.size.width = max(0, map.minX - 10 - caption.minX)
            result[result.count - 1] = Slot(photo: last.photo, photoRect: last.photoRect, fill: last.fill,
                                            captionRect: narrower)
        }
        return (result, map)
    }

    /// Plasseringene for en side. `aspect` gir bredde/høyde for hvert bilde.
    static func slots(for page: BookPage, format: BookFormat, isRight: Bool, aspect: (String) -> CGFloat) -> [Slot] {
        let size = format.trim
        switch page.layout {
        case .fullBleed:
            guard let id = page.photos.first else { return [] }
            let b = BookFormat.bleed
            return [Slot(photo: id, photoRect: CGRect(x: isRight ? 0 : -b, y: -b, width: size.width + b, height: size.height + 2 * b),
                         fill: true, captionRect: nil)]
        case .single, .two:
            let left = isRight ? innerMargin : outerMargin
            let area = CGRect(x: left, y: topMargin,
                              width: size.width - innerMargin - outerMargin,
                              height: size.height - topMargin - bottomMargin - captionSpace)
            let count = page.layout.photoCount
            let cellWidth = (area.width - gutter * CGFloat(count - 1)) / CGFloat(count)
            return page.photos.prefix(count).enumerated().map { index, id in
                let cell = CGRect(x: area.minX + CGFloat(index) * (cellWidth + gutter), y: area.minY,
                                  width: cellWidth, height: area.height)
                let rect = fit(aspect(id), in: cell)
                // Teksten starter ved bildets venstre kant, men får minst 3 tommer bredde (innenfor ruta).
                let width = max(rect.width, min(cell.width, 3 * 72))
                let caption = CGRect(x: min(rect.minX, cell.maxX - width), y: rect.maxY + captionGap,
                                     width: width, height: captionSpace - captionGap)
                return Slot(photo: id, photoRect: rect, fill: false, captionRect: caption)
            }
        }
    }

    /// Største rektangel med gitt forhold som får plass i `box`, midtstilt.
    static func fit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        let a = aspect > 0 ? aspect : 1.5
        var w = box.width, h = w / a
        if h > box.height { h = box.height; w = h * a }
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
