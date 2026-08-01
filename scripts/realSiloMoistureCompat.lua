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

    RealSiloDebug.print("[realSilo] MoistureSystem-compatibiliteit actief (hasFillType kijkt nu naar alle vakken)")
    return true
end

-- ----------------------------------------------------------------
-- Publieke helper voor de UI: geeft een compacte tekst zoals
-- "  |  A · 12.4%" terug voor een gegeven placeable + fillType, of
-- "" als MoistureSystem niet actief is of er geen data bekend is.
-- ----------------------------------------------------------------
function RealSiloMoistureCompat.getCompartmentLabel(placeable, fillType)
    if placeable == nil or fillType == nil or fillType == 0 then
        return ""
    end

    local ms = g_currentMission and g_currentMission.MoistureSystem
    if ms == nil or placeable.uniqueId == nil then
        return ""
    end

    local ok, info = pcall(function() return ms:getObjectInfo(placeable.uniqueId, fillType) end)
    if not ok or info == nil or info.moisture == nil then
        return ""
    end

    local moisturePct = info.moisture * 100
    local gradeLabel = ""
    if CropValueMap ~= nil and CropValueMap.getQualityGrade ~= nil and info.quality ~= nil then
        local ok2, grade = pcall(CropValueMap.getQualityGrade, fillType, info.quality)
        if ok2 and grade ~= nil then
            gradeLabel = tostring(grade) .. " \xC2\xB7 "
        end
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

        local label = RealSiloMoistureCompat.getCompartmentLabel(placeable, slot.fillType)
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
-- g_currentMission.MoistureSystem gegarandeerd aangemaakt als de mod
-- actief is.
-- ----------------------------------------------------------------
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
    installHasFillTypePatch()
    installDialogHook()
end)

RealSiloDebug.print("[realSilo] realSiloMoistureCompat geladen")
