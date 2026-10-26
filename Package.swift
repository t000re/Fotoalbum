// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Fotoalbum",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fotoalbum", targets: ["Fotoalbum"]),
    ],
    targets: [
        // Appen: bildene, dato/sted/beskrivelse per bilde, og (senere) boka.
        // usa-states.json og usa-regions.json: delstater og geografiske regioner fra Natural Earth
        // (allemannseie), laget med tools/make-states.py og tools/make-regions.py.
        .executableTarget(name: "Fotoalbum", resources: [.copy("Resources/usa-states.json"),
                                                         .copy("Resources/usa-regions.json"),
                                                         // Land og regioner i hele verden (tools/make-world.py).
                                                         .copy("Resources/world-countries.json"),
                                                         .copy("Resources/world-regions.json")]),
    ]
)
