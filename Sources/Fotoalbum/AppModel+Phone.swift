import Photos

extension AppModel {
    /// Kopierer dato, sted og klokkeslett fra et iPhone-bilde til de analoge bildene `targets`.
    func copy(from asset: PHAsset, phone: PhoneLibrary, to targets: [String]) async {
        guard !targets.isEmpty else { return }
        let (day, place, zone) = await phone.dayAndPlace(of: asset)
        apply(day: day, place: place, time: asset.creationDate, timeZone: zone?.identifier, source: .iPhone,
              phoneID: asset.localIdentifier, to: targets)
    }
}
