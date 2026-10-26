import CoreGraphics

// Ryggbredder for smussomslag (hardcover, dust jacket) fra Blurbs «PDF to Book Specifications»,
// målt 23. okt. 2026 for Standard Landscape i steg på 2 sider (samme for alle formater ved stikkprøver).
// Hvert par er (fra og med sidetall, ryggbredde i punkter).

let SPINE_STANDARD: [(fromPages: Int, width: CGFloat)] = [(20, 33), (74, 41), (148, 54), (222, 66), (296, 79), (370, 89)]
let SPINE_PREMIUM: [(fromPages: Int, width: CGFloat)] = [(20, 33), (52, 41), (102, 54), (162, 66), (202, 79)]
let SPINE_EGGSHELL: [(fromPages: Int, width: CGFloat)] = [(20, 33), (42, 41), (82, 54), (122, 66), (162, 79), (202, 89)]
let SPINE_PEARL: [(fromPages: Int, width: CGFloat)] = SPINE_EGGSHELL

/// Høyeste sidetall per papir (Blurb gir ingen mål over dette).
let MAX_PAGES: [Paper: Int] = [.standard: 440, .premium: 240, .mohawkEggshell: 240, .mohawkPearl: 240]
