-- ============================================================
-- realSiloMoistureCompat.lua
--
-- Optionele compatibiliteitslaag met de mod FS25_MoistureSystem
-- (vocht/kwaliteit-tracking per graansoort). Is die mod niet actief,
-- dan doet dit bestand helemaal niets (alle checks vallen terug op
-- "MoistureSystem niet gevonden" en stoppen meteen).
--
-- ----------------------------------------------------------------
-- PROBLEEM 1 — dataverlies per vak (de belangrijkste fix)
-- ----------------------------------------------------------------
-- MoistureSystem:hasFillType(uniqueId, fillType) bepaalt via
-- storage:getFillLevel(fillType) of een silo een bepaald product nog
-- bevat. realSiloStorageHook.lua hookt Storage.getFillLevel zo dat
-- een GECONFIGUREERDE realSilo altijd het fillLevel van alleen het
-- ACTIEVE vak teruggeeft (nodig zodat Giants' eigen laad/los-, weeg-
-- en verkooplogica alleen het actieve vak "ziet"). Voor elk ander
-- vak/product in dezelfde silo geeft die aanroep dus altijd 0 terug,
-- ook al zit het product er echt nog in.
--
-- MoistureSystem:setObjectInfo() gebruikt hasFillType() als
-- opschoonfilter: bij elke schrijfactie voor uniqueId+fillType X
-- worden ALLE andere, al opgeslagen fillTypes voor diezelfde
-- uniqueId opnieuw gecontroleerd en verwijderd zodra hasFillType
-- false teruggeeft. Met realSilo's actief-vak-virtualisatie verliest
-- een niet-actief vak daardoor zijn vocht/kwaliteitsdata zodra er
-- ELDERS in dezelfde silo iets bijgeboekt wordt (nieuwe levering,
-- verkoop, drySilo-update, ...) — precies het scenario waarvoor
-- realSilo gemaakt is: meerdere graansoorten tegelijk in één silo.
--
-- Oplossing: we patchen MoistureSystem.hasFillType zodat het voor
-- door realSilo beheerde silo's/extensions over ALLE vakken van de
-- silo-cluster kijkt (via RealSiloCompartmentStorage.siloSlots), in
-- plaats van via de gevirtualiseerde Storage:getFillLevel. Voor elk
-- ander object (voertuigen, balen, niet-realSilo silo's, ...) blijft
-- het oorspronkelijke gedrag exact hetzelfde.
--
-- Als bonus herkent de patch ook spec_siloExtension-placeables
-- (silo-extensions), die MoistureSystem van zichzelf niet checkt
-- (het kijkt alleen naar spec_silo) — dit kan dus alleen dekking
-- toevoegen, nooit bestaand gedrag breken.
--
-- ----------------------------------------------------------------
-- PROBLEEM 2 — zichtbaarheid
-- ----------------------------------------------------------------
-- Zonder aanpassing toont realSilo nergens welk vochtpercentage of
-- welke kwaliteitsgrade (A-D) een vak heeft. We voegen dat toe aan:
--   - de vakkenlijst in het RealSiloDialog-overzicht (T-menu)
--   - de wereld-infobox (het paneel dat verschijnt bij de silo)
-- Beide lezen uitsluitend via MoistureSystem's eigen publieke API
-- (getObjectInfo) — er wordt niets aan MoistureSystem zelf
-- geschreven vanuit deze weergavecode.
-- ============================================================

RealSiloMoistureCompat = {}

-- ----------------------------------------------------------------
-- Vind de realSilo-uid die bij een storage hoort (hoofdsilo of
-- extension). realSiloStorageLink is een globale tabel uit
-- realSiloStorageHook.lua: [storage] = uid.
-- ----------------------------------------------------------------
local function findSiloUidForObject(object)
    if object == nil then return nil end

    if object.spec_silo and object.spec_silo.storages then
        for _, storage in ipairs(object.spec_silo.storages) do
            local uid = realSiloStorageLink and realSiloStorageLink[storage]
            if uid then return uid end
        end
    end

    if object.spec_siloExtension and object.spec_siloExtension.storage then
        local uid = realSiloStorageLink and realSiloStorageLink[object.spec_siloExtension.storage]
        if uid then return uid end
    end

    return nil
end

-- ----------------------------------------------------------------
-- Installeer de hasFillType-patch op de actieve MoistureSystem-
-- instantie. Idempotent (mag meerdere keren aangeroepen worden) en
-- volledig onschadelijk als MoistureSystem niet geladen is.
-- ----------------------------------------------------------------
local function installHasFillTypePatch()
    local ms = g_currentMission and g_currentMission.MoistureSystem
    if ms == nil then
        return false -- MoistureSystem niet actief
    end
    if ms._realSiloCompatInstalled then
        return true
    end
    ms._realSiloCompatInstalled = true

    local originalHasFillType = ms.hasFillType

    ms.hasFillType = function(self, uniqueId, fillType)
        if uniqueId == nil or fillType == nil then
            return false
        end
        if not self:shouldTrackFillType(fillType) then
            return false
        end

        local object = g_currentMission:getObjectByUniqueId(uniqueId)
        local uid = findSiloUidForObject(object)

        if uid ~= nil and realSiloManager ~= nil and realSiloManager.isConfigured(uid) then
            local data = RealSiloCompartmentStorage.siloSlots[uid]
            if data then
                for _, slot in ipairs(data.slots) do
                    if slot.fillType == fillType and slot.fillLevel and slot.fillLevel > 0.0001 then
                        return true
                    end
                end
                return false
            end
        end

        return originalHasFillType(self, uniqueId, fillType)
    end

    print("[realSilo] MoistureSystem-compatibiliteit actief (hasFillType kijkt nu naar alle vakken)")
    return true
end

-- ----------------------------------------------------------------
-- Publieke helper voor de UI: geeft een compacte tekst zoals
-- "  |  A · 12.4%" terug voor een gegeven placeable + fillType, of
-- "" als MoistureSystem niet actief is of er geen data bekend is.
-- ----------------------------------------------------------------
-- slot (optioneel): als meegegeven en dit vak een EIGEN vocht/
-- kwaliteit-waarde heeft (gepind bij de eerste MoistureSystem-
-- uitlezing, zie getEffectiveMoistureInfo), wordt die getoond in plaats van de
-- gedeelde MoistureSystem-waarde voor silo+fillType. Zonder slot (of
-- als het vak nog geen eigen waarde heeft) is het gedrag ongewijzigd.
function RealSiloMoistureCompat.getCompartmentLabel(placeable, fillType, slot, uid, slotIndex)
    if placeable == nil or fillType == nil or fillType == 0 then
        return ""
    end

    local ms = g_currentMission and g_currentMission.MoistureSystem
    if ms == nil or placeable.uniqueId == nil then
        return ""
    end

    local info
    if slot ~= nil and RealSiloCompartmentStorage ~= nil then
        info = RealSiloCompartmentStorage.getEffectiveMoistureInfo(placeable, slot, uid, slotIndex)
    else
        local ok, msInfo = pcall(function() return ms:getObjectInfo(placeable.uniqueId, fillType) end)
        if ok then info = msInfo end
    end
    if info == nil or info.moisture == nil then
        RealSiloDebug.print(
            "[realSilo][DIAG] getCompartmentLabel: geen moisture-info | uid=%s fillType=%s info=%s",
            tostring(placeable.uniqueId), tostring(fillType), tostring(info))
        return ""
    end

    -- BUGFIX (v8): CropValueMap (net als DryingSystem) is een bare
    -- global uit MoistureSystem's EIGEN Lua-omgeving, en dus principieel
    -- onbereikbaar vanuit realSilo's scripts (elke mod draait in FS25 in
    -- een eigen geïsoleerde omgeving) -- vandaar dat CropValueMap hier
    -- altijd nil was en de grade nooit verscheen, ongeacht of
    -- info.quality wel degelijk een geldige waarde had. In plaats van
    -- te proberen CropValueMap alsnog te bereiken (er is geen gedeelde
    -- instance van beschikbaar op g_currentMission om via een metatable-
    -- truc bij te komen, in tegenstelling tot DryingSystem), rekenen we
    -- de grade hier gewoon zelf uit met dezelfde grenzen als
    -- CropValueMap.initializeQualityBands() in MoistureSystem's bron
    -- (data/CropValueMap.lua): A vanaf 90, B vanaf 70, C vanaf 50,
    -- D daaronder, op de 0-100 quality-schaal die getObjectInfo levert.
    -- Enige risico: als de MoistureSystem-auteur deze grenzen ooit
    -- wijzigt, loopt onze eigen indeling er iets uit -- acceptabel,
    -- gezien het alternatief (nooit een grade kunnen tonen) erger is.
    local function qualityToGradeLetter(quality)
        if quality >= 90 then return "A"
        elseif quality >= 70 then return "B"
        elseif quality >= 50 then return "C"
        else return "D" end
    end

    local moisturePct = info.moisture * 100
    local gradeLabel = ""
    if info.quality ~= nil then
        gradeLabel = qualityToGradeLetter(info.quality) .. " \xC2\xB7 "
    else
        RealSiloDebug.print(
            "[realSilo][DIAG] getCompartmentLabel: quality ontbreekt | fillType=%s",
            tostring(fillType))
    end

    return string.format("  |  %s%.1f%%", gradeLabel, moisturePct)
end

-- ----------------------------------------------------------------
-- UI: vakkenlijst in RealSiloDialog (T-menu overzicht). Wrap
-- populateCompartmentCell puur additief: eerst het originele gedrag,
-- daarna (indien beschikbaar) het vocht/grade-label achter de al
-- bestaande "x / y L"-tekst plakken.
-- ----------------------------------------------------------------
local function installDialogHook()
    if RealSiloDialog == nil or RealSiloDialog._moistureCompatInstalled then
        return
    end
    RealSiloDialog._moistureCompatInstalled = true

    local originalPopulateCompartmentCell = RealSiloDialog.populateCompartmentCell

    RealSiloDialog.populateCompartmentCell = function(self, index, cell)
        originalPopulateCompartmentCell(self, index, cell)

        local ms = g_currentMission and g_currentMission.MoistureSystem
        if ms == nil then return end

        local uid = RealSiloDialog.currentUniqueId
        if not uid then return end

        local slots = RealSiloCompartmentStorage.getSlots(uid)
        local slot = slots and slots[index]
        if not slot or not slot.fillType or slot.fillType == 0 then return end
        if not slot.fillLevel or slot.fillLevel <= 0 then return end

        local placeable
        if slot.isExtension then
            placeable = slot.extPlaceable
        else
            local silo = realSiloManager.getSilo(uid)
            placeable = silo and silo.placeable
        end
        if not placeable then return end

        local label = RealSiloMoistureCompat.getCompartmentLabel(placeable, slot.fillType, slot, uid, index)
        if label == "" then return end

        local fillEl = cell:getAttribute("fillLevelText")
        if fillEl then
            fillEl:setText((fillEl:getText() or "") .. label)
        end
    end
end

-- ----------------------------------------------------------------
-- Installatie: wachten tot Mission00.onStartMission, net als
-- realSiloHook.lua zelf doet. Op dat moment zijn ALLE mods (dus ook
-- MoistureSystem, ongeacht laadvolgorde) al volledig geladen en is
-- g_currentMission.MoistureSystem in theorie al aangemaakt (gebeurt in
-- MoistureSystem:loadMap(), dat draait al vóór onStartMission) als de
-- mod actief is.
--
-- v6: we hebben in de praktijk GEEN van de succes/faal-logregels van
-- deze installers teruggezien in een log waarin RealSiloDebug wel
-- degelijk aan bleek te staan (andere DIAG-regels kwamen wel door) —
-- dus staat nu niet vast of dit blok ooit met een niet-nil
-- MoistureSystem draait. Daarom nu: (1) een ALTIJD-zichtbare regel bij
-- de eerste poging, zodat we voortaan zwart-op-wit zien of dit blok
-- draait en wat het aantreft, en (2) een korte retry via de update-
-- loop (max 5 sec) voor het geval MoistureSystem net op dat exact
-- moment nog niet klaar stond.
-- ----------------------------------------------------------------
local _installAttempts = 0

local function tryInstallMoistureCompat()
    _installAttempts = _installAttempts + 1
    local ms = g_currentMission and g_currentMission.MoistureSystem
    if _installAttempts == 1 then
        RealSiloDebug.print(
            "[realSilo][DIAG] realSiloMoistureCompat: eerste installatiepoging, MoistureSystem=%s",
            tostring(ms ~= nil))
    end
    local ok1 = installHasFillTypePatch()
    installDialogHook()
    return ok1
end

-- Publiek gemaakt (v6) zodat realSiloHook.lua dit ook rechtstreeks kan
-- aanroepen vanuit PlaceableSilo.onLoad -- een hook waarvan we uit ELK
-- tot nu toe ontvangen log zeker weten dat hij afgaat, in
-- tegenstelling tot Mission00.onStartMission waarvan dat (ondanks de
-- v6-pogingen om dat te bewijzen) nog niet hard bevestigd is. Beide
-- triggers blijven actief; welke ook het eerst raak schiet, telt.
RealSiloMoistureCompat.tryInstall = tryInstallMoistureCompat

-- Belangrijk: de retry-wrapper reset FSBaseMission.update NOOIT terug
-- naar een eerder opgeslagen versie (dat zou een wrapper die een ANDERE
-- module er tussentijds aan toevoegde weer kunnen wissen). In plaats
-- daarvan blijft de wrapper permanent hangen maar wordt hij na succes
-- (of na de max-pogingen-grens) een goedkope no-op via een vlag.
local _moistureCompatDone = false

Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
    if tryInstallMoistureCompat() then
        _moistureCompatDone = true
        return
    end

    FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function()
        if _moistureCompatDone then return end
        if tryInstallMoistureCompat() then
            _moistureCompatDone = true
        elseif _installAttempts > 300 then
            _moistureCompatDone = true
            RealSiloDebug.print("[realSilo][DIAG] realSiloMoistureCompat: MoistureSystem nooit gevonden na 300 pogingen, gestopt met proberen")
        end
    end)
end)

print("[realSilo] realSiloMoistureCompat geladen")
