import Foundation

/// Boka: sidene lages fra bildene i dato-rekkefølge, og du endrer mal og rekkefølge per side.
extension AppModel {
    var book: Book { project.book ?? Book() }

    private func changeBook(_ change: (inout Book) -> Void) {
        var b = book
        change(&b)
        project.book = b
        scheduleSave()
    }

    /// Bildene i den rekkefølgen de ble tatt (uten dato sist), som boka bygges fra.
    var photosByDay: [String] {
        chronology(of: photos.map(\.id)).flatMap { $0.runs.flatMap(\.ids) }
    }

    /// Lager boka fra bunnen: ett bilde med marg per side, i dato-rekkefølge.
    func rebuildBook() {
        changeBook { b in
            b.pages = photosByDay.filter { !b.excluded.contains($0) }
                .map { BookPage(layout: .single, photos: [$0]) }
        }
    }

    /// Lager boka første gang Bok åpnes.
    func ensureBook() {
        if project.book == nil { rebuildBook() }
    }

    /// Bilder som verken er i boka eller tatt ut (f.eks. nye i mappa).
    var photosNotInBook: [String] {
        let used = Set(book.pages.flatMap(\.photos))
        return photosByDay.filter { !used.contains($0) && !book.excluded.contains($0) }
    }

    var excludedPhotos: [String] { photosByDay.filter { book.excluded.contains($0) } }

    func setFormat(_ id: String) { changeBook { $0.formatID = id } }

    func setPlaceText(_ value: PlaceText) { changeBook { $0.placeText = value } }

    /// Lagrer ruten fra iPhone-bildene (bare hvis den er endret).
    func setRoute(_ route: [RoutePoint]) {
        guard !route.isEmpty, route != project.route else { return }
        project.route = route
        scheduleSave()
    }

    // MARK: Endre sider

    /// Bytter mal. Trenger malen to bilder, hentes det første bildet fra neste side;
    /// trenger den ett, flyttes det andre bildet til en ny side rett etter.
    func setLayout(_ layout: PageLayout, for pageID: UUID) {
        changeBook { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
            b.pages[i].layout = layout
            if layout.photoCount == 2, b.pages[i].photos.count < 2, i + 1 < b.pages.count {
                let moved = b.pages[i + 1].photos.removeFirst()
                b.pages[i].photos.append(moved)
                if b.pages[i + 1].photos.isEmpty {
                    b.pages.remove(at: i + 1)
                } else if b.pages[i + 1].layout == .two {
                    b.pages[i + 1].layout = .single
                }
            } else if layout.photoCount == 1, b.pages[i].photos.count > 1 {
                let rest = Array(b.pages[i].photos.dropFirst())
                b.pages[i].photos = [b.pages[i].photos[0]]
                b.pages.insert(contentsOf: rest.map { BookPage(layout: .single, photos: [$0]) }, at: i + 1)
            }
        }
    }

    /// Flytter en side ett hakk fram eller tilbake.
    func movePage(_ pageID: UUID, by step: Int) {
        changeBook { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }) else { return }
            let j = i + step
            guard b.pages.indices.contains(j) else { return }
            b.pages.swapAt(i, j)
        }
    }

    /// Bytter plass på de to bildene på en side.
    func swapPhotos(on pageID: UUID) {
        changeBook { b in
            guard let i = b.pages.firstIndex(where: { $0.id == pageID }), b.pages[i].photos.count == 2 else { return }
            b.pages[i].photos.swapAt(0, 1)
        }
    }

    /// Tar et bilde ut av boka. Tomme sider forsvinner.
    func removeFromBook(_ photo: String) {
        changeBook { b in
            for i in b.pages.indices { b.pages[i].photos.removeAll { $0 == photo } }
            b.pages.removeAll { $0.photos.isEmpty }
            for i in b.pages.indices where b.pages[i].layout == .two && b.pages[i].photos.count < 2 {
                b.pages[i].layout = .single
            }
            b.excluded.insert(photo)
        }
    }

    /// Setter et bilde inn igjen på egen side, der det hører hjemme etter dato.
    func addToBook(_ photo: String) {
        changeBook { b in
            b.excluded.remove(photo)
            let order = photosByDay
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let mine = rank[photo] ?? order.count
            let index = b.pages.firstIndex { page in (page.photos.compactMap { rank[$0] }.min() ?? 0) > mine }
            b.pages.insert(BookPage(layout: .single, photos: [photo]), at: index ?? b.pages.count)
        }
    }
}
