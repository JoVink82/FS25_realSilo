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
  niet in een submap. Inpakken vanuit de mod-map zelf, met `.git/`,
  `screenshots/` en alle `.md`-bestanden (README's, CLAUDE.md) uitgesloten
  -- die horen niet in de op te leveren zip:
  `zip -r FS25_RealSilo.zip . -x ".*" -x ".git/*" -x "screenshots/*" -x "*.md"`
  Controleer met `unzip -l` dat er geen `.md`-bestanden in de output staan.
- **Testversies:** bij een testreeks een letter-suffix gebruiken
  (`1.2.0.8a`, dan `b`, `c`, ...). Bij ELKE opgeleverde update binnen zo'n
  reeks de letter ophogen, ook als de vorige letter nog niet getest is --
  nooit dezelfde letter twee keer opleveren.
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

### 10. Netwerk-events van EEN ANDERE mod's GUI werken niet voor proxy's (dedicated server)

Gemeld: "droger van MoistureSystem start niet op een dedicated server" (werkte
wel in singleplayer). Oorzaak zat niet in realSilo's eigen events, maar in
hoe FS25_MoistureSystem's **eigen** GUI-knop (`MoistureGuiDrying:onClickToggleDrying`,
zie `FS25_MoistureSystem/src/gui/MoistureGuiDrying.lua`) op een client werkt:
die stuurt een `DryingToggleEvent` met `NetworkUtil.getObjectId(placeable)`.
Onze vak-proxy's (zie realSiloDryerCompat.lua) zijn geen echte, genetwerkte
objecten -- `NetworkUtil.getObjectId(proxy)` geeft `nil`, dus de knop stuurde
op een client stilzwijgend HELEMAAL NIETS naar de server. Werkte alleen als
host/server (bij singleplayer altijd het geval, dus daar nooit opgevallen).
Op een dedicated server is ELKE speler een client -- vandaar dat het daar
nooit werkte, voor niemand.

**Eerste (foute) poging:** de instance-methode van de ANDERE mod's
GUI-controller patchen. MoistureGuiDrying is een bare global uit
MoistureSystem's eigen Lua-omgeving (net als CropValueMap, zie punt 7) en dus
niet direct bereikbaar -- maar de GELADEN GUI-FRAME-instance is dat wel:
`Gui:loadGui(..., isFrame=true)` bewaart 'm in `g_gui.frames["<naam>"].target`
(`g_gui` is een gewone gedeelde engine-global, `self.target = controller`
staat in `GuiElement.new`). Dat is dus een DERDE manier om een instance van
een andere mod te bereiken, naast de twee die al bekend waren:
  - via `g_currentMission.<veld>` (zoals `g_currentMission.dryingSystem` voor
    DryingSystem, zie punt 7/v14c in realSiloDryerCompat.lua)
  - via `g_gui.frames["<GuiNaam>"].target` (voor een GUI-controller die als
    frame geladen is -- `isFrame=true` in de `loadGui`-aanroep van de andere
    mod, te verifieren in diens eigen bron)

Idee was: `instance.onClickToggleDrying = eigenFunctie` zetten (zelfde "patch
de instance, niet de klasse"-truc als voor DryingSystem). **Dit bleek NIET te
werken** -- pas ontdekt na een hele testronde op de dedicated server, waarbij
zelfs de allereerste, onvoorwaardelijke debug-regel in de gepatchte functie
NOOOIT verscheen in het log. De knop reageerde dus zichtbaar (niet
uitgeschakeld, klik werd geregistreerd) maar deed niets.

**Echte oorzaak:** een GUI-knop roept zijn click-callback niet op via een
verse `instance:methode()`-aanroep, maar via een VELD dat GIANTS eenmalig
vult bij het laden van de XML. Zie `GuiElement:addCallback` in
`dataS/scripts/gui/elements/GuiElement.lua`:
```lua
self[funcName] = self.target[callbackName]   -- self.onClickCallback = self.target["onClickToggleDrying"]
```
Dit is een KOPIE van de functie-WAARDE zoals die was op het moment dat
MoistureSystem zijn GUI opbouwde -- ver voordat onze installer (die pas via
de update-loop draait) een kans kreeg om te patchen. Onze latere
`instance.onClickToggleDrying = ...` verandert een veld dat de knop allang
niet meer raadpleegt: `button.onClickCallback` wijst nog altijd naar de
OORSPRONKELIJKE functie. Dat die oorspronkelijke functie op een host/server
toch "werkte": hij heeft zelf al een tak `if g_currentMission:getIsServer()
then g_currentMission.dryingSystem:toggleDrying(placeable) end` die geen
netwerk-object-id nodig heeft -- dus singleplayer werkte altijd toevallig
goed, met of zonder onze patch. Alleen de client-tak (met
`NetworkUtil.getObjectId`) was ooit kapot, en die tak werd nooit bereikt via
onze aanpassing.

**Werkende fix:** niet de instance-methode patchen, maar het VELD zelf op de
knop-ELEMENT overschrijven: `instance.btnToggleDrying.onClickCallback = ...`.
Dat veld wordt bij elke klik gewoon opnieuw gelezen (`self.onClickCallback(...)`),
dus een late herschrijving komt wel aan, ongeacht wanneer de installer draait.
**Les voor het vervolg: bij het patchen van GUI-gedrag van een andere mod
altijd controleren of de aanroep via een directe methode-aanroep loopt (dan
volstaat een instance-patch) of via een `addCallback`-gebonden knop/element
(dan moet het `onClickCallback`/`onXxxCallback`-VELD op het element zelf
gepatcht worden, niet de instance-methode).**

De eigenlijke logica blijft ongewijzigd: voor onze eigen vak-proxy's loopt de
aanroep via realSilo's EIGEN event (`RealSiloDryerToggleEvent` in
realSiloEvents.lua), dat het vak identificeert via silo-uid + vakindex
(gewone waarden) in plaats van een netwerk-object-id, en op de server gewoon
`DryingSystem:toggleDrying()` / `:setDryingState()` aanroept -- die kijken
zelf toch alleen naar `placeable.uniqueId` (een string), dus onze
synthetische `"<uid>#vak<N>"`-sleutel werkt daar prima. Voor elke andere
(echte) placeable blijft het origineel ongewijzigd (via de bewaarde
`originalCallback`).

**Valkuil bij zo'n installer -- en de FOUTE eerste oplossing ervoor:** als de
"klaar"-vlag pas true wordt zodra OOK deze GUI-patch gelukt is, en de patch
controleert op iets dat op een dedicated server-proces nooit bestaat (hier:
`g_gui.frames[...]`/het knop-element, want een dedicated server heeft geen
GUI) -- dan loopt de installatie-retry (1x per frame) voor altijd door,
exact dezelfde val als punt 2/v14b hierboven al eens beschreef voor
"MoistureSystem niet aanwezig".

Eerste oplossing was een pogingen-cap: na ~3000 pogingen "opgeven"
(as-if-succeeded) zodat de hoofd-klaar-vlag niet voor altijd geblokkeerd
blijft. **Ook dit bleek fout** (live-test, 2026-09-06): de aanname "op een
echte client staat de knop allang klaar bij spelstart" klopte niet. Het
knop-element bestaat pas nadat de speler het menu voor het eerst zelf
geopend heeft, en dat duurde in de praktijk langer dan 3000 pogingen. Zodra
de cap voorbij was, gaf de patch voorgoed op EN werd de hele installatie als
compleet gemarkeerd (de update-loop-hook stopt zichzelf dan) -- dus ook nadat
de speler het menu daarna alsnog opende, gebeurde er bij een klik niets meer,
de rest van die sessie. Zichtbaar in het log als een reeks
"nog niet compleet | ... dryerToggleKnop=false"-regels die nooit "true"
worden, gevolgd door een klik die volledig genegeerd wordt.

**Juiste oplossing voor de cap:** geen pogingen-cap, maar het ECHTE
onderscheid maken. `g_client == nil` is waar op een zuiver headless
dedicated server-proces (geen lokale speler) en NOOIT waar op een client --
ook niet op de host van een listen-server, die immers ook zelf meespeelt.
Op een dedicated server meteen als voldaan beschouwen (er komt daar toch
nooit een GUI); op elke andere client onbeperkt blijven proberen (1x per
frame, goedkope lookup) tot het menu voor het eerst geopend wordt, hoe lang
dat ook duurt -- zelfde "geen harde limiet, blijft proberen tot het
lukt"-filosofie als de dryingSystem-aanwezigheidscheck hierboven. **Les: een
aanname over "hoelang iets duurt op een normale client" onderbouwen met een
echte boolean-check (hier `g_client == nil`) in plaats van met een
pogingen-cap/timeout -- zeker als het misgaan ervan een silent, permanente
black-out betekent voor de rest van de sessie.**

**En toen bleek de knop-patch zelf OOK nog fout (2026-09-06, derde ronde):**
met de cap opgelost bleef `dryerToggleKnop=false` gewoon voor altijd `false`
op een echte client -- geen timing-probleem meer, een structureel probleem.
Een diagnostische dump (alle keys in `g_gui.frames` + alle velden met
"btn"/"toggle" in de naam op de instance) loste het in één keer op:
`instance.btnToggleDrying` bestond gewoon niet ("=nil"). Verklaring, uit
`MoistureGuiDrying:initialize()` (FS25_MoistureSystem/src/gui/MoistureGuiDrying.lua):
```lua
self.btnToggleDrying = {
    inputAction = InputAction.MENU_ACTIVATE,
    text = g_i18n:getText("ms_action_startDrying"),
    callback = function() self:onClickToggleDrying() end,
    disabled = true,
}
self:setMenuButtonInfo({ self.btnBack, self.btnToggleDrying })
```
`btnToggleDrying` is dus **helemaal geen GuiElement/ButtonElement** --
het is een gewone Lua-tabel voor FS25's "menu button info"-balk (de
SPACE-hint onderin het scherm bij ingame-menu-tabs). Twee gevolgen:
  1. Er is geen `.onClickCallback`-veld (dat bestaat alleen op een echte
     knop-GuiElement, zie de EERSTE, ook al foute versie van deze patch
     hierboven). Het veld dat bij een druk op SPACE echt aangeroepen wordt,
     heet `.callback`, en de aanroep gebeurt zonder argumenten (de closure
     vangt `self` af in plaats van 'm als parameter te krijgen) -- dus de
     patch moet ook een functie ZONDER parameters zijn die de vastgelegde
     `instance` uit de closure gebruikt, niet een `target`-parameter.
  2. Deze tabel wordt pas aangemaakt in `:initialize()`, en dat draait
     kennelijk pas zodra de speler het tabblad voor het eerst zelf opent
     -- niet meteen bij het laden van de GUI (in tegenstelling tot wat de
     naam en de rest van FS25's GUI-laadpad (`Gui:loadGui` roept
     `exposeControlsAsFields`/`onGuiSetupFinished` wel synchroon aan) zou
     doen vermoeden). Vandaar dat de cap-fix hierboven WEL nodig was, ook
     al was de eigenlijke patch daarna nog fout.

**Les: bij zo'n patch niet afgaan op de VELDNAAM zoals die in eigen code
gebruikt wordt (`self.btnToggleDrying` "klinkt als" een knop), maar met een
diagnostische dump (`pairs(instance)`, keys loggen) verifiëren wat het
object ECHT is voordat je aanneemt hoe het aangeroepen wordt. Dat had twee
mislukte rondes gescheeld.**

**En toen bleek `g_client == nil` ZELF ook geen betrouwbare "dit is een
headless dedicated server"-check (nog dezelfde dag, live-test op een echte
GPORTAL-dedicated-server via diens webgebaseerde logviewer): daar bestaat
`g_client` gewoon, ook al zit er natuurlijk nooit iemand fysiek voor dat
serverproces om een menu te openen. Het gevolg was onschuldig (de knoppatch
bleef daar gewoon netjes onbeperkt proberen, precies zoals bedoeld voor een
"gewone client die het menu nog niet geopend heeft"), maar de hele
"detecteer of dit een dedicated server is"-exercise bleek achteraf
overbodig: een mislukte poging van installToggleGuiPatch() is een handvol
goedkope tabel-lookups, zonder state-opbouw -- er is dus geen enkele reden
om daar ooit mee te stoppen, op WELK proces dan ook. **Definitieve,
vereenvoudigde oplossing: geen pogingen-cap, geen omgevingsdetectie, gewoon
altijd `installToggleGuiPatch()` blijven proberen.** Lukt het (speler opent
het menu) dan is het klaar; lukt het nooit (headless server, of gewoon geen
speler die dit menu ooit opent) dan blijft het onschadelijk op de
achtergrond proberen voor de rest van de sessie (zonder logregels).
**Bredere les: als een "geef op na X
pogingen"-vangnet nodig lijkt, eerst checken of de mislukte poging zelf wel
daadwerkelijk schade aanricht (CPU, geheugen, groeiende state, logspam in
productie) -- zo niet, dan is "gewoon oneindig blijven proberen" vaak
simpeler EN robuuster dan elke vorm van cap of omgevingsdetectie, die zelf
weer een nieuwe (foute) aanname kan blijken te zijn.**

**En daarna bleek het pollen zelf (1x per frame checken "bestaat
instance.btnToggleDrying al?") in de praktijk over meerdere live-testsessies
heen gewoon niet binnen enkele minuten raak te schieten -- zonder dat
duidelijk was WANNEER :initialize() (de methode die deze tabel aanmaakt,
zie hierboven) uberhaupt draait. In plaats van te blijven wachten en hopen:
**instance:initialize() zelf hooken**, exact dezelfde "patch de instance"
-techniek als bij onClickToggleDrying/DryingSystem, maar dan op de methode
die de knop-tabel PRODUCEERT in plaats van op de tabel zelf te pollen. Zodra
de instance uberhaupt bestaat (heel vroeg, ruim voor initialize() zelf
draait), hangen we onze eigen wrapper om instance.initialize: die roept
eerst het origineel aan (zodat self.btnToggleDrying gewoon aangemaakt
wordt zoals MoistureSystem het bedoeld heeft) en patcht DAARNA meteen
`self.btnToggleDrying.callback`. Geen polling, geen timing-giswerk, geen
vraag meer over "hoe lang duurt dit" -- onze code draait exact op het
moment dat het moet, wanneer dat ook is. **Les: als een waarde pas na een
niet-deterministische, niet te voorspellen gebeurtenis beschikbaar komt,
hook dan de methode die 'm AANMAAKT in plaats van te pollen op het
resultaat -- dat is zowel sneller als zonder timing-aannames.**

**En toen bleek zelfs DIE hook nooit te vuren -- ook niet nadat de speler
het menu (met SHIFT+M) daadwerkelijk geopend en gebruikt had. De ECHTE
oorzaak, eindelijk gevonden via GIANTS' eigen `Gui:resolveFrameReference`
(dataS/scripts/gui/base/Gui.lua): `g_gui.frames["MoistureGuiDrying"].target`
is HELEMAAL NIET de instance waar de speler mee interacteert.**

Het SHIFT+M-venster (`MoistureGui`, een `TabbedMenu`) laadt zijn Drying-pagina
niet rechtstreeks, maar via een `<FrameReference ref="MoistureGuiDrying" .../>`-
element in `MoistureGui.xml`. GIANTS' eigen resolutielogica voor zo'n
FrameReference is expliciet gedocumenteerd in de broncode: "the registered
frame is cloned and returned" -- de al-geregistreerde `MoistureGuiDrying`-
controller uit `g_gui.frames` wordt GEKLOOND (`frameController:clone(...)`),
en die KLOON wordt toegewezen aan `moistureGui.pageDrying`. `MoistureGui:
onGuiSetupFinished()` roept vervolgens `self.pageDrying:initialize()` aan op
DIE kloon -- nooit op het origineel in `g_gui.frames`. Elke patch die wij tot
dan toe op `g_gui.frames["MoistureGuiDrying"].target` zetten (instance-methode,
knop-tabel, of zelfs een hook op `:initialize()` zelf) werkte dus op een
object waar de speler NOOIT mee interacteert. Vandaar dat `btnToggleDrying`
op dat object voor altijd `nil` bleef en onze `initialize()`-hook nooit
"aangeroepen" logde, ook niet nadat de speler het menu al lang gebruikt had.

**Juiste pad naar de echte, live instance:**
`g_currentMission.MoistureSystem.moistureGui.pageDrying` --
  - `g_currentMission.MoistureSystem` is een gewone gedeelde engine-global
    (main.lua: `g_currentMission.MoistureSystem = self`), net als
    `g_currentMission.dryingSystem`;
  - `.moistureGui` is het SHIFT+M-scherm zelf (main.lua:
    `self.moistureGui = MoistureGui:new(...)`);
  - `.pageDrying` is de kloon, toegewezen door `resolveFrameReference` zodra
    `MoistureGui.xml` geladen wordt -- in dezelfde synchrone `Gui:loadGui`-
    aanroep die daarna ook meteen `onGuiSetupFinished()` (en dus
    `:initialize()`) aanroept. Tegen de tijd dat dit pad een niet-nil
    instance teruggeeft, heeft `:initialize()` dus AL gedraaid en bestaat
    `btnToggleDrying` al -- geen aparte `initialize()`-hook meer nodig,
    gewoon proberen en bij falen laten herhalen (geen cap, zelfde
    filosofie als overal in dit bestand).

**Bredere les, de belangrijkste van deze hele saga: bij een `<FrameReference>`
in GIANTS' GUI-XML (te herkennen aan `ref="..."` dat naar een AL elders
geladen frame verwijst) is `g_gui.frames["<Naam>"].target` het ORIGINEEL,
niet per se de instance die de speler te zien krijgt -- GIANTS kloont het bij
resolutie. Zoek in zo'n geval de plek waar de klonende ouder-instance zelf
opgeslagen wordt (hier: `g_currentMission.MoistureSystem.moistureGui`) en
lees de kloon van DAARUIT (`.pageDrying`), niet via `g_gui.frames` van de
gerefereerde naam.**

**En toen bleek de toggle-knop op de dedicated server eindelijk te werken
(bevestigd via live-test: `onClickToggleDrying`-DIAG-regels verschenen nu wél
in het clientlog, het event kwam aan bij de server), maar meldde de speler
alsnog: "drogen kan geactiveerd worden maar het product wordt niet droger".
DEZELFDE beperking bleek nog een tweede keer toe te slaan, ditmaal niet in de
knop maar in de daadwerkelijke uur-tick-verlaging zelf.**

FS25_MoistureSystem's `DryingSystem:drySilo()` (aangeroepen vanuit
`onHourChanged`, alleen op de server) verlaagt `ms.objectInfo[placeable
.uniqueId][fillTypeName].moisture` heel gewoon in een gedeelde Lua-tabel --
dat werkt voor onze vak-proxy net zo goed als voor een echte placeable. Maar
`drySilo()` stuurt dat resultaat daarna alleen door naar clients met:

```lua
local objectId = NetworkUtil.getObjectId(placeable)
if objectId ~= nil then
    g_server:broadcastEvent(ObjectMoistureResponseEvent.new(objectId, ms.objectInfo[placeable.uniqueId]))
end
```

Onze vak-proxy is geen echt, genetwerkt object -- exact dezelfde beperking
als bij de toggle-knop (zie hierboven): `NetworkUtil.getObjectId(proxy)`
geeft ALTIJD `nil`, dus deze broadcast wordt voor onze vakken stilzwijgend
altijd overgeslagen. Resultaat: de server droogde intern prima door (elk uur
minder vocht in zijn EIGEN `ms.objectInfo`), maar een CLIENT kreeg dat nooit
te zien -- diens eigen `ms.objectInfo`-kopie voor dat vak bleef voor altijd op
de allereerste (ongedroogde) waarde staan, en dus ook `slot.moisture` (die in
`ensureVirtualSeeded` alleen wordt bijgewerkt VANUIT `ms.objectInfo`, nooit
andersom, zodra de synthetische sleutel eenmaal bestaat).

**Fix: geen nieuw event nodig.** `realSiloEvents.lua` had al een beproefd,
silo-uid+index-gebaseerd sync-kanaal (`RealSiloSlotSyncEvent` /
`RealSiloEvents.broadcastSlotSync`, van oorsprong gebouwd voor "stuur de
vulling opnieuw na een transfer"). In `realSiloDryerCompat.lua`'s
`installDrySiloSafetyNet`-wrapper lezen we na elke succesvolle
`drySilo`-aanroep voor een vak-proxy de zojuist bijgewerkte
`ms.objectInfo`-waarde terug, zetten die in `RealSiloCompartmentStorage`, en
roepen (alleen als er ook echt iets veranderd is) `RealSiloEvents
.broadcastSlotSync(uid)` aan -- precies hetzelfde kanaal dat al werkte voor
transfers, nu ook gebruikt voor droog-updates.

**Bredere les nummer twee: `NetworkUtil.getObjectId(proxy) == nil` is geen
eenmalige uitzondering die je op één plek (de knop) hoeft te omzeilen --
ELKE plek in een externe mod die intern naar deze functie terugvalt om iets
naar clients te sturen, slaat voor een niet-genetwerkte proxy stilzwijgend
over. Bij het compatibel maken van zo'n proxy met een andere mod: zoek niet
alleen de invoerkant (de knop die een actie triggert) maar ook elke
UITVOERkant die periodiek resultaten terugstuurt (hier: de uur-tick), en
controleer die apart op dezelfde aanname.**

**En toen bleek zelfs DIE fix niet genoeg: live-test (2026-09-06, ingame-tijd
versneld, ~5 uur gewacht) liet in het serverlog keurig vier
`[realSilo][DIAG] moisture-sync: ... (broadcast naar clients)`-regels zien
(0.180 -> 0.166 -> 0.152 -> 0.138 -> 0.130, exact de idealMax van tarwe) --
de server droogde dus onmiskenbaar correct EN de broadcast vuurde. Toch bleef
het percentage in de speler's Grain Drying-menu ongewijzigd.**

Oorzaak: de vorige fix schreef de gedroogde waarde alleen terug in
`RealSiloCompartmentStorage` (`slot.moisture`/`slot.quality`, via het
bestaande `RealSiloSlotSyncEvent`-kanaal) -- maar het Grain Drying-menu leest
zijn percentage helemaal niet uit `slot.moisture`. Het roept
`ms:getObjectInfo(proxy.uniqueId, fillTypeIndex)` aan (in
`DryingSystem:getSiloCropStatus`, FS25_MoistureSystem's eigen bron), dus uit
`ms.objectInfo[virtualId][fillTypeName]`. En `ensureVirtualSeeded` (verderop
in `realSiloDryerCompat.lua`) doet, zodra die synthetische sleutel eenmaal
bestaat, precies het OMGEKEERDE van wat je hier nodig hebt: het behandelt
`ms.objectInfo` als leidend en overschrijft `slot.moisture` DAARMEE zodra ze
verschillen (bedoeld voor het geval drogen zelf, in de client se eigen
proces, al een wijziging in `ms.objectInfo` had aangebracht). Op een CLIENT
bleef `ms.objectInfo[virtualId]` na de allereerste keer seeden voor altijd
op die oorspronkelijke (ongedroogde) waarde staan -- dus zette de
eerstvolgende menu-ververing (draait ~1x/sec zolang het menu open staat) de
zojuist door `RealSiloSlotSyncEvent` binnengekomen, correcte
`slot.moisture` domweg meteen terug naar de oude waarde. Vandaar dat de
broadcast wel aantoonbaar aankwam, maar het menu alsnog nooit veranderde.

**Fix:** `RealSiloDryerCompat.syncVirtualMoistureFromSlot(uid, slotIndex)`
toegevoegd, die `ms.objectInfo[virtualId][fillTypeName]` rechtstreeks
gelijktrekt met de huidige `slot.moisture`/`slot.quality`. Aangeroepen vanuit
`RealSiloSlotSyncEvent:run` (in `realSiloEvents.lua`) direct nadat een
inkomende slot-sync `slot.moisture`/`slot.quality` bijwerkt -- dus bij ELKE
slot-sync, niet alleen na drogen (transfers gebruiken hetzelfde kanaal), zodat
er nooit meer een stale `ms.objectInfo`-waarde kan overblijven die een latere
menu-ververing terug kan laten veren.

**Bredere les nummer drie: een fix die aantoonbaar "aan de bron" werkt (hier:
de server berekent en verstuurt de juiste waarde) is nog geen bewijs dat de
UI ook klopt. Zoek bij twijfel expliciet op WELK veld de weergave-laag
daadwerkelijk leest (hier: `ms.objectInfo`, niet `slot.moisture`) voor je een
sync-fix als compleet beschouwt -- en let op bestaande code die diezelfde
waarde elders periodiek in de omgekeerde richting synchroniseert
(`ensureVirtualSeeded`'s "existing wint van slot"-tak), want die kan een
zojuist gefixte sync stilletjes weer ongedaan maken.**

### 11. Booleans die van "onschadelijk/legacy" naar "actief gehandhaafd" gaan: check de DEFAULT opnieuw

`realSiloManager.hasDryer(uid)` bestond al lang (save/load/XML-plumbing
compleet) maar werd nergens gelezen -- README_modders.md noemde het zelfs
expliciet "Legacy, no longer functional". Bij het alsnog handhaven ervan
(v2.0.0.0, `installOwnedDryablesSplit` in realSiloDryerCompat.lua) bleek de
opgeslagen/geladen default `false` te zijn (`(getXMLInt(...) or 0) == 1`) --
onschadelijk zolang niemand ernaar keek, maar zodra de vlag ineens bepaalt
of een silo in het Grain Drying-menu verschijnt, zou ELKE bestaande silo en
savegame (zonder dit attribuut) in één klap zijn droogfunctie verliezen.
Fix: bij het ontbreken van het attribuut (savegame van vóór deze instelling)
expliciet `true` aannemen, niet `false`; alleen een aanwezig 0/1-attribuut
is de door de speler gekozen waarde. **Les: voor je een tot dusver ongebruikte
boolean-vlag alsnog gaat handhaven, controleer expliciet wat de bestaande
default oplevert voor data die dateert van vóór de vlag ooit gebruikt werd --
"legacy/onschadelijk" en "veilige default zodra hij wel gelezen wordt" zijn
twee verschillende dingen.**

Tweede randgeval bij dezelfde feature: de droger UITzetten terwijl een vak
al aan het drogen is, laat de silo verdwijnen uit `getOwnedDryables` (dus
onzichtbaar in het menu) maar `DryingSystem.activeDryers` (een simpele,
per-machine Lua-set, zie punt 10 hierboven) bleef zonder extra actie stiekem
AAN staan. Fix: `RealSiloDryerCompat.stopAllDryingForSilo(uid)`, aangeroepen
vanuit `RealSiloConfigEvent.apply` zodra `hasDryer` van true naar false gaat,
zet elk drogend vak van die silo expliciet stil en broadcast dat resultaat
(zelfde `RealSiloDryerToggleEvent`-kanaal als een gewone toggle-klik).

### 12. Native BinaryOption/MultiTextOption: size-override breekt het widget, en lange infotekst heeft een eigen, brede label nodig

Twee losse, in-game gemelde problemen na de omschakeling naar
`fs25_binaryOption`/`fs25_multiTextOption` (zie punt 9 hierboven), allebei
in v2.0.0.0 opgelost:

**Uitlijning/overloop van rowToggle/rowStepper.** De eerste versie zette
zelf `with="anchorTopLeft" position="305px -10px" size="230px 40px"` op de
`BinaryOption`/`MultiTextOption`-elementen. Deze widgets gebruiken echter
`autoAddDefaultElements` en bouwen hun eigen knoppen/slider op basis van
hun EIGEN, vaste basismaat (`fs25_binaryOption` = 276x32px,
`fs25_multiTextOption` = 280x36px). Een kleinere size opdringen knijpt de
buitenkant van het widget, niet de interne knop-layout -- dat gaf precies
het gemelde "aan de rechterkant afgekapt/lijkt over de rand te lopen"
beeld. **Fix:** gebruik i.p.v. de kale profielen de door Giants zelf
gebruikte "instellingenrij"-varianten `fs25_settingsBinaryOption` /
`fs25_settingsMultiTextOption` (`sdk/xmlDoku/guiProfiles.xml`,
`with="anchorMiddleRight"`, eigen vaste `position`) helemaal zonder eigen
`with`/`position`/`size`-override -- die ankeren zichzelf keurig tegen de
rechterrand van de rij, exact zoals FS25's eigen instellingenmenu. Om alle
rijtypes visueel in dezelfde kolom te laten vallen is `rowInput` (het
gewone tekstveld) + zijn achtergrond (`realSiloConfigInputBg`) om dezelfde
reden omgezet naar `with="anchorTopRight" position="-15px -10px"`
(vaste breedte 260px) i.p.v. de oude vaste linkerpositie op x=305px.

**Afgekapte infotekst ("...") op ROW_INFO/ROW_CALC.** `rowLabel`
(`realSiloConfigRowLabel`-profiel, 290px breed) werd hergebruikt voor
zowel korte veldlabels als lange volzinnen ("This silo contains
product. Empty it first...", "4 silos x 200,000 l each (total: ...")
zonder `textMaxNumLines` -- FS25 kapt een `Text`-element zonder die
attribuut standaard af op een regel. **Fix:** een los, breed label
(`rowLabelWide`, profiel `realSiloConfigRowLabelWide`, ~700px,
`textMaxNumLines=2`) toegevoegd als extra, standaard verborgen kind in
dezelfde gedeelde `configRowInput`-template (zelfde patroon als
`rowToggle`/`rowStepper`, punt 9). `populateConfigCell` gebruikt nu
`labelWideEl` voor `ROW_INFO`/`ROW_CALC` en de smalle `labelEl` voor
`ROW_INPUT`/`ROW_TOGGLE`.

### 13. Drogen-pagina had geen zichtbare "hoe activeer ik dit"-hint

De Drogen-pagina (pagina 6) is alleen via de G-toets bereikbaar (geen
ruimte voor een 4e voetknop, zie eerder in dit bestand) en
`g_inputBinding:setActionEventText()` verschijnt alleen in het
F1-wereld-overzicht, dat niet zichtbaar is terwijl dit GUI-dialoogvenster
open staat. Speler meldde: geen enkele manier gevonden om de droger te
activeren. **Fix:** een expliciete hint-rij (`realSilo_dryerActivateHint`,
nieuwe l10n-key, alle 3 talen) toegevoegd onderaan de Instellingen-pagina
(`buildConfigRows`), maar ALLEEN wanneer `hasDryerVal == true` EN
`g_currentMission.MoistureSystem` bestaat -- anders zou de hint verwarrend
zijn voor silo's zonder droger of zonder FS25_MoistureSystem.

### 14. "Silo - Silo 1" als titel is GEEN bug

Gemeld als onleesbaar/verkeerd scherm, maar `getDisplayName(uid)` en het
default-naamsysteem werken hier correct: een silo die nog geen eigen naam
gekregen heeft, heet gewoon "Silo" (de default, zie
`RealSiloUtil.resolveDisplayName(..., "realSilo_defaultName", "Silo")` in
`realSiloHook.lua`). De titel `"%s - %s %d"` (displayName, "Silo", vaknr)
geeft dan toevallig "Silo - Silo 1" -- verwarrend qua herhaling, maar
functioneel juist. Het achterliggende leesbaarheidsprobleem op die pagina
(afgekapte infotekst) is wel echt en valt onder punt 12 hierboven.

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
- **Wel of geen droger** (per silo instelbaar, sinds v2.0.0.0): staat uit,
  dan verschijnen de vakken van die silo helemaal niet in FS25_MoistureSystem's
  Grain Drying-menu (`realSiloManager.hasDryer(uid)`, gehandhaafd in
  `realSiloDryerCompat.lua`'s `installOwnedDryablesSplit`). Standaard AAN
  (bestaande silo's/savegames blijven drogen zoals voorheen). Kan ook
  permanent vastgelegd worden door de map-/silomodel-XML (`dryer`-attribuut),
  dan is de instelling read-only in de dialoog (`config.dryerXmlFixed`).
- **Eigen "Drogen"-pagina in het realSilo-menu** (sinds v2.0.0.0, pagina 6,
  `RealSiloDialog:buildDryerRows`): lijst van alle vakken van deze silo
  (hoofdsilo + extensions) die op dit moment product bevatten, elk met een
  AAN/UIT-knop. Klikken past DIRECT toe (`RealSiloEvents.sendDryerToggle`,
  geen aparte "Opslaan"-stap zoals de andere config-pagina's — zie
  `ROW_TOGGLE`'s `immediate`/`onToggle`-velden, toegepast vanuit
  `onClickConfigToggle`). Bereikbaar via de G-toets (`REALSILO_DRYER`,
  geregistreerd in `onOpen`, net als de T-toets voor Transfer) — GEEN eigen
  footer-knop, want de 3 bestaande knoppen vullen de knoppenbalk al precies
  600px (zie de knoppen-XML onderaan `RealSiloDialog.xml`). Rechten:
  iedereen die de silo mag gebruiken, niet alleen de admin
  (`RealSiloUtil.canToggleSiloDryer`, dagelijks gebruik, geen instelling) —
  zelfde functie die ook FS25_MoistureSystem's eigen Shift+M Grain
  Drying-knop gebruikt.
- **Visuele AAN/UIT-stijl (`ROW_TOGGLE`) — natieve `BinaryOption`, niet
  zelfgetekend**: eerste versie (nog binnen dezelfde v2.0.0.0-sessie)
  tekende dit zelf als twee gekleurde vakken naast elkaar. Ontdekt via de
  meegeleverde `EasyDevControlsPlayerFrame.xml` (companion-mod van de
  gebruiker) dat FS25 hiervoor een ECHT native GUI-element heeft:
  `<BinaryOption profile="fs25_binaryOption">`
  (`BinaryOptionElement.lua`, uitbreiding van `MultiTextOptionElement`,
  zie `sdk/debugger/gameSource.zip`), met een kant-en-klaar profiel
  `fs25_binaryOption` in `sdk/xmlDoku/guiProfiles.xml` dat exact het
  OFF/ON-schuifknopje van het spel se eigen instellingenmenu tekent
  (bestaande spel-afbeeldingen, geen eigen artwork nodig). Nu gebruikt in
  plaats van het zelfgebouwde twee-vakken-ontwerp: één
  `<BinaryOption .../>` (`name="rowToggle"`) als extra, altijd-aanwezig
  kind-element in het ene gedeelde `configRowInput`-celtype (nog steeds
  ÉÉN uniform celtype, verplicht — zie SmoothList-pool-waarschuwing
  hierboven). `populateConfigCell` zet 'm zichtbaar/onzichtbaar per
  rijtype en synct de stand met `:setIsChecked(waarde, true)`
  (`skipAnimation=true`, geen `forceEvent` zodat dit geen loze klik
  veroorzaakt). Gebruikt door zowel de per-silo "Droger beschikbaar"-rij
  (pagina 2) als elke rij op de Drogen-pagina (6). De 3 eerder
  zelfgemaakte profielen (`realSiloToggleBox` e.a.) zijn verwijderd uit
  `guiProfiles.xml` — niet meer nodig.
- **VALKUIL, in-game gevonden (log.txt): `onClickCallback` van
  BinaryOption/MultiTextOption geeft NIET het element zelf door.** Eerste
  aanname was dat Giants' `GuiElement:raiseCallback` het aangeklikte
  element als argument meegeeft (naar analogie van `onFocusCallback`/
  `onLeaveCallback` in de gedecompileerde `MultiTextOptionElement.lua`,
  die dat wél zo doen). In-game gaf dit een echte crash: `Error: Running
  LUA method 'update'.` / `attempt to index number with
  'rsConfigRowIndex'` — het eerste argument is dus een GETAL (`state`,
  de nieuwe index), niet het element. **Oplossing:** het element zelf
  ophalen via `FocusManager:getFocusedElement()` — zowel
  `BinaryOptionElement:onLeftButtonClicked`/`onRightButtonClicked` als
  `MultiTextOptionElement`'s eigen versies roepen synchroon
  `FocusManager:setFocus(self)` aan vlak vóórdat de klik-callback wordt
  aangeroepen, dus op het moment dat `onClickConfigToggle`/
  `onClickConfigStepper` draait is `FocusManager:getFocusedElement()`
  gegarandeerd het zojuist aangeklikte element. Altijd `type(element) ==
  "table"` checken voor je 'm indexeert — dit soort klik-callbacks is
  nooit 100% uit de (partiële) SDK-bron te bevestigen, dus defensief
  coderen. Zie `onClickConfigToggle`/`onClickConfigStepper` in
  `RealSiloDialog.lua` voor het patroon; gebruik dit ook voor eventuele
  toekomstige natieve GUI-elementen in een lijst-cel.
- **Aantal silo's: natieve pijltjesselector (`ROW_INPUT` met
  `row.stepper=true`)**, sinds v2.0.0.0, zelfde stijl als "Running
  Multiplier" in FS25's eigen instellingenmenu: profiel
  `fs25_multiTextOption` (`MultiTextOption`-element, `name="rowStepper"`
  in de `configRowInput`-template, naast `rowToggle`). `row.min`/`row.max`
  bepalen het bereik (1-32); `populateConfigCell` bouwt de `texts`-lijst
  en zet de stand met `:setState(waarde - min + 1, false)`. Alleen
  "Aantal silo's" gebruikt dit vooralsnog — capaciteit/snelheid/
  zoekbereik blijven gewone tekstvelden. Zelfde `rsConfigRowIndex` +
  `FocusManager:getFocusedElement()`-patroon als hierboven.
- **VALKUIL, in-game gevonden (screenshot): `g_i18n:getText(key) or
  fallback` beschermt NIET tegen een ontbrekende vertaalsleutel.** Een
  missende l10n-key geeft in FS25 geen `nil` terug maar een letterlijke
  placeholder-string ("Missing 'key' in ..."), dus de `or fallback`
  wordt nooit gebruikt en die placeholder-tekst verschijnt gewoon in de
  GUI. Gebeurde met `realSilo_slotNameLabel` (pagina 3, naamveld per
  vak) — de key bestond al in de Lua-code maar was nooit aan de drie
  `translation_*.xml`-bestanden toegevoegd. Controleer bij een nieuwe
  `g_i18n:getText("realSilo_...")`-aanroep ALTIJD of de key ook echt in
  alle drie de vertaalbestanden staat (een simpele grep-diff tussen
  gebruikte en gedefinieerde keys volstaat) — vertrouw niet op de
  `or fallback` als vangnet.

### 15. Instance-level `with=` op GuiElement/TextInput werd NIET betrouwbaar toegepast -- anchor hoort in het PROFIEL

Punt 12 hierboven loste de overloop-bug van rowToggle/rowStepper op door
`with="anchorMiddleRight"` in het PROFIEL (`fs25_settingsBinaryOption`/
`-MultiTextOption`) te laten zitten i.p.v. als instance-attribuut. Voor
`rowInput` (TextInput) + zijn achtergrond (`realSiloConfigInputBg`) werd
toen echter WEL een instance-level `with="anchorTopRight"` gebruikt --
en dat bleek zelf ook stuk: in-game overlapten het label en de
invoerwaarde ("Silo name:" + "Farma 800 + Obi 1000" bovenop elkaar). De
`position`-offset werd kennelijk toegepast alsof het element nog zijn
PROFIEL-default `anchorTopLeft` had (dus vlak bij x=0, ONDER het label),
terwijl de instance-`with` zelf genegeerd leek te worden.

**Fix:** exact dezelfde aanpak als punt 12 -- `with="anchorTopRight"`
verplaatst NAAR de profielen zelf (`realSiloConfigInputBg` en
`realSiloConfigInput` in `guiProfiles.xml`), instance-tag in
`RealSiloDialog.xml` houdt alleen nog `position`/`size`. **Les, definitief
bevestigd nu met TWEE onafhankelijke gevallen (punt 12 en dit punt): `with`
(het anchor-schema) hoort in het PROFIEL, nooit als instance-attribuut op
het XML-element zelf -- `position`/`size` overriden op de instance is wel
prima en het gangbare patroon door dit hele bestand heen (zie `rowLabel`,
`dialogTitleElement`, etc.). Bij een toekomstig nieuw GUI-element: nooit
`with=` op de instance-tag zetten, altijd in een eigen (of bestaand)
Profile.**

Tegelijk `rowLabel` verbreed van 290px naar 410px (de waarde-kolom staat nu
altijd rechts uitgelijnd op vaste marge, dus links is meer ruimte over) en
`realSiloConfigRowLabel` kreeg `textMaxNumLines=2` als vangnet -- nodig
voor de langere Drogen-rijlabels uit punt 17 hieronder.

### 16. Drogen-knop alsnog in de footer: de "600px is precies vol"-aanname was onze eigen keuze, geen spel-limiet

Punt 13 documenteerde "geen ruimte voor een 4e voetknop" als vaststaand
feit. Bij nader onderzoek (gebruiker vroeg expliciet om de G-actie ook als
knop): `fs25_dialogButtonBox` (SDK-profiel) is van zichzelf
`anchorBottomStretchingX` met `absoluteSizeOffset="50px 0px"` -- rekt dus
uit tot (dialoogbreedte - 50px) = 860-50 = 810px. Het eerdere
`size="600px 60px"` op de `BoxLayout`-instance was gewoon ONZE eigen,
eerder gekozen waarde (precies passend voor 3 knoppen), geen harde
spel-limiet. **Fix:** `size="800px 60px"` (ruim binnen de 810px die het
profiel zelf al toestaat) + een 4e knop `buttonDryer` (`fs25_dryerMenuTitle`
tekst, `onClick="onClickDryer"`) tussen Transfer en Close. Zichtbaarheid:
alleen op pagina 1 EN alleen als drogen voor deze silo ook echt bruikbaar
is (`realSiloManager.hasDryer(uid) == true` EN
`g_currentMission.dryingSystem ~= nil`, zelfde gate als `onClickDryer`/
`buildDryerRows` al gebruikten) -- anders een knop die altijd meteen een
foutmelding geeft. G-toets blijft ernaast bestaan (`onOpen`, ongewijzigd),
exact zoals Transfer al T-toets + knop combineert.

**Bijvangst, zelfde ronde:** de eerdere "vindbaarheid"-hint uit punt 13
checkte `g_currentMission.MoistureSystem` (de mod-brede referentie) terwijl
de ECHTE gate die `onClickDryer`/`buildDryerRows`/deze nieuwe knop allemaal
gebruiken `g_currentMission.dryingSystem` is (de kleine-letter
DryingSystem-instance). Die twee zijn niet hetzelfde object en kunnen in
theorie uiteenlopen. Rechtgezet naar `.dryingSystem` overal, inclusief de
hint-rij. **Les: als een mod twee losse globals voor "is de andere mod
actief" heeft (hier `.MoistureSystem` vs `.dryingSystem`), kopieer nooit
zomaar de eerste de beste die je tegenkomt -- zoek de EXACTE check op die
de functionaliteit zelf al gebruikt (hier: `onClickDryer`) en hergebruik
precies die.**

### 17. Meer info in het Drogen-menu (vocht%/grade), maar bewust GEEN ETA

Gebruiker vergeleek ons "Drogen"-menu met FS25_MoistureSystem's eigen
Grain Drying-tabel (NAME/TYPE/STATE/CROPS/ETA) en vroeg om meer info.
Toegevoegd aan elke vak-rij in `buildDryerRows`: vocht% + kwaliteitsgrade
via de AL BESTAANDE, elders al bewezen helper
`RealSiloMoistureCompat.getCompartmentLabel(ownerPlaceable, fillType, slot,
uid, slotIndex)` (dezelfde functie die de Overview-pagina's "A · 14.0%"
al toont) -- géén nieuwe, ongeverifieerde aanroep. Plus een simpel
"Drogend"/"Inactief"-tekstlabel, afgeleid van de toch al veilig aanwezige
`RealSiloDryerCompat.isDrying(uid, slotIndex)`.

**Bewust NIET gedaan: een ETA (resterende tijd) tonen zoals de
Moisture-mod dat doet.** `DryingSystem`'s interne rekenmethode daarvoor
staat nergens als Lua-bron in de meegeleverde SDK (`gameSource.zip`) om te
verifiëren -- exact dezelfde situatie als de `onClickCallback`-aanname uit
punt 4/Valkuil hierboven die toen een echte crash gaf. Een ETA-cijfer
verzinnen/schatten zou een VERKEERD getal aan de speler kunnen tonen, wat
erger is dan het gewoon weglaten. **Les: als iets alleen via een
ongeverifieerde aanname van een ANDERE mod's interne rekenlogica te tonen
is (i.p.v. een simpele read van een bestaande, al-gebruikte helper),
niet gokken -- weglaten en in de UI-tekst/documentatie eerlijk verwijzen
naar de bron-mod se eigen menu voor dat specifieke cijfer.**

### 18. Pijltjesselector met een eigen stapgrootte (niet alleen 1-voor-1)

Punt 12/Deel 4 introduceerde `row.stepper=true` voor "Aantal silo's", met
een impliciete stapgrootte van 1 (de `texts`-lijst liep gewoon `row.min` t/m
`row.max`). Voor "Speed (L/min)" (stap 1000) en "Extension search range"
(stap 1, maar nu met bereik 1-300 i.p.v. 1-32) was een instelbare
stapgrootte nodig. Toegevoegd: `row.step` (optioneel, default 1) --
`populateConfigCell` bouwt de `texts`-lijst nu met
`for n = row.min, row.max, step` i.p.v. altijd stap 1, en rondt een
bestaande waarde die niet exact op de step-grid ligt af naar de
dichtstbijzijnde optie (`math.floor((val - row.min) / step + 0.5)`,
geklemd op `[0, #texts-1]`) -- nodig omdat een oude, handmatig ingevoerde
waarde (bv. 3500 L/min uit een save van vóór deze wijziging) niet
noodzakelijk een veelvoud van de nieuwe stapgrootte is.
`onClickConfigStepper` leest dezelfde `row.step` terug bij het omrekenen
van de klik-`state` naar de echte waarde
(`row.min + (state-1) * step`). "Speed": 1000-50000 in stappen van 1000
(bovengrens ruim onder de 65535-grens van het 16-bit streamveld in
`RealSiloConfigEvent`, zie `realSiloEvents.lua`). "Extension search
range": 1-300 in stappen van 1 (zelfde grenzen als de bestaande clamp in
`onConfirm`).

### 19. Lege TextInput in een SmoothList-cel: onvindbaar zonder expliciete klik-naar-focus, en bijna onzichtbaar bij een lege waarde

Gemeld: op de vak-bewerkpagina (pagina 3) kon de speler geen naam invullen
-- het "Naam:"-veld leek niet aanklikbaar. Twee samenhangende problemen,
allebei gefixt:

1. **Onzichtbaar bij lege waarde.** `realSiloConfigInputBg` (de vlakke
   achtergrond achter een tekstveld) had `imageColor="1 1 1 0.10"` -- bij
   een LEGE TextInput (geen tekst om naar te kijken) is dat vrijwel
   onzichtbaar tegen de donkere rijachtergrond, dus was er geen enkele
   visuele aanwijzing dat daar een klikbaar veld stond. Verhoogd naar
   `0.22` -- blijft subtiel maar is nu duidelijk herkenbaar, ook leeg.
2. **`onListClick` deed niets voor `ROW_INPUT`-rijen.** Sinds de native
   BinaryOption/MultiTextOption-omschakeling (punt 9) is de ROW_TOGGLE-tak
   uit `onListClick` verwijderd, maar er kwam nooit iets terug voor gewone
   tekstvelden: een klik op de RIJ (buiten het TextInput-element zelf,
   bijvoorbeeld op het label of de rand) deed niets, en het was onduidelijk
   of het kleine TextInput-vlak zelf wel altijd de klik binnenkreeg
   (dezelfde soort onzekerheid als bij BinaryOption/MultiTextOption, zie
   punt 4 -- Giants' klik-routing binnen een SmoothList-cel is niet
   gedocumenteerd). **Fix:** `onListClick` zet nu bij elke klik op een
   `ROW_INPUT`-rij (zonder `stepper`) expliciet
   `FocusManager:setFocus(row._inputElement)` -- zelfde bewezen patroon als
   de klik-callbacks van de native widgets. Werkt overlappend met de eigen
   klik-afhandeling van TextInput zelf (geen kwaad als die toch al werkte),
   en lost het probleem sowieso op als dat de oorzaak was.

### 20. Vindbaarheids-hint uit Deel 5/punt 13 weer verwijderd

Na de Drogen-voetknop (punt 16) vond de gebruiker de losse hint-rij
("Tip: ga terug naar het overzicht...") op de instellingenpagina overbodige
rommel. De rij (en de bijbehorende `realSilo_dryerActivateHint`-vertaalsleutel,
in alle 3 talen) is verwijderd -- de footer-knop + G-toets op het overzicht
zijn nu de enige vindbaarheids-route. **Les: een hint die een tijdelijk gat
dichtte (geen knop, dus een tekst-uitleg) hoort te verdwijnen zodra het
onderliggende gat zelf gedicht is (hier: de knop) -- laat 'm niet
per ongeluk staan als dode rommel.**

### 21. Naamveld op pagina 3 weer verwijderd (i.p.v. gefixt)

Na punt 19 (TextInput focus/zichtbaarheid gefixt) gaf de gebruiker aan
geen noodzaak te zien om het "Naam:"-veld op de vak-bewerkpagina (pagina 3)
uberhaupt te behouden -- gewoon weghalen. De ROW_INPUT-rij (`key="slotName"`)
is verwijderd uit `buildSlotEditRows`, en de bijbehorende opslaan-aanroep
(`RealSiloEvents.sendSlotName(...)`) is verwijderd uit `onConfirmSlot` --
die riep anders bij elke Opslaan een LEGE naam-waarde door (`getConfigValue`
geeft `nil`/`""` terug voor een rij die niet meer bestaat), wat elke keer
een eventueel al ingestelde vaknaam stilzwijgend zou hebben gewist. De
onderliggende infrastructuur (`RealSiloCompartmentStorage.setSlotName`,
`RealSiloSlotNameEvent`, XML save/load van `slot.name`) is INTACT gelaten --
alleen de GUI-invoer is weg, dus een naam die via XML/map-config of een
eerdere sessie al gezet is blijft gewoon zichtbaar in de rij-header
("Silo 2: <naam>"), alleen niet meer via dit menu te wijzigen. De nu
verweesde vertaalsleutel `realSilo_slotNameLabel` is verwijderd uit alle
drie de taalbestanden (zelfde discipline als punt 20: een gat dat niet
meer bestaat, hoort geen dode code/vertaling achter te laten).

---

## Testen

Sinds 1.2.0.7 bevat de mod GEEN logging meer (ook geen `RealSiloDebug`
en geen companion-debugmod). Giants keurt bij de ModHub-certificering
elke `pcall`/`xpcall` af ("swallows errors and hides them from the log"),
en `descVersion` moet 113 zijn. Regels:
- Nooit `pcall`/`xpcall` gebruiken; `grep -rn pcall scripts/` moet leeg zijn.
- Diagnose-logging alleen tijdelijk in een testversie en vóór een
  ModHub-inzending weer verwijderen.
- Fouten verschijnen nu gewoon als Lua-fout in `log.txt`.

Bij problemen met laden/lossen is het log leidend: kijk welke functies het
spel daadwerkelijk aanroept voordat je een hook kiest. Zo bleek dat de
LoadTrigger alleen `getSupportedFillTypes` en `removeFillLevel` gebruikt —
niet `getAllFillLevels`, waar eerder vergeefs op gehookt was.
