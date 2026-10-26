import CoreGraphics
import Foundation

/// Papirtypene Blurb tilbyr for fotobøker. Papiret avgjør hvor tykk boka blir, og dermed ryggen.
enum Paper: String, Codable, CaseIterable {
    case standard
    case premium            // Premium (lustre eller matt)
    case mohawkEggshell     // Mohawk Superfine Eggshell
    case mohawkPearl        // Mohawk proPhoto Pearl

    var name: String {
        switch self {
        case .standard: "Standard"
        case .premium: "Premium (lustre eller matt)"
        case .mohawkEggshell: "Mohawk Superfine Eggshell"
        case .mohawkPearl: "Mohawk proPhoto Pearl"
        }
    }

    /// Ryggbredde i punkter etter sidetall: (fra og med sidetall, bredde). Fra Blurbs kalkulator
    /// (hardcover med smussomslag), målt 23. okt. 2026 i steg på 2 sider.
    var spineSteps: [(fromPages: Int, width: CGFloat)] {
        switch self {
        case .standard: SPINE_STANDARD
        case .premium: SPINE_PREMIUM
        case .mohawkEggshell: SPINE_EGGSHELL
        case .mohawkPearl: SPINE_PEARL
        }
    }

    /// Høyeste sidetall papiret kan ha.
    var maxPages: Int { MAX_PAGES[self]! }

    func spineWidth(pages: Int) -> CGFloat {
        spineSteps.last { pages >= $0.fromPages }?.width ?? spineSteps[0].width
    }
}

/// Omslaget: hard perm med smussomslag (løst papiromslag med klaffer).
/// Fra venstre: bakre klaff, bakside, rygg, forside, fremre klaff.
struct Cover: Codable, Hashable {
    var frontPhoto: String?
    var backPhoto: String?
    var title = "USA 2022"
    var subtitle = ""
    /// Hvit tekst (på mørke bilder) eller svart.
    var whiteTitle = true
    /// Kartet med hele ruten på bakre klaff.
    var mapOnFlap = true
    var paper = Paper.standard
    /// Eget omslag laget i Figma/Photoshop (bilde eller PDF i full størrelse med utfallende kant).
    var customFile: String?
    var useCustom = false

    init() {}

    /// Felter som mangler i eldre prosjektfiler, får standardverdien.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Cover()
        frontPhoto = try c.decodeIfPresent(String.self, forKey: .frontPhoto)
        backPhoto = try c.decodeIfPresent(String.self, forKey: .backPhoto)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? d.subtitle
        whiteTitle = try c.decodeIfPresent(Bool.self, forKey: .whiteTitle) ?? d.whiteTitle
        mapOnFlap = try c.decodeIfPresent(Bool.self, forKey: .mapOnFlap) ?? d.mapOnFlap
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper) ?? d.paper
        customFile = try c.decodeIfPresent(String.self, forKey: .customFile)
        useCustom = try c.decodeIfPresent(Bool.self, forKey: .useCustom) ?? d.useCustom
    }
}

/// Målene til smussomslaget i punkter, fra Blurbs «PDF to Book Specifications» (hardcover, dust jacket),
/// sjekket 23. okt. 2026. Forside og bakside er alltid like store; når ryggen blir bredere,
/// blir klaffene tilsvarende smalere, så hele omslaget er (nesten) like bredt.
struct CoverSpec: Hashable {
    /// Forside og bakside (hver), etter kutt.
    let panel: CGSize
    /// Klaffene (hver), fra kutt til brett.
    let flapWidth: CGFloat
    let spineWidth: CGFloat
    static let bleed: CGFloat = 9
    static let safe: CGFloat = 18

    var trim: CGSize { CGSize(width: 2 * flapWidth + 2 * panel.width + spineWidth, height: panel.height) }
    var pageSize: CGSize { CGSize(width: trim.width + 2 * Self.bleed, height: trim.height + 2 * Self.bleed) }

    // Delene av omslaget, målt fra øvre venstre hjørne av kuttet.
    var backFlap: CGRect { CGRect(x: 0, y: 0, width: flapWidth, height: panel.height) }
    var back: CGRect { CGRect(x: flapWidth, y: 0, width: panel.width, height: panel.height) }
    var spine: CGRect { CGRect(x: back.maxX, y: 0, width: spineWidth, height: panel.height) }
    var front: CGRect { CGRect(x: spine.maxX, y: 0, width: panel.width, height: panel.height) }
    var frontFlap: CGRect { CGRect(x: front.maxX, y: 0, width: flapWidth, height: panel.height) }

    /// Per format: forside/bakside (b × h) og hele bredden ved 41 pt rygg (100 sider standardpapir).
    private static let formats: [String: (panel: CGSize, baseWidth: CGFloat)] = [
        "landscape-10x8": (CGSize(width: 716, height: 594), 2069),
        "portrait-8x10": (CGSize(width: 603, height: 738), 1835),
        "square-7x7": (CGSize(width: 516, height: 495), 1547),
        "square-12x12": (CGSize(width: 879, height: 864), 2359),
        "landscape-13x11": (CGSize(width: 931, height: 783), 2501),
    ]

    static func make(format: BookFormat, paper: Paper, pages: Int) -> CoverSpec {
        let f = formats[format.id] ?? formats["landscape-10x8"]!
        let spine = paper.spineWidth(pages: pages)
        // Blurb runder klaffen opp til hele punkter.
        let flap = ((f.baseWidth - 2 * f.panel.width - spine) / 2).rounded(.up)
        return CoverSpec(panel: f.panel, flapWidth: flap, spineWidth: spine)
    }
}
