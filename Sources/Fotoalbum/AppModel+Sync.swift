import AppKit
import Photos

/// iCloud-synk: prosjektene ligger i iCloud Drive/Fotoalbum/Prosjekter, så de kan brukes på flere Mac-er.
/// Det som bare gjelder denne Mac-en (likhetsfingeravtrykk, sist åpne prosjekt, reservekopier) blir
/// liggende i Application Support. Endringer fra en annen Mac lastes inn når appen kommer fram,
/// og ellers hvert 5. sekund.
extension AppModel {
    /// iCloud Drive på denne Mac-en, hvis det er slått på.
    nonisolated static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Prosjektmappa i iCloud Drive. nil uten iCloud Drive, og ved testing (FOTOALBUM_BIBLIOTEK).
    nonisolated static var iCloudProjects: URL? {
        guard ProcessInfo.processInfo.environment["FOTOALBUM_BIBLIOTEK"] == nil, let drive = iCloudDrive else { return nil }
        return drive.appendingPathComponent("Fotoalbum/Prosjekter")
    }

    /// Prosjektmappa på denne Mac-en (brukt før iCloud, og uten iCloud Drive).
    nonisolated static var localProjects: URL { libraryFolder.appendingPathComponent("Prosjekter") }

    /// Første gang med iCloud: kopierer prosjektene på denne Mac-en dit (de som ikke finnes der fra før).
    /// Originalene blir liggende urørt som reserve.
    nonisolated static func copyProjectsToICloud() {
        guard let cloud = iCloudProjects else { return }
        let fm = FileManager.default
        let marker = libraryFolder.appendingPathComponent("Prosjektene er kopiert til iCloud.txt")
        guard !fm.fileExists(atPath: marker.path) else { return }
        do {
            try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
            for url in (try? fm.contentsOfDirectory(at: localProjects, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "json" {
                let target = cloud.appendingPathComponent(url.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
            }
            try fm.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
            try "Prosjektene i Prosjekter-mappa her ble kopiert til iCloud Drive/Fotoalbum/Prosjekter. Appen bruker kopiene i iCloud; disse er en reserve.\n"
                .write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Kunne ikke kopiere prosjektene til iCloud: \(error)")
        }
    }

    // MARK: Lese og skrive (koordinert, så iCloud ikke leser en halvskrevet fil)

    nonisolated static func readData(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }

    nonisolated static func writeData(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    // MARK: Endringer fra en annen Mac

    func startWatchingForOutsideChanges() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForOutsideChanges() }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForOutsideChanges() }
        }
    }

    /// Leser prosjektfila; har en annen Mac endret den, tas endringene inn. Har du selv en ulagret
    /// endring, venter vi (den lagres om et halvt sekund og vinner).
    func checkForOutsideChanges() {
        guard !pendingSave, !checkingDisk else { return }
        checkingDisk = true
        let id = projectID
        let url = Self.projectURL(id)
        Task {
            let data = await Task.detached(priority: .utility) { Self.readData(url) }.value
            checkingDisk = false
            guard id == projectID, !pendingSave, let data, data != lastDiskData,
                  let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return }
            lastDiskData = data
            let folderChanged = file.folder != project.folder
            project = file
            undoStack = []
            redoStack = []
            if folderChanged { reloadPhotos() }
            translatePhoneIDs()
        }
    }

    // MARK: Mappa med skanninger på en annen Mac

    /// Mappa med skanninger på denne Mac-en. Ligger den i iCloud Drive (eller i hjemmemappa) og stien
    /// er fra en annen Mac, finnes den samme mappa her.
    func resolvedFolder() -> URL? {
        guard let path = project.folder else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let cloudMark = "/Library/Mobile Documents/com~apple~CloudDocs/"
        if let range = path.range(of: cloudMark), let drive = Self.iCloudDrive {
            let url = drive.appendingPathComponent(String(path[range.upperBound...]))
            if fm.fileExists(atPath: url.path) { return url }
        }
        // /Users/<annen bruker>/… → /Users/<meg>/…
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 2, parts[0] == "Users" {
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent(parts.dropFirst(2).joined(separator: "/"))
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: iPhone-bilder på en annen Mac

    /// Bilder-appen gir hvert bilde en ID som bare gjelder denne Mac-en. Derfor lagres også
    /// iCloud-ID-en (lik på alle Mac-er med samme iCloud-bildebibliotek).
    nonisolated static func cloudID(forPhone localID: String) -> String? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return nil }
        let result = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [localID])[localID]
        return try? result?.get().stringValue
    }

    /// Gjør iPhone-koblingene gyldige på denne Mac-en: bilder med iCloud-ID får den lokale ID-en
    /// (bare i minnet, til neste endring lagres), og bilder koblet på denne Mac-en før synken fikk
    /// iCloud-ID-en sin.
    func translatePhoneIDs() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let library = PHPhotoLibrary.shared()

        let withCloud = project.photos.filter { $0.value.phoneCloudID != nil }
        let cloudIDs = Set(withCloud.compactMap(\.value.phoneCloudID)).map(PHCloudIdentifier.init(stringValue:))
        if !cloudIDs.isEmpty {
            let local = library.localIdentifierMappings(for: cloudIDs)
            for (id, info) in withCloud {
                guard let cloud = info.phoneCloudID,
                      let localID = try? local[PHCloudIdentifier(stringValue: cloud)]?.get(),
                      localID != info.phoneID else { continue }
                project.photos[id]?.phoneID = localID
            }
        }

        let withoutCloud = project.photos.filter { $0.value.phoneID != nil && $0.value.phoneCloudID == nil }
        guard !withoutCloud.isEmpty else { return }
        let mappings = library.cloudIdentifierMappings(forLocalIdentifiers: withoutCloud.compactMap(\.value.phoneID))
        var changed = false
        for (id, info) in withoutCloud {
            guard let localID = info.phoneID, let cloud = try? mappings[localID]?.get() else { continue }
            project.photos[id]?.phoneCloudID = cloud.stringValue
            changed = true
        }
        if changed { scheduleSave() }
    }
}
