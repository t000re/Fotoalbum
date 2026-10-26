import AppKit
import SwiftUI

@main
struct FotoalbumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Fotoalbum", id: "main") {
            ContentView()
                .environment(delegate.model)
                .environment(delegate.phone)
                .environment(delegate.similarity)
                .frame(minWidth: 1150, minHeight: 650)
        }
        Window("Oversikt", id: "overview") {
            OverviewView()
                .environment(delegate.model)
        }
        .keyboardShortcut("1")
        .defaultSize(width: 460, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nytt prosjekt …") { delegate.model.newProject() }
                    .keyboardShortcut("n")
                ProjectsMenu(model: delegate.model)
                Button("Gi prosjektet nytt navn …") { delegate.model.renameProject() }
                Button("Lagre kopi av prosjektet …") { delegate.model.duplicateProject() }
                Button("Vis prosjektfila i Finder") { delegate.model.showProjectsInFinder() }
                Divider()
                Button("Velg mappe med skanninger …") { delegate.model.chooseFolder() }
                    .keyboardShortcut("o")
                Divider()
                Button("Eksporter kopier med dato og sted …") { delegate.model.exportCopies() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                // Bok og omslag er skjult inntil videre (koden ligger i Book*/Cover*).
            }
            // ⌘S: alt lagres automatisk, men ⌘S lagrer med en gang.
            CommandGroup(replacing: .saveItem) {
                Button("Lagre") { delegate.model.saveNow() }
                    .keyboardShortcut("s")
            }
            // ⌘Z: i et tekstfelt angres skrivingen; ellers angres siste endring av dato, sted eller beskrivelse.
            CommandGroup(replacing: .undoRedo) {
                Button("Angre") {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
                        text.undoManager?.undo()
                    } else {
                        delegate.model.undo()
                    }
                }
                .keyboardShortcut("z")
                Button("Gjør om") {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
                        text.undoManager?.redo()
                    } else {
                        delegate.model.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Bilde") {
                Button("Neste bilde") {
                    if delegate.model.mode == .focus { delegate.model.focusNextPhoto() } else { delegate.model.selectNext(1) }
                }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Forrige bilde") {
                    if delegate.model.mode == .focus { delegate.model.focusPreviousPhoto() } else { delegate.model.selectNext(-1) }
                }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Samme dato og sted som sist") {
                    delegate.model.applySameAsLast()
                    delegate.model.focusDidFill()
                }
                .keyboardShortcut("d")
                Button("Merk som usikker") {
                    for id in delegate.model.selectedIDs {
                        delegate.model.update(id) { $0.uncertain = $0.isUncertain ? nil : true }
                    }
                }
                .keyboardShortcut("u")
                Button("Fyll inn mellom like bilder på rullen …") { delegate.fillRollGaps() }
                Divider()
                ForEach(1...5, id: \.self) { n in
                    Button("Bruk forslag \(n)") { delegate.useSuggestion(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor let phone = PhoneLibrary()
    @MainActor let similarity = SimilarityIndex()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { model.similarity = similarity; model.phone = phone }
        // Trengs når appen startes rett fra Terminal (uten .app rundt), så vinduet kommer fram.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// «Bruk forslag n» fra menyen: kopier fra det n-te iPhone-bildet i «Ligner mest».
    @MainActor func useSuggestion(_ n: Int) {
        let list = similarity.suggestions
        guard list.indices.contains(n - 1), similarity.suggestionsFor == model.selection else { return }
        let asset = list[n - 1].asset
        let targets = model.selectedIDs
        Task {
            await model.copy(from: asset, phone: phone, to: targets)
            model.focusDidFill()
        }
    }

    /// Fyller hull på rullen: bilder mellom to bilder med samme dato og sted får det samme.
    @MainActor func fillRollGaps() {
        let confirm = NSAlert()
        confirm.messageText = "Fyll inn mellom like bilder på rullen?"
        confirm.informativeText = "Bilder uten dato og sted som ligger mellom to bilder med samme dato og sted på rullen, får den datoen og det stedet. Rekkefølgen er " + (model.scanTimes.isEmpty ? "etter filnavn." : "etter skannetiden i filene.") + " Du kan angre med ⌘Z."
        confirm.addButton(withTitle: "Fyll inn")
        confirm.addButton(withTitle: "Avbryt")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let count = model.fillBetweenEqualNeighbors()
        let done = NSAlert()
        done.messageText = count == 0 ? "Ingen hull å fylle" : "\(count) bilder fikk dato og sted"
        done.runModal()
    }

    @MainActor func compareSuggestion(_ n: Int) {
        let list = similarity.suggestions
        guard list.indices.contains(n - 1), similarity.suggestionsFor == model.selection else { return }
        model.compareAsset = list[n - 1].asset
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
    }
}

