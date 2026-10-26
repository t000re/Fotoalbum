import AppKit

/// Et prosjekt i prosjektlista.
struct ProjectInfo: Identifiable {
    let id: UUID
    let name: String
    let modified: Date
    let photoCount: Int
    let folder: String?
}

/// Prosjekter: hvert har sin mappe med skanninger, sin info per bilde, sin bok og sitt omslag.
/// Alt lagres automatisk i Prosjekter-mappa; ⌘S lagrer med en gang.
extension AppModel {
    /// Alle prosjektene, sist endret først.
    func listProjects() -> [ProjectInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.projectsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> ProjectInfo? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let file = Self.readProject(url) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ProjectInfo(id: id, name: file.name ?? "Uten navn", modified: modified,
                               photoCount: file.photos.count, folder: file.folder)
        }
        .sorted { $0.modified > $1.modified }
    }

    func openProject(_ id: UUID) {
        guard id != projectID else { return }
        saveNow()
        guard let file = Self.readProject(Self.projectURL(id)) else {
            alert("Prosjektet kunne ikke åpnes", "Fila kan ikke leses. Det er tatt en kopi av den i Fotoalbum-mappa.")
            return
        }
        load(file, id: id)
    }

    /// Nytt, tomt prosjekt: spør om navn, så om mappa med skanninger.
    func newProject() {
        guard let name = askForName(title: "Nytt prosjekt", text: "Hva skal prosjektet hete?",
                                    initial: uniqueName("Nytt prosjekt")) else { return }
        saveNow()
        var file = ProjectFile()
        file.name = name
        load(file, id: UUID())
        saveNow()
        chooseFolder()
    }

    func renameProject() {
        guard let name = askForName(title: "Gi nytt navn", text: "Nytt navn på prosjektet:", initial: projectName),
              name != projectName else { return }
        project.name = name
        saveNow()
    }

    /// Lagrer en kopi av prosjektet og åpner kopien (originalen blir som den var).
    func duplicateProject() {
        guard let name = askForName(title: "Lagre kopi", text: "Navn på kopien:", initial: uniqueName(projectName + " kopi")) else { return }
        saveNow()
        var copy = project
        copy.name = name
        load(copy, id: UUID())
        saveNow()
    }

    func showProjectsInFinder() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([Self.projectURL(projectID)])
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(listProjects().map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func askForName(title: String, text: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Avbryt")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
