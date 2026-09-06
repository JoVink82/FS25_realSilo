-- ============================================================
-- realSiloDryerCompat.lua
--
-- Geeft elk COMPARTIMENT van een door realSilo beheerde silo een
-- eigen, onafhankelijke plek in FS25_MoistureSystem's Grain
-- Drying-menu (Shift+M), in plaats van dat alle vakken van dezelfde
-- silo (en hetzelfde gewas) op ÉÉN gedeelde vocht/kwaliteit-waarde
-- draaien -- en dus allemaal tegelijk "drogen" zodra er ergens in de
-- silo gedroogd wordt (precies het gerapporteerde probleem: "drogen
-- doet hij bij de silo gelijk dus zelfde waardes").
--
-- Hoe: MoistureSystem's DryingSystem kent geen compartimenten, alleen
-- placeables (elk met precies één uniqueId, gebruikt als sleutel in
-- ms.objectInfo[uid][fillType]). We registreren daarom per vak een
-- lichte PROXY-tabel die zich voor DryingSystem gedraagt als een
-- eigen, zelfstandige silo-placeable:
--   - proxy.uniqueId = "<echte silo-uid>#vak<N>" (kan nooit botsen met
--     een echte placeable-id)
--   - proxy.spec_silo.storages = uitsluitend de inhoud van DIT vak
--   - proxy:getName() = "<silonaam> - Vak N" (silonaam via
--     Placeable:getName(), inclusief de aangepaste naam-patch uit
--     realSiloHook.lua)
--   - proxy:getOwnerFarmId() = doorverwezen naar de echte silo
--
-- DryingSystem:getOwnedDryables() en :getPlaceableByUniqueId() worden
-- gepatcht (metatable-truc, zie eerdere versies van dit bestand) zodat:
--   1) een door realSilo beheerde silo in de dryables-lijst VERVANGEN
--      wordt door N proxy's (één per gevuld vak);
--   2) de per-uur droog-tick (onHourChanged -> getPlaceableByUniqueId)
--      zo'n proxy weer terugvindt aan de hand van zijn synthetische
--      uniqueId.
--
-- ms.objectInfo[uid][fillType] is een gewone Lua-tabel, geen speciale
-- klasse -- die kan dus prima onder een synthetische sleutel bestaan.
-- Bij de EERSTE keer dat een vak als proxy wordt opgevraagd, "seeden"
-- we die synthetische sleutel vanuit de huidige effectieve waarde van
-- het vak (RealSiloCompartmentStorage.getEffectiveMoistureInfo,
-- ongewijzigd). Daarna is de synthetische sleutel leidend: latere
-- aanroepen SCHRIJVEN NIET meer overheen, maar lezen 'm terug naar het
-- vak toe (zo komt een door drogen verminderde vochtwaarde weer
-- zichtbaar in het R-menu/de infobox). Dit gebeurt zowel bij elke
-- ververing van het Grain Drying-menu (~1x/sec zolang het open staat)
-- als bij elke uur-tick voor vakken die actief drogen.
--
-- OPGELOST (was hier eerder een BEPERKING): op een MULTIPLAYER-CLIENT
-- (dus ook elke speler op een DEDICATED SERVER -- die is nooit
-- host/server) stuurt MoistureGuiDrying's eigen toggle-knop een
-- netwerk-event met de NetworkUtil-object-id van de placeable. Die
-- bestaat niet voor onze proxy's (het zijn geen echte, genetwerkte
-- objecten): NetworkUtil.getObjectId(proxy) geeft nil, de knop stuurde
-- dus stilzwijgend helemaal niets naar de server. Drogen
-- starten/stoppen via dit menu werkte daardoor alleen als host/server
-- (bij singleplayer altijd het geval, en waarom dit daar nooit is
-- opgevallen) -- op een dedicated server was elke speler een client en
-- deed de knop dus nooit iets.
--
-- Fix: onderaan dit bestand patchen we de instance-methode
-- MoistureGuiDrying:onClickToggleDrying() (via g_gui.frames, dezelfde
-- "patch de instance, niet de klasse"-truc als voor DryingSystem
-- verderop) zodat een klik op één van onze vak-proxy's NIET via
-- MoistureGuiDrying's eigen NetworkUtil-pad loopt, maar via realSilo's
-- eigen RealSiloDryerToggleEvent (zie realSiloEvents.lua): dat
-- identificeert het vak via silo-uid + vakindex in plaats van een
-- netwerk-object-id, en roept op de server gewoon
-- DryingSystem:toggleDrying()/:setDryingState() aan -- die kijken toch
-- alleen naar placeable.uniqueId (een string). Voor elke ANDERE
-- (echte) placeable in de dryables-lijst blijft het originele gedrag
-- ongewijzigd. Lijst bekijken/ETA/vocht per vak werkte al langer prima
-- op een client, dat verandert niet.
--
-- TWEEDE, VERGELIJKBAAR PROBLEEM (2026-09-06, na de bovenstaande fix): de
-- toggle-knop werkte toen eindelijk, maar de vochtwaarde zelf zakte voor een
-- CLIENT nooit -- exact dezelfde NetworkUtil.getObjectId(proxy)==nil-beperking,
-- ditmaal in DryingSystem:drySilo() zelf: die stuurt zijn uur-tick-resultaat
-- alleen door als NetworkUtil.getObjectId(placeable) niet nil is. Fix (zie
-- installDrySiloSafetyNet/syncProxyMoistureToSlot verderop): na elke
-- drySilo-aanroep voor een vak-proxy de nieuwe waarde uit ms.objectInfo
-- terugschrijven naar onze eigen boekhouding en die met het bestaande
-- RealSiloSlotSyncEvent-kanaal (silo-uid + index, geen netwerk-object-id
-- nodig) naar alle clients broadcasten.
--
-- Is FS25_MoistureSystem niet actief, dan doet dit bestand niets.
-- ============================================================

RealSiloDryerCompat = {}

local VIRTUAL_ID_SEP = "#vak"

function RealSiloDryerCompat.buildVirtualId(uid, slotIndex)
    return uid .. VIRTUAL_ID_SEP .. tostring(slotIndex)
end

function RealSiloDryerCompat.parseVirtualId(virtualId)
    if type(virtualId) ~= "string" then return nil end
    local uid, idxStr = virtualId:match("^(.-)" .. VIRTUAL_ID_SEP .. "(%d+)$")
    if not uid or uid == "" then return nil end
    return uid, tonumber(idxStr)
end

-- Echte placeable die op dit moment achter een vak zit (hoofdsilo, of
-- bij een extensie de extensie zelf) -- dezelfde logica als
-- realSiloMoistureCompat.lua's populateCompartmentCell.
local function getSlotOwnerPlaceable(uid, data, slot)
    if slot.isExtension then
        return slot.extPlaceable
    end
    return data.placeable
end

-- Zorgt dat ms.objectInfo["<uid>#vak<N>"][fillTypeName] bestaat.
-- Eerste keer: overgenomen van de huidige effectieve waarde van dit
-- vak (pint 'm meteen ook op het vak zelf, zie
-- RealSiloCompartmentStorage.getEffectiveMoistureInfo). Bestaat de
-- synthetische sleutel al (mogelijk sindsdien door drogen verminderd),
-- dan is DIE leidend en wordt de eventueel gewijzigde waarde
-- teruggeschreven naar het vak (niet andersom).
local function ensureVirtualSeeded(uid, slotIndex, data, slot)
    if slot.fillType == nil or slot.fillType == 0 then return nil end
    if not slot.fillLevel or slot.fillLevel <= 0 then return nil end
    local ms = g_currentMission and g_currentMission.MoistureSystem
    if not ms then return nil end
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(slot.fillType)
    if fillTypeName == nil then return nil end

    local virtualId = RealSiloDryerCompat.buildVirtualId(uid, slotIndex)
    ms.objectInfo[virtualId] = ms.objectInfo[virtualId] or {}

    local existing = ms.objectInfo[virtualId][fillTypeName]
    if existing ~= nil then
        if existing.moisture ~= slot.moisture or existing.quality ~= slot.quality then
            slot.moisture = existing.moisture
            slot.quality  = existing.quality
        end
        return fillTypeName
    end

    local ownerPlaceable = getSlotOwnerPlaceable(uid, data, slot)
    local ok, info = pcall(RealSiloCompartmentStorage.getEffectiveMoistureInfo, ownerPlaceable, slot)
    if not ok or info == nil or info.moisture == nil then return nil end

    ms.objectInfo[virtualId][fillTypeName] = { moisture = info.moisture, quality = info.quality }
    return fillTypeName
end

-- ----------------------------------------------------------------
-- BLEEK (2026-09-06, na live-test: de moisture-sync-broadcast hierboven vuurde
-- wel degelijk, maar de speler zag in het Grain Drying-menu alsnog niets
-- veranderen): de vorige fix schreef de gedroogde waarde alleen terug in
-- RealSiloCompartmentStorage (slot.moisture/quality) op de client -- maar het
-- menu leest zijn percentage NOOIT rechtstreeks uit slot.moisture. Het leest
-- ms:getObjectInfo(proxy.uniqueId, fillTypeIndex), dus uit ms.objectInfo[
-- virtualId][fillTypeName] (zie DryingSystem:getSiloCropStatus in
-- FS25_MoistureSystem zelf). En ensureVirtualSeeded hierboven doet, zodra die
-- synthetische sleutel eenmaal bestaat, juist het OMGEKEERDE van wat je zou
-- verwachten: het behandelt ms.objectInfo als leidend en overschrijft
-- slot.moisture DAARMEE (voor het geval drogen het al server-side had
-- aangepast in de oude, kapotte situatie zonder deze compat-laag). Op de
-- client bleef ms.objectInfo[virtualId] voor altijd op de allereerste
-- (ongedroogde) waarde staan, dus de eerstvolgende menu-ververing (~1x/sec)
-- zette de zojuist door RealSiloSlotSyncEvent gesynchroniseerde
-- slot.moisture domweg meteen terug naar de oude waarde.
--
-- Fix: bij ELKE binnenkomende slot-sync (RealSiloSlotSyncEvent, dus ook na
-- deze droog-broadcast) niet alleen slot.moisture/quality bijwerken, maar
-- ONMIDDELLIJK ook ms.objectInfo[virtualId][fillTypeName] daarmee
-- gelijktrekken -- zodat er nooit meer een stale ms.objectInfo-waarde
-- overblijft die een latere menu-ververing weer kan laten terugveren.
-- Aangeroepen vanuit realSiloEvents.lua's RealSiloSlotSyncEvent:run.
-- ----------------------------------------------------------------
function RealSiloDryerCompat.syncVirtualMoistureFromSlot(uid, slotIndex)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    local slot = data and data.slots and data.slots[slotIndex]
    if not slot or not slot.fillType or slot.fillType == 0 or slot.moisture == nil then return end

    local ms = g_currentMission and g_currentMission.MoistureSystem
    if not ms then return end
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(slot.fillType)
    if fillTypeName == nil then return end

    local virtualId = RealSiloDryerCompat.buildVirtualId(uid, slotIndex)
    ms.objectInfo[virtualId] = ms.objectInfo[virtualId] or {}
    ms.objectInfo[virtualId][fillTypeName] = { moisture = slot.moisture, quality = slot.quality }
end

-- Bouwt de proxy-"placeable" voor één vak. nil als het vak leeg is,
-- de silo niet meer bestaat, of er niets te seeden viel.
local function buildProxyPlaceable(uid, slotIndex)
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    local slot = data and data.slots and data.slots[slotIndex]
    if not data or not slot or not data.placeable then return nil end
    if not slot.fillType or slot.fillType == 0 or not slot.fillLevel or slot.fillLevel <= 0 then
        return nil
    end

    local fillTypeName = ensureVirtualSeeded(uid, slotIndex, data, slot)
    if fillTypeName == nil then return nil end

    local mainPlaceable = data.placeable
    local proxy = {}
    proxy.uniqueId          = RealSiloDryerCompat.buildVirtualId(uid, slotIndex)
    proxy.realSiloUniqueId  = uid
    proxy.realSiloSlotIndex = slotIndex
    proxy.spec_silo = {
        storages = { { fillLevels = { [slot.fillType] = slot.fillLevel } } },
    }
    proxy.getOwnerFarmId = function() return mainPlaceable:getOwnerFarmId() end
    proxy.getName = function()
        local baseName = (mainPlaceable.getName and mainPlaceable:getName()) or "Silo"
        local vakLabel  = g_i18n:getText("realSilo_compartment") or "Vak"
        return string.format("%s - %s %d", baseName, vakLabel, slotIndex)
    end
    return proxy
end

-- ----------------------------------------------------------------
-- Aangeroepen op de SERVER via RealSiloDryerToggleEvent (of lokaal,
-- als de server zelf de host is). Bouwt de proxy opnieuw op en zet
-- 'm om via DryingSystem:toggleDrying() -- exact dezelfde functie die
-- MoistureGuiDrying zelf voor echte placeables gebruikt.
-- Return: de nieuwe isDrying-status, of nil als het vak niet (meer)
-- opgebouwd kon worden (leeg, silo weg, geen moisture-data).
-- ----------------------------------------------------------------
function RealSiloDryerCompat.toggleDrying(uid, slotIndex)
    local ds = g_currentMission and g_currentMission.dryingSystem
    if ds == nil then return nil end

    local proxy = buildProxyPlaceable(uid, slotIndex)
    if proxy == nil then return nil end

    ds:toggleDrying(proxy)
    return ds:isDrying(proxy.uniqueId)
end

-- ----------------------------------------------------------------
-- Aangeroepen op ELKE ontvanger (client of server) van de
-- RealSiloDryerToggleEvent-broadcast. In tegenstelling tot toggleDrying
-- hierboven is hier GEEN volledige proxy nodig -- setDryingState kijkt
-- alleen naar de uniqueId-string, dus dit werkt ook zonder dat het vak
-- lokaal al bekend/gevuld is.
-- ----------------------------------------------------------------
function RealSiloDryerCompat.applyDryingState(uid, slotIndex, newState)
    local ds = g_currentMission and g_currentMission.dryingSystem
    if ds == nil then return end
    ds:setDryingState(RealSiloDryerCompat.buildVirtualId(uid, slotIndex), newState)
end

-- v14c -- BUGFIX: de metatable-truc (getmetatable(instance).__index)
-- die eerder voor DryingSystem werkte, bleek deze keer geen bruikbare
-- klassentabel op te leveren (installatie bleef voor altijd falen,
-- ook nadat g_currentMission.dryingSystem al lang bestond). In plaats
-- van te blijven gokken naar de exacte metatable-vorm: er bestaat maar
-- EEN instance van DryingSystem (gedeeld via g_currentMission.dryingSystem,
-- door ALLE spelers/mods gebruikt) -- dus een methode direct op die
-- INSTANCE zetten werkt net zo goed als op de klassentabel, en heeft
-- geen enkele aanname over de metatable-vorm nodig: self:methode(...)
-- kijkt sowieso eerst op de instance zelf voordat Lua uberhaupt de
-- metatable/__index raadpleegt. (Dit werkt NIET voor iets met veel
-- instances zoals de oude DryingActivatable-per-silo, maar DryingSystem
-- heeft er precies een, dus hier is het de eenvoudigere en robuustere
-- oplossing.)

-- ----------------------------------------------------------------
-- 1) getOwnedDryables: door realSilo beheerde silo's vervangen door
--    N vak-proxy's.
-- ----------------------------------------------------------------
local function installOwnedDryablesSplit(instance)
    if type(instance.getOwnedDryables) ~= "function" then return false end
    if instance._realSiloDryablesSplitInstalled then return true end
    instance._realSiloDryablesSplitInstalled = true

    local originalGetOwnedDryables = instance.getOwnedDryables
    instance.getOwnedDryables = function(self, farmId)
        local result = originalGetOwnedDryables(self, farmId)
        if result == nil then return result end
        local final = {}
        for _, placeable in ipairs(result) do
            local uid = placeable.realSiloUniqueId
            if uid ~= nil then
                local data = RealSiloCompartmentStorage.siloSlots[uid]
                if data and data.slots then
                    for slotIndex = 1, #data.slots do
                        local ok, proxy = pcall(buildProxyPlaceable, uid, slotIndex)
                        if ok and proxy then table.insert(final, proxy) end
                    end
                end
            else
                table.insert(final, placeable)
            end
        end
        return final
    end

    RealSiloDebug.print("[realSilo] MoistureSystem Grain Drying-menu: door realSilo beheerde silo's opgesplitst per vak")
    return true
end

-- ----------------------------------------------------------------
-- 2) getPlaceableByUniqueId: synthetische vak-id's terug oplossen naar
--    een verse proxy (nodig voor de uur-tick en toggleDrying-lookup).
-- ----------------------------------------------------------------
local function installGetPlaceableByUniqueIdPatch(instance)
    if type(instance.getPlaceableByUniqueId) ~= "function" then return false end
    if instance._realSiloGetByUidPatched then return true end
    instance._realSiloGetByUidPatched = true

    local originalGetByUid = instance.getPlaceableByUniqueId
    instance.getPlaceableByUniqueId = function(self, uniqueId)
        local uid, slotIndex = RealSiloDryerCompat.parseVirtualId(uniqueId)
        if uid ~= nil then
            local ok, proxy = pcall(buildProxyPlaceable, uid, slotIndex)
            if ok then return proxy end
            return nil
        end
        return originalGetByUid(self, uniqueId)
    end

    return true
end

-- ----------------------------------------------------------------
-- 3) drySilo: veiligheidsnet EN de ontbrekende moisture-sync naar clients.
--
-- BLEEK (2026-09-06, na live-test op dedicated server: toggle werkte nu
-- eindelijk, maar "product wordt niet droger"): FS25_MoistureSystem's eigen
-- DryingSystem:drySilo() verlaagt ms.objectInfo[placeable.uniqueId][fillTypeName]
-- .moisture prima op de SERVER (dat gebeurt gewoon in een gedeelde Lua-tabel,
-- ongeacht wat voor placeable het is) -- maar stuurt het resultaat daarna
-- alleen door naar clients via:
--     local objectId = NetworkUtil.getObjectId(placeable)
--     if objectId ~= nil then g_server:broadcastEvent(ObjectMoistureResponseEvent...) end
-- Onze vak-proxy is geen echt, genetwerkt object -- exact dezelfde beperking
-- als bij de toggle-knop (zie "OPGELOST" bovenaan dit bestand):
-- NetworkUtil.getObjectId(proxy) geeft ALTIJD nil, dus die broadcast wordt
-- voor onze vakken stilzwijgend altijd overgeslagen. Resultaat: de server
-- droogt intern gewoon door (elk uur minder vocht in zijn eigen
-- ms.objectInfo), maar een CLIENT ziet daar nooit iets van -- diens eigen
-- ms.objectInfo-kopie voor dit vak blijft voor altijd op de allereerste
-- (ongedroogde) waarde staan, en dus ook slot.moisture (die alleen wordt
-- bijgewerkt VANUIT ms.objectInfo, zie ensureVirtualSeeded hierboven).
--
-- Fix: geen nieuw event nodig -- realSiloEvents.lua heeft al een beproefd,
-- silo-uid+index-gebaseerd sync-kanaal (RealSiloSlotSyncEvent /
-- RealSiloEvents.broadcastSlotSync, ook gebruikt na transfers). Na elke
-- succesvolle drySilo-aanroep voor een vak-proxy lezen we de zojuist
-- bijgewerkte ms.objectInfo-waarde terug, zetten die in onze eigen
-- boekhouding (RealSiloCompartmentStorage), en broadcasten de hele
-- slot-lijst van die silo -- alleen als er ook echt iets veranderd is.
-- ----------------------------------------------------------------
local function syncProxyMoistureToSlot(placeable)
    if g_server == nil then return end
    local uid, slotIndex = placeable.realSiloUniqueId, placeable.realSiloSlotIndex
    local data = RealSiloCompartmentStorage.siloSlots[uid]
    local slot = data and data.slots and data.slots[slotIndex]
    if not slot or not slot.fillType or slot.fillType == 0 then return end

    local ms = g_currentMission and g_currentMission.MoistureSystem
    if not ms then return end
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(slot.fillType)
    local info = fillTypeName and ms.objectInfo[placeable.uniqueId] and ms.objectInfo[placeable.uniqueId][fillTypeName]
    if not info or info.moisture == nil then return end

    if slot.moisture ~= info.moisture or slot.quality ~= info.quality then
        RealSiloDebug.print(
            "[realSilo][DIAG] moisture-sync: vak %s#vak%s: moisture %s -> %s, quality %s -> %s (broadcast naar clients)",
            tostring(uid), tostring(slotIndex), tostring(slot.moisture), tostring(info.moisture),
            tostring(slot.quality), tostring(info.quality))
        slot.moisture = info.moisture
        slot.quality  = info.quality
        RealSiloEvents.broadcastSlotSync(uid)
    end
end

local function installDrySiloSafetyNet(instance)
    if type(instance.drySilo) ~= "function" then return false end
    if instance._realSiloDrySiloWrapped then return true end
    instance._realSiloDrySiloWrapped = true

    local originalDrySilo = instance.drySilo
    instance.drySilo = function(self, placeable, ...)
        if placeable ~= nil and placeable.realSiloSlotIndex ~= nil then
            local ok, err = pcall(originalDrySilo, self, placeable, ...)
            if not ok then
                RealSiloDebug.print(string.format(
                    "[realSilo][DIAG] drySilo-fout opgevangen voor vak %s van silo %s: %s",
                    tostring(placeable.realSiloSlotIndex), tostring(placeable.realSiloUniqueId), tostring(err)))
            else
                local ok2, err2 = pcall(syncProxyMoistureToSlot, placeable)
                if not ok2 then
                    RealSiloDebug.print(string.format(
                        "[realSilo][DIAG] moisture-sync-fout opgevangen voor vak %s van silo %s: %s",
                        tostring(placeable.realSiloSlotIndex), tostring(placeable.realSiloUniqueId), tostring(err2)))
                end
            end
            return
        end
        return originalDrySilo(self, placeable, ...)
    end

    return true
end

-- ----------------------------------------------------------------
-- 4) MoistureGuiDrying:onClickToggleDrying() patchen zodat een klik op
--    één van onze vak-proxy's realSilo's eigen event gebruikt in
--    plaats van MoistureGuiDrying's eigen NetworkUtil-pad (zie
--    "OPGELOST" bovenaan dit bestand). Andere (echte) placeables lopen
--    ongewijzigd via het origineel.
--
-- MoistureGuiDrying is zelf een bare global uit MoistureSystem's eigen
-- Lua-omgeving en dus niet direct bereikbaar (zelfde beperking als
-- CropValueMap, zie realSiloMoistureCompat.lua). De GUI-FRAME-instance
-- is dat wel: Gui:loadGui(..., isFrame=true) bewaart 'm in
-- g_gui.frames["MoistureGuiDrying"].target (frames-tabel is gedeeld,
-- g_gui zelf is een gewone engine-global).
--
-- BELANGRIJK (2026-09-06, na live-test op dedicated server): de eerste
-- versie van deze patch zette de methode rechtstreeks op de instance
-- (instance.onClickToggleDrying = eigenFunctie), zoals bij
-- installOwnedDryablesSplit hierboven. Dat werkt daar wél, maar hier
-- NIET -- en dat kostte een hele testronde om te ontdekken. Verschil:
-- die andere patches worden aangeroepen via een DIRECTE methode-aanroep
-- (instance:methode(), dus altijd een verse lookup in de instance-tabel
-- op het moment van de aanroep). Een GUI-knop werkt anders: GIANTS'
-- GuiElement:addCallback (dataS/scripts/gui/elements/GuiElement.lua)
-- doet bij het laden van de XML EENMALIG
--     self.onClickCallback = self.target[callbackName]
-- -- dus een KOPIE van de functie-WAARDE die op dat moment (bij het
-- opbouwen van MoistureSystem's GUI, ver voor onze installer via de
-- update-loop een kans krijgt) op de instance stond. Onze latere
-- instance.onClickToggleDrying = ... verandert dus een veld dat de knop
-- allang niet meer raadpleegt; de knop blijft voor altijd de
-- OORSPRONKELIJKE (ongepatchte) functie aanroepen. Vandaar dat een klik
-- als host/server toch "werkte" (die functie heeft zelf al een
-- server-branch die zonder netwerk-object-id werkt) maar als client op
-- een dedicated server he-le-maal niets deed, zelfs geen spoor in de
-- diagnostische logging: de gepatchte functie werd domweg nooit
-- aangeroepen.
--
-- Fix: niet de instance-methode patchen, maar het VELD `onClickCallback`
-- op de knop-ELEMENT zelf (instance.btnToggleDrying) overschrijven. Dat
-- veld wordt bij elke klik gewoon opnieuw gelezen (self.onClickCallback(...)),
-- dus een latere toewijzing komt wel aan, ongeacht hoe laat onze
-- installer draait.
-- ----------------------------------------------------------------
-- ECHTE FOUT GEVONDEN (2026-09-06, na live-test + broncode van GIANTS'
-- Gui:resolveFrameReference): g_gui.frames["MoistureGuiDrying"].target is
-- NIET de instance waar de speler mee interacteert! Het SHIFT+M-venster
-- (MoistureGui, een TabbedMenu) laadt de Drying-pagina via een
-- <FrameReference ref="MoistureGuiDrying" .../>-element in MoistureGui.xml.
-- GIANTS' eigen Gui:resolveFrameReference KLOONT de geregistreerde frame-
-- controller ("Otherwise, the registered frame is cloned and returned",
-- dataS/scripts/gui/base/Gui.lua) en wijst die KLOON toe aan
-- moistureGui.pageDrying -- self.pageDrying:initialize() (in
-- MoistureGui:onGuiSetupFinished, src/gui/MoistureGui.lua) draait dus op de
-- KLOON, niet op het origineel in g_gui.frames. Elke patch die we tot nu
-- toe op g_gui.frames["MoistureGuiDrying"].target zetten, werkt dus op een
-- object waar de speler nooit mee interacteert -- vandaar dat btnToggleDrying
-- daar voor altijd nil bleef en initialize() daar nooit "aangeroepen" werd.
--
-- De echte, live instance is bereikbaar via g_currentMission.MoistureSystem
-- (main.lua: "g_currentMission.MoistureSystem = self", een gewone gedeelde
-- engine-global net als g_currentMission.dryingSystem) -> .moistureGui (het
-- SHIFT+M-scherm zelf, main.lua: "self.moistureGui = MoistureGui:new(...)")
-- -> .pageDrying (de kloon, toegewezen door resolveFrameReference zodra
-- MoistureGui.xml geladen wordt -- in dezelfde synchrone Gui:loadGui-aanroep
-- die daarna ook meteen self.pageDrying:initialize() aanroept, dus tegen de
-- tijd dat dit pad iets teruggeeft is initialize() al gedraaid en bestaat
-- btnToggleDrying al).
local function getDryingGuiInstance()
    local ms = g_currentMission and g_currentMission.MoistureSystem
    local moistureGui = ms and ms.moistureGui
    return moistureGui and moistureGui.pageDrying
end

-- Diagnose waarom installToggleGuiPatch niet lukt: dumpt exact wat er WEL
-- bestaat langs het (gecorrigeerde) pad g_currentMission.MoistureSystem
-- -> .moistureGui -> .pageDrying, zodat een volgende test in één keer laat
-- zien welke schakel ontbreekt. Alleen aangeroepen als installToggleGuiPatch
-- faalt, en dan maar 1x per ~20 sec (zelfde cadans als de rest).
local function diagDumpGuiPatchState()
    local ms = g_currentMission and g_currentMission.MoistureSystem
    if ms == nil then
        RealSiloDebug.print("[realSilo][DIAG] guiPatch-diag: g_currentMission.MoistureSystem is nil")
        return
    end

    local moistureGui = ms.moistureGui
    if moistureGui == nil then
        RealSiloDebug.print("[realSilo][DIAG] guiPatch-diag: g_currentMission.MoistureSystem.moistureGui is nil (SHIFT+M-scherm nog niet geladen?)")
        return
    end

    local instance = moistureGui.pageDrying
    if instance == nil then
        RealSiloDebug.print("[realSilo][DIAG] guiPatch-diag: moistureGui.pageDrying is nil (FrameReference nog niet opgelost?)")
        return
    end

    local matches = {}
    for k, v in pairs(instance) do
        if type(k) == "string" and (k:lower():find("btn", 1, true) or k:lower():find("toggle", 1, true)) then
            table.insert(matches, k .. "=" .. tostring(v))
        end
    end
    table.sort(matches)
    RealSiloDebug.print("[realSilo][DIAG] guiPatch-diag: pageDrying gevonden. velden met 'btn'/'toggle' in de naam: %s",
        #matches > 0 and table.concat(matches, " | ") or "(geen)")
    RealSiloDebug.print("[realSilo][DIAG] guiPatch-diag: instance.btnToggleDrying=%s (type=%s)",
        tostring(instance.btnToggleDrying), type(instance.btnToggleDrying))
end

-- BLEEK (2026-09-06, diagnostische dump): self.btnToggleDrying is HELEMAAL
-- GEEN GuiElement/ButtonElement -- het is een gewone Lua-tabel die
-- MoistureGuiDrying zelf in :initialize() aanmaakt voor FS25's "menu button
-- info"-balk (de SPACE/START DRYING-hint onderin het scherm):
--     self.btnToggleDrying = { inputAction = ..., text = ..., callback = function()
--         self:onClickToggleDrying() end, disabled = true }
-- Er is dus geen `.onClickCallback`-veld (dat bestaat alleen op echte
-- GuiElement-knoppen, zie eerdere -- foute -- versie van deze patch). Het veld
-- dat daadwerkelijk aangeroepen wordt als de speler op SPACE drukt (of erop
-- klikt), heet `.callback`.
--
-- TWEEDE PROBLEEM, ook pas met live-tests gevonden: deze tabel bestaat pas
-- NADAT :initialize() gedraaid heeft. Eerst geprobeerd om dat op te lossen
-- door :initialize() zelf te hooken -- overbodig gebleken zodra bleek dat
-- getDryingGuiInstance() de VERKEERDE instance opleverde (zie de uitgebreide
-- toelichting daarboven): via het gecorrigeerde pad
-- (g_currentMission.MoistureSystem.moistureGui.pageDrying) heeft
-- :initialize() namelijk AL gedraaid tegen de tijd dat we een niet-nil
-- instance terugkrijgen (zelfde synchrone Gui:loadGui-aanroep). Simpelweg
-- proberen en bij falen door de aanroepende loop opnieuw laten proberen
-- (geen cap) volstaat dus.
local function patchToggleButtonInfo(instance)
    local info = instance.btnToggleDrying
    if info == nil then return false end
    -- BUGFIX (2026-09-06, na live-test): stond hier eerder ook "return false"
    -- voor het geval de knop AL gepatcht was -- dus na de allereerste succesvolle
    -- patch bleef installToggleGuiPatch() voor altijd false teruggeven, ok4 werd
    -- nooit true, en de FSBaseMission.update-hook (en de bijbehorende "nog niet
    -- compleet"-logspam) bleef daardoor de rest van de sessie onnodig elk frame
    -- doorlopen -- terwijl de knop zelf allang correct werkte. Al gepatcht is
    -- een SUCCES-toestand, geen mislukking.
    if info._realSiloToggleWrapped then return true end
    info._realSiloToggleWrapped = true

    local originalCallback = info.callback
    info.callback = function()
        local entry = instance:getSelectedEntry()
        local canToggle = entry ~= nil and instance:canToggle(entry)
        RealSiloDebug.print(
            "[realSilo][DIAG] onClickToggleDrying: entry=%s uid=%s canToggle=%s isDrying=%s",
            tostring(entry ~= nil), tostring(entry and entry.uniqueId), tostring(canToggle),
            tostring(entry and entry.isDrying))
        if entry == nil or not canToggle then return end

        local placeable = entry.placeable
        local uid = placeable and placeable.realSiloUniqueId
        if uid == nil then
            -- Geen realSilo-vak-proxy: gewoon origineel gedrag.
            RealSiloDebug.print("[realSilo][DIAG] onClickToggleDrying: geen realSilo-vak, origineel pad")
            if originalCallback ~= nil then
                return originalCallback()
            end
            return
        end

        -- realSilo's eigen event regelt client->server->alle clients op
        -- basis van silo-uid + vakindex. RealSiloEvents.sendDryerToggle
        -- kijkt zelf al of dit de server/host is of een client, net als
        -- alle andere RealSiloEvents.sendXxx-helpers.
        RealSiloDebug.print(
            "[realSilo][DIAG] onClickToggleDrying: realSilo-vak uid=%s slot=%s -> sendDryerToggle",
            tostring(uid), tostring(placeable.realSiloSlotIndex))
        RealSiloEvents.sendDryerToggle(uid, placeable.realSiloSlotIndex)
        instance:refreshList()
    end

    RealSiloDebug.print("[realSilo] MoistureSystem Grain Drying-menu: droger-toggle voor vakken loopt nu via realSilo's eigen event")
    return true
end

local function installToggleGuiPatch()
    local instance = getDryingGuiInstance()
    if instance == nil then return false end

    -- Via het gecorrigeerde pad (g_currentMission.MoistureSystem.moistureGui.pageDrying,
    -- zie boven) heeft :initialize() tegen de tijd dat dit een niet-nil instance
    -- teruggeeft AL gedraaid (zelfde synchrone Gui:loadGui-aanroep die de kloon
    -- toewijst roept daarna ook meteen onGuiSetupFinished -> initialize() aan) --
    -- dus btnToggleDrying zou hier al moeten bestaan. Voor de zekerheid blijft dit
    -- gewoon de normale "probeer, en bij falen blijft de aanroepende loop het
    -- volgende frame opnieuw doen"-vorm aanhouden (geen cap, zie hieronder) in
    -- plaats van ervan uit te gaan dat het altijd meteen raak is.
    return patchToggleButtonInfo(instance)
end

-- v14b -- BUGFIX: "300 pogingen" bleek in de praktijk NIET genoeg.
-- g_currentMission.dryingSystem bestaat kennelijk pas een stuk later
-- dan bij de andere realSilo/MoistureSystem-compat-lagen (die WEL
-- binnen 300 frames een reachable instance vonden) -- vermoedelijk
-- omdat DryingSystem pas wordt aangemaakt nadat de savegame/kaart
-- verder geladen is. Eerste-poging-regel altijd zichtbaar. Geen
-- harde limiet meer: blijft proberen (1x per frame, een goedkope
-- metatable-lookup) tot het lukt, met om de ~10 seconden een korte
-- statusregel zodat zichtbaar blijft dat hij nog bezig is i.p.v.
-- stilzwijgend opgegeven heeft. Reset FSBaseMission.update nooit
-- terug (voorkomt dat een wrapper van een andere module gewist wordt).
local _dryerCompatAttempts = 0
local _dryerCompatDone = false

-- De GUI-knoppatch (installer 4) had eerst een eigen aparte cap (3000
-- pogingen), daarna een omgevingscheck (g_client == nil) om te bepalen of
-- dit "een headless dedicated server-proces, hier komt nooit een GUI" was.
-- Beide bleken fout:
--   - de cap gaf voorgoed op voordat de speler het menu ooit geopend had
--     (zie git-historie/eerdere versie van dit bestand voor de details);
--   - g_client == nil bleek GEEN betrouwbare "dit is een headless
--     dedicated server"-indicator te zijn: live-test op een echte
--     GPORTAL-dedicated-server (2026-09-06) liet zien dat g_client daar
--     WEL bestaat, terwijl er natuurlijk nooit iemand fysiek voor dat
--     serverproces zit om het menu te openen. Resultaat: de knoppatch
--     probeerde daar gewoon door te gaan (goed), maar de eerdere
--     "g_client==nil -> meteen klaar"-tak sloeg simpelweg nooit aan, en
--     de diagnostische dump liet zien dat instance.btnToggleDrying daar
--     voor altijd nil blijft (want niemand opent daar ooit het menu).
--
-- Inzicht: dat is prima zo. Deze installer opnieuw proberen is een
-- handvol goedkope tabel-lookups per frame (geen allocaties, geen groei) --
-- er is dus HELEMAAL GEEN reden om ooit "op te geven" of te proberen te
-- detecteren of dit een dedicated server is. Op een client lukt het zodra
-- de speler het menu voor het eerst opent; op een proces waar dat nooit
-- gebeurt (headless of anderszins) blijft ok4 gewoon voor altijd false,
-- zonder enige schade -- en RealSiloDebug.print is toch al stil zolang de
-- companion-debugmod niet geinstalleerd is, dus ook geen logspam in een
-- normale (niet-diagnostische) sessie. Simpelweg: geen cap, geen
-- omgevingsdetectie, gewoon onbeperkt blijven proberen -- zelfde filosofie
-- als de dryingSystem-aanwezigheidscheck hierboven.

local function tryInstallDryerCompat()
    _dryerCompatAttempts = _dryerCompatAttempts + 1
    if _dryerCompatAttempts == 1 then
        local dsInstance = g_currentMission and g_currentMission.dryingSystem
        RealSiloDebug.print(
            "[realSilo][DIAG] realSiloDryerCompat: eerste installatiepoging, g_currentMission.dryingSystem=%s",
            tostring(dsInstance ~= nil))
    elseif _dryerCompatAttempts % 600 == 0 then
        RealSiloDebug.print(
            "[realSilo][DIAG] realSiloDryerCompat: nog steeds aan het proberen (poging %d), g_currentMission.dryingSystem=%s",
            _dryerCompatAttempts, tostring(g_currentMission and g_currentMission.dryingSystem ~= nil))
    end

    local instance = g_currentMission and g_currentMission.dryingSystem
    if instance == nil then
        -- MoistureSystem draait niet (bv. op een dedicated server zonder
        -- die mod). Na een ruime marge stoppen met proberen, anders blijft
        -- deze controle eindeloos doorlopen en het log volschrijven --
        -- gemeten: 15.000+ pogingen op een server zonder MoistureSystem.
        if _dryerCompatAttempts > 3000 then
            _dryerCompatDone = true
            RealSiloDebug.print("[realSilo][DIAG] realSiloDryerCompat: MoistureSystem niet aanwezig, gestopt met proberen")
        end
        return false
    end

    local ok1 = installOwnedDryablesSplit(instance)
    local ok2 = installGetPlaceableByUniqueIdPatch(instance)
    local ok3 = installDrySiloSafetyNet(instance)

    local ok4 = installToggleGuiPatch()

    if ok1 and ok2 and ok3 and ok4 then
        RealSiloDebug.print("[realSilo][DIAG] realSiloDryerCompat: installatie voltooid na " .. tostring(_dryerCompatAttempts) .. " poging(en)")
        return true
    end
    if _dryerCompatAttempts == 1 or _dryerCompatAttempts % 600 == 0 then
        RealSiloDebug.print(
            "[realSilo][DIAG] realSiloDryerCompat: nog niet compleet | getOwnedDryables=%s getPlaceableByUniqueId=%s drySilo=%s dryerToggleKnop=%s",
            tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4))
        if not ok4 then
            diagDumpGuiPatchState()
        end
    end
    return false
end

RealSiloDryerCompat.tryInstall = tryInstallDryerCompat

Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
    if tryInstallDryerCompat() then
        _dryerCompatDone = true
        return
    end

    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function()
        if _dryerCompatDone then return end
        if tryInstallDryerCompat() then
            _dryerCompatDone = true
        end
    end)
end)

RealSiloDebug.print("[realSilo] realSiloDryerCompat geladen (vakken worden als aparte droogbare silo's aangeboden aan MoistureSystem)")
