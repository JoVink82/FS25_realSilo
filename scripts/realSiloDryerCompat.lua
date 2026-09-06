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
-- Op een MULTIPLAYER-CLIENT kan MoistureSystem's standaard netwerk-event
-- geen proxy versturen omdat die geen NetworkUtil-object-id heeft. Daarom
-- onderscheppen we voor RealSilo-vakken de toggle-knop en sturen we via
-- RealSiloDryerToggleEvent de silo-uid + vakindex naar de server.
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

-- Beschikbaar voor RealSiloDryerToggleEvent op de server.
RealSiloDryerCompat.buildProxyPlaceable = buildProxyPlaceable

local function getDryingFrameController()
    local root = g_gui and g_gui.frames and g_gui.frames["MoistureGuiDrying"]
    return root and root.target or nil
end

function RealSiloDryerCompat.refreshDryingGui()
    local controller = getDryingFrameController()
    if controller ~= nil and controller.refreshList ~= nil then
        controller:refreshList()
    end
end

-- Dedicated clients kunnen voor een vak-proxy geen standaard
-- DryingToggleEvent maken. Onderschep uitsluitend RealSilo-vakken in het
-- bestaande MoistureSystem-scherm; alle normale silo's blijven via de
-- originele handler lopen.
local function installDedicatedGuiToggle()
    if g_currentMission == nil or g_currentMission:getIsServer() then return true end
    local controller = getDryingFrameController()
    if controller == nil or type(controller.onClickToggleDrying) ~= "function" then
        return false
    end
    if controller._realSiloDedicatedToggleInstalled then return true end
    controller._realSiloDedicatedToggleInstalled = true

    local originalOnClick = controller.onClickToggleDrying
    controller.onClickToggleDrying = function(self, ...)
        local entry = self:getSelectedEntry()
        local placeable = entry and entry.placeable
        if placeable ~= nil and placeable.realSiloUniqueId ~= nil
                and placeable.realSiloSlotIndex ~= nil then
            if not self:canToggle(entry) then return end
            RealSiloDebug.print("[realSilo] Dedicated droger-verzoek: uid=%s vak=%d",
                tostring(placeable.realSiloUniqueId), placeable.realSiloSlotIndex)
            RealSiloEvents.sendDryerToggle(
                placeable.realSiloUniqueId, placeable.realSiloSlotIndex)
            return
        end
        return originalOnClick(self, ...)
    end
    RealSiloDebug.print("[realSilo] MoistureSystem dedicated droger-toggle per vak actief")
    return true
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
-- 3) drySilo veiligheidsnet: onze proxy's zijn geen echte, genetwerkte
--    objecten. Mocht drySilo() daar intern op struikelen (bv. via
--    NetworkUtil.getObjectId), dan vangen we dat hier op zodat het
--    drogen van ANDERE (echte of andere vak-)silo's in dezelfde
--    uur-tick niet meesleurt in een crash.
-- ----------------------------------------------------------------
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
            end
            return
        end
        return originalDrySilo(self, placeable, ...)
    end

    return true
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
    local ok4 = installDedicatedGuiToggle()
    if ok1 and ok2 and ok3 and ok4 then
        RealSiloDebug.print("[realSilo][DIAG] realSiloDryerCompat: installatie voltooid na " .. tostring(_dryerCompatAttempts) .. " poging(en)")
        return true
    end
    if _dryerCompatAttempts == 1 or _dryerCompatAttempts % 600 == 0 then
        RealSiloDebug.print(
            "[realSilo][DIAG] realSiloDryerCompat: nog niet compleet | getOwnedDryables=%s getPlaceableByUniqueId=%s drySilo=%s dedicatedGui=%s",
            tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4))
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
