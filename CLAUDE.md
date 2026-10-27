# Fotoalbum – prosjektbeskrivelse for Claude Code

## Hva appen er
En enkel macOS-app for å lage en fotobok fra en USA-ferie i 2022. Jeg har 390 skannede analoge
bilder uten metadata. Appen lar meg:
1. Gi hvert analoge bilde dato og sted, helst ved å kopiere fra iPhone-bilder fra samme tur
   (som ligger i Bilder-appen) med ett klikk
2. Skrive en beskrivelse til bilder
3. Sette sammen en fotobok med bilder, stedsnavn, dato og beskrivelser
4. Eksportere innmat og omslag som PDF-er klare for Blurb PDF to Book
   (https://www.blurb.com/pdf-to-book)

Jeg er designer uten kodebakgrunn. Forklar kort hva du gjør og hvorfor, hold koden
enkel og lesbar, og spør heller enn å gjette når noe påvirker hvordan boka ser ut.

## Kildefiler
- Skanningene er JPEG, eksportert fra Lightroom Classic uten meningsfulle filnavn og i tilfeldig
  rekkefølge. Appen kan ikke stole på filnavn eller rekkefølge.
- Formatet kan endres (f.eks. TIFF) hvis det trengs for trykk.
- Originalene endres aldri. Appen leser dem og lagrer sine egne data ved siden av.

## Personvern
Claude skal ikke se, åpne eller ta skjermbilder av bildene mine (skanningene eller Bilder-biblioteket).
Test med genererte testbilder og `FOTOALBUM_BIBLIOTEK=<testmappe>`, så det ekte prosjektet ikke røres.

## Teknisk retning
- Swift + SwiftUI, kun macOS (Apple Silicon)
- PhotoKit (PHPhotoLibrary) for å lese iPhone-bildene fra Bilder-appen: dato, GPS og miniatyrer.
  Bare lesetilgang.
- CoreLocation (CLGeocoder) for stedsnavn fra GPS. Stedsnavnet kan alltid redigeres.
- MapKit for et lite kart ved siden av iPhone-bildene
- PDF lages med Core Graphics (CGContext for PDF) med trim- og bleed-bokser
- Ingen tredjepartsavhengigheter med mindre vi blir enige om det

## Data
- Per analogt bilde: dato (uten klokkeslett), sted (navn + ev. koordinater), beskrivelse,
  og hvor dato/sted kom fra (iPhone-bilde, forrige bilde eller skrevet inn)
- Hvert prosjekt lagres automatisk som JSON i Prosjekter-mappa
- Arkiv > «Eksporter kopier med dato og sted» (⇧⌘E): kopier i en ny mappe med navn som
  `220714_yosemite-national-park_01.jpg` (nummerert i tidsrekkefølge) og dato/tid (EXIF), GPS,
  stedsnavn og beskrivelse (IPTC) i bildet. Bildedataene kopieres uendret. Originalene røres ikke.
  IPTC: sted (Sublocation), region (Province/State), land (navn på norsk + kode); søkeord = sted,
  region, land. Bilder med bare region får region og land (uten GPS), filnavn etter regionen.
  Tidssone: iPhone-bildets, ellers slått opp hos Apple for regionen/landet (med sommertid).

## Matching (dato og sted)
- Stort bilde av det analoge bildet, ved siden av en stripe med iPhone-bilder fra turen sortert på tid
- Klikk på et iPhone-bilde → dato og sted kopieres til det analoge bildet (eller alle valgte)
- «Samme som forrige» med én tast
- Velg flere analoge bilder og gi dem samme dato og sted på én gang
- Filter: vis bare bilder som mangler dato eller sted
- Manuell inntasting når ingen iPhone-bilder passer

## Rekkefølge
- Lista i Bilder er kronologisk: dag for dag, og innen dagen etter klokkeslettet til iPhone-bildet
  dato/sted ble kopiert fra (`time`). Overskrifter for dag og sted (nytt sted når navnet skifter).
- Boka bygges i samme rekkefølge.

## Kart i boka
- Enkelt, litt håndtegnet USA-kart (fastlandet) med ruten så langt og en prikk der vi er.
- Ruten kommer fra iPhone-bildenes GPS i turens periode (lagres i prosjektet, `route`).
- Lite kart på bildesiden, under bildet til høyre. Automatisk på første side i en ny stat;
  kan slås på/av per side.
- Delstatsomriss: Natural Earth 1:50m (allemannseie), forenklet med `tools/make-states.py`
  til `Sources/Fotoalbum/Resources/usa-states.json`.

## Boka
- Standard: Blurb fotobok 10×8 tommer liggende. Andre Blurb-formater skal kunne velges.
- Bildene står i dato-rekkefølge, og jeg kan flytte på dem
- Plassering, font, størrelse osv. for tekst kommer fra mine skisser i Figma.
  Fleksibelt oppsett, ikke låst til én mal.
- Font: Akkurat (AkkuratStd, installert, kan bygges inn i PDF)
- Norsk datoformat, f.eks. «7. okt. 2022»
- Appen lager også omslaget

## Blurb PDF to Book – krav (sjekket 23. okt. 2026)
Kilder: Blurbs «PDF to Book specifications and checklist» (support.blurb.com) og
«PDF to Book Specifications» (blurb.com/make/pdf_to_book/booksize_calculator).
- Mål i punkter. Kuttet er mindre enn navnet tilsier:
  | Format | Kutt (b × h) | PDF-side (b × h) |
  | Standard liggende 10×8 | 684 × 576 | 693 × 594 |
  | Standard stående 8×10 | 576 × 720 | 585 × 738 |
  | Liten kvadratisk 7×7 | 486 × 477 | 495 × 495 |
  | Stor kvadratisk 12×12 | 846 × 846 | 855 × 864 |
  | Stor liggende 13×11 | 900 × 765 | 909 × 783 |
- Utfallende kant 9 pt på topp, bunn og ytterkant, ikke mot ryggen (venstre/høyre side speilvendt)
- Sikker sone 18 pt fra kutt, 45 pt fra ryggen
- Enkeltsider (ikke oppslag), side 1 er høyreside, partall sider, minst 20; over 240 sider
  utelukker noen papirtyper, maks 440–480
- sRGB eller CMYK, tekst i 100 % svart, ingen spotfarger, ingen skjæremerker, maks 300 ppi
- Omslaget er en egen PDF. Vi bruker hard perm med smussomslag: klaff · bakside · rygg · forside · klaff,
  9 pt utfallende kant rundt. Forside/bakside er faste per format (10×8: 716 × 594); ryggen går i trinn
  etter sidetall og papir (`SpineTables.swift`), og klaffene blir smalere når ryggen blir bredere.
  Målt i Blurbs kalkulator 23. okt. 2026; stemmer med kalkulatoren for standard, premium og Mohawk ved 200 sider.
- PDF/X er ikke nevnt i dagens krav

## Milepæler – én av gangen, jeg tester mellom hver
1. Lese inn mappa med skanninger, vise dem i rutenett og stort, skrive dato, sted og beskrivelse.
   Lagres automatisk.
2. iPhone-bildene fra turen side om side, ett-klikks kopiering, «samme som forrige»,
   flere valgte på én gang.
   Stedsnavn fra GPS med riktig lokal dato (tidssone fra stedsoppslaget) og meny med andre navn
   kom med her.
   Søk etter sted og kart over iPhone-bildene kom også med her.
3. Oversiktsvindu (⌘1): fremdrift, dager, steder (gi nytt navn / slå sammen) og kart over de
   analoge bildene; filtre for hva som mangler.
4. Sideoppsett etter Figma-skissene, med forhåndsvisning av oppslag.
5. Eksport av innmat-PDF etter Blurbs krav (Arkiv > Eksporter bok-PDF, ⇧⌘P).
6. Omslag (smussomslag) med riktig rygg og klaffer: bilde på forside og bakside, tittel, kart på
   bakre klaff (Arkiv > Eksporter omslag-PDF, ⌥⇧⌘P).
   Eller «Eget bilde»: appen viser målene (px ved 300 ppi, mm, pt), lagrer en mal (PNG med kutt,
   bretter og sikre soner) til Figma/Photoshop, og lager omslag-PDF-en av ditt bilde eller din PDF.

## Etter v1
- Steder på turen (iPhone-panelet, fanen «Steder på turen»): iPhone-bildenes GPS samlet til steder
  (opphold innen 5 km, besøk innen 8 km slås sammen, like navn slås sammen), navn fra stedsoppslag
  (by/park). «Bruk» gir valgte bilder stedet. Forslag mens du skriver sted; kartpunkt slås opp når du
  er ferdig. Oversikt > Steder kan finne kartpunkt for alle steder som mangler det.
- Bildelikhet («Ligner mest», ⌃1–⌃5): Vision-fingeravtrykk (lokalt) av analoge og iPhone-bilder i
  gråtoner med utjevnet lyshet, lagret i Fotoalbum/Likhet. Testet på syntetiske «filmversjoner»:
  riktig først 26/40, blant fem 35/40. Ekte treffsikkerhet ukjent til brukeren har prøvd.

- Sammenligning (høyreklikk et forslag eller ⌥⌃1–5): iPhone-bildet stort ved siden av det analoge.
  Avstanden vises under hvert forslag (lavere = mer likt; ikke prosent).
- Angre/gjør om (⌘Z/⇧⌘Z) for dato, sted og beskrivelse; i tekstfelt angres skrivingen.
  Endringer innen 1 sekund angres samlet.
- «Usikker» per bilde, med notat; filter «Usikre»; oransje spørsmålstegn i rutenettet.
- Sorter etter likhet: grupper av like analoge bilder (gjennomsnittlig avstand; grensen er en
  andel av alle par, styrt av «Løs–Streng»). «Velg gruppen» velger alle i gruppen.
- Sorter etter rull: skannetid (EXIF) fra filene, ellers filnavn. «På rullen» i bildefeltene foreslår
  dato/sted fra nærmeste bilde med info (innen 6). Bilde > «Fyll inn mellom like bilder på rullen».
- Tekst i bildet (Vision, lokalt): vises i bildefeltene med «Søk sted»; skiltord som «Welcome to»
  fjernes før søket.

- Fokusmodus («Fokus» øverst, ⇧⌘F): bildene som mangler sted eller dato, ett om gangen.
  Sted → Dato → Beskrivelse, ett felt med forslag (↑↓, Enter videre, ⇧Enter tilbake, Esc avslutt).
  Stedsforslag: bildene rundt på rullen og sist brukt (tomt felt), så steder brukt i prosjektet (mest
  brukt først), steder på turen fra iPhone, og søketreff fra Apples stedssøk mens du skriver
  (MKLocalSearchCompleter, USA først; kartpunkt hentes når treffet velges).
  Samme forslagsliste (`rankedPlaceOptions`) brukes i stedsfeltet i Bilder-visningen.
  Datoforslag: dagene med iPhone-bilder innen 15 km fra stedet, bildene rundt, sist brukt; dato kan
  skrives som 14.7 / 14. juli. Venstre: fem like bilder (⌃1–5 fyller inn og går til beskrivelsen).
  Høyre: kart med ruten, stedet og en 100 km-sirkel, og iPhone-bilder innen 100 km, nærmeste først
  (høyst 150; samme dag når dato er satt). Datoforslagene bruker samme radius (`focusRadiusKm`).

- «Jeg vet ikke» (⌘K) i fokusmodus: merker sted/dato som ukjent (`unknownPlace`/`unknownDay`), bildet
  går ut av køen og finnes under filteret «Vet ikke». Settes tilbake når du gir en verdi.
- Prosjekter (Arkiv-menyen og mappeknappen øverst til venstre): nytt (⌘N), åpne, gi nytt navn, lagre
  kopi, ⌘S. Hvert prosjekt er Fotoalbum/Prosjekter/<id>.json; «Gjeldende prosjekt.txt» husker sist
  åpne. Den gamle Prosjekt.json ble lest inn som første prosjekt og ligger urørt.
- iCloud-synk (AppModel+Sync.swift): prosjektfilene ligger i iCloud Drive/Fotoalbum/Prosjekter (første
  gang kopiert fra Application Support, som blir liggende som reserve). Likhet-mellomlageret og «Gjeldende
  prosjekt.txt» er per Mac. Endringer fra en annen Mac lastes inn når appen kommer fram og hvert 5. sekund;
  en ulagret endring her vinner. Skanningsmappa finnes igjen i iCloud Drive/hjemmemappa på en annen Mac,
  ellers «Finn mappa». iPhone-koblinger lagres også som iCloud-ID (`phoneCloudID`) og oversettes til
  den lokale ID-en. Ved testing (FOTOALBUM_BIBLIOTEK) brukes ikke iCloud.

- Område over sted (`area`, f.eks. Blue Ridge Mountains over Sylva). Et område er bildene du har gitt
  det; foreslås fra bildene rundt på rullen og områder brukt innen 100 km. Fokusmodus: Område → Sted
  → Dato → Beskrivelse (naturlig forslag er markert; ⌘K = uten område). Områdeforslag uten sted
  bygger på punktene til bildene rundt og de tre mest like iPhone-bildene.
- Områdeform (`AreaShape`): landskapsregion/delstat = omriss; område du har brukt = sirkel rundt
  bildene (min. 100 km); ellers Apples søk på navnet + 100 km. Når bildet har område: kartet viser
  formen, iPhone-bildene og «Like bilder» er bare innenfor, stedsforslag (brukte/turen) bare
  innenfor, Apple-søket prioriterer området, datoforslag uten sted = dager med iPhone-bilder i området. Bilder-visningen har et
  Område-felt; lista viser område i stedsoverskriftene. Boka: «Bildetekst» = Område · Sted / bare
  område / bare sted. Oversikt > Steder har Områder (nytt navn/slå sammen). (Område er fjernet
  fra eksporten.)
- Områdeforslag fra kartet: geografiske regioner punktet ligger i (Natural Earth 1:10m
  geography_regions, forenklet med `tools/make-regions.py` til `Resources/usa-regions.json`),
  nasjonalpark/-skog fra Apples stedsoppslag (engelsk), og delstaten. Rekkefølge: rullen, brukt i
  nærheten, nasjonalpark, landskap (mest presise først), skog/andre parker, delstat.

## Hovedvinduet (fra 26. okt. 2026)
Hele vinduet er fokusvisningen (FocusView.swift); Bilder- og Bok-visningene er skjult, men koden ligger.
- Midten: bildet, merkelapper øverst (Område · Sted · Dato · Beskrivelse, klikk for å endre),
  glassfelt nederst (Liquid Glass på macOS 26) med ←/→, «Vet ikke» og opptil 5 forslag over feltet.
  Stegene i feltet: Område → Sted → Dato → Beskrivelse (området fra forrige bilde står først og er
  markert; har bildet område, starter det på Sted). Område kan også settes med områdevelgeren.
- Venstre: like iPhone-bilder (innenfor området, ⌃1–5).
- Høyre: områdevelger (blir bildets område og står til neste bilde), datovelger (standard «Alle dager»,
  nullstilles for hvert bilde; i Dato-steget vises den markerte dagen),
  iPhone-bilder derfra med datooverskrifter, kart nederst.
- Nederst: alle bildene i rullrekkefølge; ferdige krysset ut, gjeldende i midten. Klikk = hopp dit.
- Turens datoer står i verktøylinja; iPhone-bildene lastes fra ContentView.
- Sidene følger det som er markert/skrevet i feltet (`focusPreviewArea`, `focusPreviewDay`).
  Områdeforslag når du skriver: brukte områder, landskapsregioner (bare i USA), delstater og
  Apples søk begrenset til nasjonalparker/parker/strender i USA (`areaSearch`). Datoforslag filtreres
  på det du skriver («20», «jul»).

## Region og land (fra 26. okt. 2026)
- Hvert bilde har `regionCode` (ISO 3166-2, «US-NM», «NO-12») og `countryCode` («US»). Fylles fra
  stedets kartpunkt (stedet er fasit); ellers fra Region-steget. Eksisterende bilder fylles ved lasting.
- Grenser: Natural Earth 1:10m admin-0 og admin-1 (hele verden), forenklet med `tools/make-world.py`
  til `Resources/world-countries.json` og `world-regions.json` (World.swift). NB: Norge har gamle fylker.
- Fokus: Region → Sted → Dato → Beskrivelse. Regionen spørres om når bildet mangler sted; forrige
  bildes region står først og er markert. Filteret (region eller «land:XX» = hele landet) styrer like
  bilder, iPhone-bildene til høyre, kartet, stedsforslag og datoforslag.
- Filtrering skjer på regionkode per kartpunkt (`filterMatches`, husket per ~1 km og regnet ut i
  bakgrunnen for iPhone-bildene), ikke på omrisset direkte: det forenklede omrisset kutter kysten,
  og oppslaget bruker nærmeste region innen ~30 km (f.eks. Ruby Beach → Washington). Et punkt hører
  også til regioner/land med grense innen 5 km (`World.filterCodes`), så bilder ved Rio Grande er både
  Texas og Mexico. iPhone-bilder uten GPS låner posisjonen til nærmeste bilde i tid (innen 3 timer).
- Region du velger selv (`regionManual`) vinner over kartpunktet til stedet byttes. Nær grenser
  (flere regioner innen 5 km) sjekkes regionen hos Apples stedsoppslag (AppModel+RegionCheck.swift),
  én om gangen med pause; også for eksisterende bilder ved oppstart.
- Område er tatt ut av fokusvisningen (bare Region og Sted). Eksisterende `area`-verdier ligger i
  dataene, men vises ikke; bildeteksten bruker bare stedet (med mindre «Bildetekst» settes i Bok).

## Steder i nærheten (alternative navn)
- Når bildet har kartpunkt, viser Sted-steget «nå» + steder i nærheten (AppModel+Nearby.swift): Apples
  stedssøk med seks søkeord (national park/monument, conservation area, state park, wilderness, overlook)
  i 60 km-utsnitt, innen 40 km, pluss severdigheten fra stedsoppslaget. Sortert etter type, så avstand;
  støy (besøkssentre, veier, butikker, organisasjoner) filtreres. Velges et, byttes bare navnet –
  kartpunktet fra iPhone-bildet beholdes. Samme forslag i Område-merkelappen. Deles for bilder
  innen ca. 10 km (Apple begrenser antall søk per minutt).

## Ikke i v1
Redigering av bildene (farge, beskjæring utover plassering på siden), andre trykkerier enn Blurb.
