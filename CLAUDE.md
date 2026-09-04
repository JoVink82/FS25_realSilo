# FS25_RealSilo — projectkennis

Mod voor Farming Simulator 25 die boerderijsilo's opdeelt in aparte
compartimenten (vakken), elk voor één product. Auteur: Jo_Vink.

---

## Werkafspraken

- **Antwoord in het Nederlands.**
- **Versienummer nooit ongevraagd ophogen.** Bij een ModHub-inzending
  moet het versienummer blijven staan zoals het is.
- **Changelog** staat in `modDesc.xml`, in de `<description>` per taal
  (EN/NL/DE), nieuwste versie bovenaan. Wijzigingen daar in dezelfde
  stijl toevoegen, in alle drie de talen.
- **Zip-structuur:** bestanden staan in de ROOT van de zip
  (`modDesc.xml`, `scripts/`, `gui/`, `translations/`, `icon_RealSilo.dds`),
  niet in een submap. Inpakken vanuit de mod-map zelf:
  `zip -r FS25_RealSilo.zip . -x ".*"`
- **Altijd valideren voor oplevering:** Lua met `luac5.1 -p` op elk
  script, XML met een parser. Zie "Valkuilen" voor de extra checks die
  hier meermaals nodig bleken.

---

## Architectuur

De mod maakt **nooit eigen Storage-objecten** aan. Een eerdere poging
daartoe corrumpeerde de netwerkstream in multiplayer (Giants'
`onWriteStream` loopt met `ipairs` over `spec.storages`; een afwijkend
aantal brak de stream).

In plaats daarvan houdt de mod een **eigen boekhouding** bij bovenop de
echte Giants-storage: per vak `index`, `fillType`, `fillLevel`,
`capacity`, `isActive`, `storage`, `name`. De echte storage bevat altijd
het WARE totaal; de boekhouding zegt alleen hoe dat verdeeld is.

### Scripts (laadvolgorde uit `modDesc.xml`)

| Bestand | Rol |
|---|---|
| `RealSiloDebug.lua` | Debug-schakelaar. Alle logging loopt via `RealSiloDebug.print()` en is stil tenzij de companion-mod `FS25_RealSilo_Debug` geïnstalleerd is. Detectie via `g_modIsLoaded` / `g_modManager`. |
| `RealSiloUtil.lua` | Silo-herkenning (`isFarmSiloStorage`) en rechten (`canManageSilo` / `canManageSiloLocal`). |
| `realSiloManager.lua` | Silo-registratie, config, transfersysteem. |
| `realSiloCompartmentStorage.lua` | De boekhouding: vakken, save/load, transfer, `captureAndDistribute`. |
| `realSiloStorageHook.lua` | Hooks op de `Storage`-klasse. Het hart van de mod. |
| `realSiloExtensionManager.lua` | Silo-extensions als extra vakken. |
| `realSiloEvents.lua` | Alle multiplayer-events. |
| `RealSiloDialog.lua` | Het GUI-menu (pagina's 1-5). |
| `realSiloActivatable.lua` | Activatable-object. |
| `realSiloHook.lua` | Hooks op PlaceableSilo/PlaceableSiloExtension, save/load, open-toets. |
| `realSiloMoistureCompat.lua`, `realSiloDryerCompat.lua` | Compatibiliteit met FS25_MoistureSystem. |

---

## Valkuilen — hier is herhaaldelijk tijd aan verloren

### 1. `getFillLevel` en `getFillLevels` moeten ALTIJD dezelfde bron gebruiken

Dit is meerdere keren misgegaan. Meldt het enkelvoud iets anders dan het
meervoud, dan krijgt het spel tegenstrijdige informatie en ontstaat er
ping-pong-gedrag: de losbuis stopt niet als de kipper leeg is, of een net
geladen kipper begint meteen weer te lossen.

Gebruik één gedeelde helper waar beide hooks uit putten, en zorg dat de
delta-berekening in `setFillLevel` diezelfde waarde als referentie neemt.

### 2. `LoadingStation:removeFillLevel(self, fillTypeIndex, delta, farmId)`

- **Update 2026-09-04:** geverifieerd tegen de gedecompileerde
  `LoadingStation.lua` uit de huidige game-installatie — de functie heeft
  in deze versie WEL een `farmId`-parameter (3e argument, na `delta`),
  gebruikt om per source-storage `hasFarmAccessToStorage` te checken.
  Dit weerspreekt de oudere aanname hieronder; blijkbaar is dit ergens
  na het optekenen van die valkuil aan de game toegevoegd (of de
  eerdere game-versie week af). Controleer bij twijfel opnieuw tegen de
  actuele gedecompileerde bron in plaats van blind op deze aantekening
  te vertrouwen.
- **Oudere aantekening (mogelijk verouderd):** een eerdere versie ging
  ervan uit dat er GEEN `farmId`-parameter was. Een verkeerde aanname
  hierover schoof toen alle argumenten op; `fillTypeIndex` kreeg de
  hoeveelheid binnen (zichtbaar in het log als `ft=33.23...`). Nu de
  parameter wél bevestigd bestaat, is die eerdere fout waarschijnlijk
  ontstaan doordat de aanroep destijds zonder `farmId` gebeurde op een
  game-versie die de parameter nog niet kende, of door een verkeerde
  argumentvolgorde. Deze functie wordt momenteel nergens in de
  mod-scripts aangeroepen (geen actieve bug), maar mocht hij ooit weer
  gehookt worden: gebruik de 4-argumenten-signature hierboven.
- **De returnwaarde is het NIET-verwijderde restant**, niet het verwijderde
  bedrag. `0` = alles gelukt, ga door. Geef je het verwijderde bedrag terug,
  dan stopt het laden na één stap.
- **De returnwaarde van het origineel is onbruikbaar** om te weten hoeveel
  er echt weg is; meet dat zelf door de echte storage vóór en ná te
  vergelijken.
- De LoadTrigger vult de trailer met de hoeveelheid die hij VRAAGT, niet met
  wat wij afgeven. Geef je minder af, dan ontstaat er graan uit het niets.

### 3. Input / `isSink`

- `isSink="true"` betekent: de toets wordt OPGESLOKT en bereikt het spel
  niet meer. Dit blokkeerde de hogedrukspuit en andere R-acties. Houd
  `isSink="false"`.
- **Standaardtoets is K, niet R.** R is in FS25 de algemene "object
  activeren"-toets (hogedrukspuit, winkels, deuren).
- **Eén globaal action-event, nooit één per silo.** Per-silo registratie
  zorgde ervoor dat op maps met meerdere silo's het menu van de eerste
  silo overal opende en de tweede onbereikbaar werd.
- Het event wordt geregistreerd bij het binnenlopen van de silo-trigger en
  verwijderd bij het verlaten. Registreren bij mission-start of in
  `onFinalizePlacement` is TE VROEG: het event werkt dan niet en verschijnt
  niet in het F1-overzicht.
- Er is een vangnet in de update-loop dat de toets vrijgeeft als de speler
  niet meer in de buurt is, omdat de trigger geen "verlaten" meldt wanneer
  je direct in een voertuig stapt.

### 4. Lua: lokale functies vóór gebruik definiëren

`local function foo()` bestaat niet vóór zijn definitieregel. Dit gaf
meermaals `attempt to call a nil value`. Controleer dit expliciet na elke
wijziging waarbij functies verplaatst of toegevoegd worden.

### 5. Aanroepen van niet-bestaande functies

In een release zat een compleet `RealSiloSlotNameEvent` dat
`RealSiloCompartmentStorage.setSlotName()` aanriep — een functie die nooit
geschreven was. Scan hierop voor je oplevert.

### 6. Multiplayer

- Alle 12 `broadcastEvent`-aanroepen gebruiken `noEventToSelf = true`.
  Op `false` voerde de host zijn eigen broadcast nogmaals uit (dubbele
  meldingen en dubbele uitvoering).
- `RealSiloConfigEvent` heeft een `isServerConfigured`-vlag, zodat clients
  een ongeconfigureerde silo niet ten onrechte als geconfigureerd zien.
- Instellingen wijzigen is **alleen voor de admin** (`getIsMasterUser`).
- `addConsoleCommand` vereist een ECHT object als 4e argument, geen `nil`.

### 7. Mods draaien in aparte Lua-omgevingen

Globale variabelen zijn NIET gedeeld tussen mods. De companion-debugmod kan
dus geen variabele zetten die de hoofdmod leest. Detecteer de andere mod via
`g_modIsLoaded` / `g_modManager`.

### 8. Tekens die FS25 niet rendert

Vermijd `⚠` (U+26A0), `🔒` en `⟳` in vertalingen — die geven renderfouten.
De pijl `→` werkt wel. Let ook op **dubbele l10n-keys**: die geven een
warning en de tweede definitie wint stilzwijgend.

### 9. Silo-herkenning

`isFarmSiloStorage` gebruikt de **FARMSILO-categorie** als enige bron van
waarheid. Maps die eigen graansoorten toevoegen (rye, spelt, triticale,
winterwheat, enz.) zetten die in die categorie, en FS25 voegt ze samen met
de basissoorten. Een eerdere uitsluitlijst-aanpak was fout: die sloot onder
meer SILAGEMAIZE uit. Cache pas als geldig markeren als hij niet leeg is,
anders wordt een te vroege lege lijst vastgezet.

---

## Functionaliteit

- Admin stelt aantal vakken en capaciteit per vak in; alleen het actieve
  vak ontvangt en lost (handmatige modus).
- **Automatisch vak kiezen** (per silo instelbaar): bij lossen gaat een
  vracht naar een vak dat het product al bevat en ruimte heeft, anders naar
  het eerste lege vak. Bij laden wordt het MINST gevulde vak met dat product
  eerst gebruikt. De keuze wordt over ALLE vakken heen gemaakt (hoofdsilo en
  extensions samen); alleen het opslagdeel met het gekozen vak meldt zich
  als beschikbaar, anders bepaalt de volgorde van de opslagdelen het
  resultaat in plaats van de vulgraad.
- **Zoekbereik voor extensions** per silo instelbaar (1–300 m, standaard 50).
  Bij wijziging volgt meteen een herscan.
- Transferfunctie tussen vakken met instelbare snelheid.
- Bestaand graan uit een save van vóór de mod blijft behouden en wordt bij
  de eerste configuratie over de vakken verdeeld (`captureAndDistribute`,
  inclusief extension-storages).
- In een MENU melden de hooks het echte totaal, zodat het financiën-/
  prijzenoverzicht de hele silo toont in plaats van alleen het actieve vak.

---

## Testen

Zonder de companion-mod logt de mod niets. Voor diagnose:
installeer `FS25_RealSilo_Debug` ernaast (losse zip, met eigen
`iconFilename` — zonder icon weigert FS25 de mod te laden).

Bij problemen met laden/lossen is het log leidend: kijk welke functies het
spel daadwerkelijk aanroept voordat je een hook kiest. Zo bleek dat de
LoadTrigger alleen `getSupportedFillTypes` en `removeFillLevel` gebruikt —
niet `getAllFillLevels`, waar eerder vergeefs op gehookt was.
