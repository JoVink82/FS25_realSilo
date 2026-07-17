-- ============================================================
-- realSiloExtensionManager.lua  v2 - multiplayer-veilig (boekhouding)
--
-- Beheert de koppeling tussen SiloExtension-placeables en silo's.
--
-- BELANGRIJK ARCHITECTUURVERSCHIL met v1: een extension met
-- meerdere compartimenten krijgt GEEN extra programmatische
-- Storage-objecten meer. Alle compartimenten van één extension
-- delen de ÉNE echte storage die Giants zelf al aanmaakt en
-- registreert (zie PlaceableSiloExtension:onFinalizePlacement).
-- Wij voegen alleen onze eigen boekhouding toe (welke vakken,
-- hoeveel per vak) — precies zoals voor de hoofdsilo. Dat
-- voorkomt elk risico op een mismatch in het aantal netwerk-
-- geregistreerde storage-objecten tussen server en client.
--
-- Aanpak (volgorde-onafhankelijk):
--   1. loadFromXML: lees savedData {siloUid, comps={...}} per extensionIndex
--   2. onFinalizePlacement van extension: claim pendingSaved entry.
--      Als er savedData is → herstel direct naar de opgeslagen silo.
--      Anders → zoek dichtstbijzijnde silo (nieuw geplaatst) en gebruik
--      de XML-definitie (_realSiloXmlDef) voor het aantal compartimenten.
--   3. saveToXML: schrijf alle linked extensions weg.
-- ============================================================

RealSiloExtensionManager = {}

-- [extPlaceable] = { uid, storage }  (enkelvoudig, 1 compartiment)
RealSiloExtensionManager.linked = {}

-- [extPlaceable] = { {uid, storage, index, isPrimary}, ... }  (multi, 2+ compartimenten)
RealSiloExtensionManager.linkedMulti = {}

-- Opgeslagen data uit XML, wacht op bijbehorende extension-placeables.
-- List van { siloUid, cap, fillType, fillLevel, isActive, isMulti, comps }
RealSiloExtensionManager.pendingSaved = {}

-- ============================================================
-- Link een extension aan een silo met ÉÉN compartiment.
-- Hergebruikt de echte storage van de extension (boekhouding).
-- ============================================================
function RealSiloExtensionManager.link(extPlaceable, uid, savedCap, savedFt, savedFl, savedActive)
    local extSpec    = extPlaceable.spec_siloExtension
    local extStorage = extSpec and extSpec.storage
    if not extStorage then return false end

    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end

    -- XML-gedefinieerde extensions zijn vast (niet door de speler instelbaar)
    local xmlLocked = (extPlaceable._realSiloXmlDef ~= nil)

    if realSiloStorageLink[extStorage] then return false end  -- al gekoppeld

    local silo = realSiloManager.getSilo(uid)
    local cap  = savedCap
    if not cap or cap <= 0 then
        cap = extStorage.capacity or (silo and silo.config.capacityPerCompartment) or 100000
    end

    realSiloStorageLink[extStorage] = uid

    local newIndex = #data.slots + 1
    local isActive = savedActive or false
    table.insert(data.slots, {
        index        = newIndex,
        fillType     = (savedFt and savedFt ~= 0 and savedFl and savedFl > 0) and savedFt or 0,
        fillLevel    = (savedFt and savedFt ~= 0) and (savedFl or 0) or 0,
        capacity     = cap,
        isActive     = isActive,
        isExtension  = true,
        xmlLocked    = xmlLocked,
        extPlaceable = extPlaceable,
        storage      = extStorage,
    })
    if isActive then data.activeSlot = newIndex end

    RealSiloExtensionManager.linked[extPlaceable] = { uid = uid, storage = extStorage }
    RealSiloDebug.print(string.format("[realSilo] Extension gekoppeld: vak %d aan %s (cap: %.0f L, fill: %.0f L)",
        newIndex, uid, cap, savedFl or 0))

    -- Stuur meteen een slot-update naar alle clients zodat het nieuwe
    -- extension-vak zichtbaar wordt zonder dat de speler hoeft op te slaan.
    if g_server ~= nil then
        RealSiloEvents.broadcastSlotSync(uid)
    end

    return true
end

-- ============================================================
-- Link een extension aan een silo met MEERDERE compartimenten.
-- Alle compartimenten delen de ÉNE echte storage van de extension
-- (boekhouding, geen extra storage-objecten).
--
-- compartments = array (1-indexed) van { cap, fillType, fillLevel, isActive }
-- ============================================================
function RealSiloExtensionManager.linkMulti(extPlaceable, uid, compartments)
    if not compartments or #compartments == 0 then return false end

    local extSpec    = extPlaceable.spec_siloExtension
    local extStorage = extSpec and extSpec.storage
    if not extStorage then return false end

    local data = RealSiloCompartmentStorage.siloSlots[uid]
    if not data then return false end

    if realSiloStorageLink[extStorage] then return false end  -- al gekoppeld

    -- XML-gedefinieerde extensions zijn vast (niet door de speler instelbaar)
    local xmlLocked = (extPlaceable._realSiloXmlDef ~= nil)

    realSiloStorageLink[extStorage] = uid

    local entries = {}
    for i, comp in ipairs(compartments) do
        local cap = comp.cap
        if not cap or cap <= 0 then
            cap = extStorage.capacity or 100000
        end

        local newIndex = #data.slots + 1
        local isActive = comp.isActive or false
        table.insert(data.slots, {
            index        = newIndex,
            fillType     = (comp.fillType and comp.fillType ~= 0 and comp.fillLevel and comp.fillLevel > 0) and comp.fillType or 0,
            fillLevel    = (comp.fillType and comp.fillType ~= 0) and (comp.fillLevel or 0) or 0,
            capacity     = cap,
            isActive     = isActive,
            isExtension  = true,
            xmlLocked    = xmlLocked,
            extPlaceable = extPlaceable,
            storage      = extStorage,
        })
        if isActive then data.activeSlot = newIndex end

        table.insert(entries, { uid = uid, storage = extStorage, index = newIndex })

        RealSiloDebug.print(string.format("[realSilo] Extension multi-vak %d gekoppeld aan %s (cap: %.0f L, fill: %.0f L)",
            newIndex, uid, cap, comp.fillLevel or 0))
    end

    RealSiloExtensionManager.linkedMulti[extPlaceable] = entries

    RealSiloDebug.print(string.format("[realSilo] Multi-extension gekoppeld aan %s (%d vakken)", uid, #entries))

    if g_server ~= nil then
        RealSiloEvents.broadcastSlotSync(uid)
    end

    return true
end

-- ============================================================
-- Ontkoppel een extension (enkelvoudig of multi-compartiment).
-- Verwijdert alleen onze boekhouding — de echte storage blijft
-- precies zoals Giants hem beheert (geen delete/removeStorage
-- meer nodig, want wij hebben er nooit één aangemaakt).
-- ============================================================
function RealSiloExtensionManager.unlink(extPlaceable)
    -- Multi-compartiment
    local entries = RealSiloExtensionManager.linkedMulti[extPlaceable]
    if entries then
        local uid    = entries[1].uid
        local data   = RealSiloCompartmentStorage.siloSlots[uid]
        local storage = entries[1].storage

        if data then
            for i = #data.slots, 1, -1 do
                if data.slots[i].extPlaceable == extPlaceable then
                    table.remove(data.slots, i)
                end
            end
            for i, slot in ipairs(data.slots) do slot.index = i end
            if data.activeSlot > #data.slots then data.activeSlot = math.max(#data.slots, 1) end
            for i, slot in ipairs(data.slots) do slot.isActive = (i == data.activeSlot) end
        end

        if storage then realSiloStorageLink[storage] = nil end

        RealSiloExtensionManager.linkedMulti[extPlaceable] = nil
        RealSiloDebug.print(string.format("[realSilo] Multi-extension ontkoppeld van %s (%d vakken)", uid, #entries))
        return
    end

    -- Enkelvoudig
    local entry = RealSiloExtensionManager.linked[extPlaceable]
    if not entry then return end

    local uid     = entry.uid
    local storage = entry.storage
    local data    = RealSiloCompartmentStorage.siloSlots[uid]

    if data then
        for i = #data.slots, 1, -1 do
            if data.slots[i].extPlaceable == extPlaceable then
                table.remove(data.slots, i)
                break
            end
        end
        for i, slot in ipairs(data.slots) do slot.index = i end
        if data.activeSlot > #data.slots then data.activeSlot = math.max(#data.slots, 1) end
        for i, slot in ipairs(data.slots) do slot.isActive = (i == data.activeSlot) end
    end

    realSiloStorageLink[storage] = nil
    RealSiloExtensionManager.linked[extPlaceable] = nil
    RealSiloDebug.print(string.format("[realSilo] Extension ontkoppeld van %s", uid))
end

-- ============================================================
-- Opslaan (enkelvoudig + multi-compartiment). De ECHTE fillLevels
-- van de storage zelf slaat Giants al op; wij slaan alleen onze
-- eigen verdeling over de vakken op.
-- ============================================================
function RealSiloExtensionManager.saveToXML(xmlFile)
    local i = 0

    local function slotsForExt(uid, extPlaceable)
        local data = RealSiloCompartmentStorage.siloSlots[uid]
        local result = {}
        if data then
            for _, slot in ipairs(data.slots) do
                if slot.extPlaceable == extPlaceable then
                    table.insert(result, slot)
                end
            end
        end
        return result
    end

    for extPlaceable, entry in pairs(RealSiloExtensionManager.linked) do
        local slots = slotsForExt(entry.uid, extPlaceable)
        local slot  = slots[1]
        if slot then
            local key = string.format("realSiloData.ext(%d)", i)
            setXMLString(xmlFile, key .. "#siloUid",  entry.uid)
            setXMLFloat(xmlFile,  key .. "#cap",       slot.capacity or 0)
            setXMLInt(xmlFile,    key .. "#numComps",  1)
            setXMLInt(xmlFile,    key .. "#fillType",  slot.fillType or 0)
            setXMLFloat(xmlFile,  key .. "#fillLevel", slot.fillLevel or 0)
            setXMLInt(xmlFile,    key .. "#isActive",  slot.isActive and 1 or 0)
            i = i + 1
            RealSiloDebug.print(string.format("[realSilo] Extension opgeslagen: %s (cap:%.0f fill:%.0f)",
                entry.uid, slot.capacity or 0, slot.fillLevel or 0))
        end
    end

    for extPlaceable, entries in pairs(RealSiloExtensionManager.linkedMulti) do
        local uid   = entries[1].uid
        local slots = slotsForExt(uid, extPlaceable)
        if #slots > 0 then
            local key = string.format("realSiloData.ext(%d)", i)
            setXMLString(xmlFile, key .. "#siloUid",  uid)
            setXMLInt(xmlFile,    key .. "#numComps",  #slots)
            for c, slot in ipairs(slots) do
                local cKey = string.format("%s.comp(%d)", key, c - 1)
                setXMLFloat(xmlFile, cKey .. "#cap",       slot.capacity or 0)
                setXMLInt(xmlFile,   cKey .. "#fillType",  slot.fillType or 0)
                setXMLFloat(xmlFile, cKey .. "#fillLevel", slot.fillLevel or 0)
                setXMLInt(xmlFile,   cKey .. "#isActive",  slot.isActive and 1 or 0)
            end
            i = i + 1
            RealSiloDebug.print(string.format("[realSilo] Multi-extension opgeslagen: %s (%d vakken)", uid, #slots))
        end
    end
end

-- ============================================================
-- Laden: sla data op in pendingSaved, koppel NIET hier.
-- Koppeling gebeurt in onFinalizePlacement van de extension/silo.
-- ============================================================
function RealSiloExtensionManager.loadFromXML(xmlFile)
    RealSiloExtensionManager.pendingSaved = {}
    local i = 0
    while true do
        local key     = string.format("realSiloData.ext(%d)", i)
        local siloUid = getXMLString(xmlFile, key .. "#siloUid")
        if siloUid == nil then break end

        local numComps = getXMLInt(xmlFile, key .. "#numComps") or 1

        if numComps > 1 then
            local comps = {}
            for c = 0, numComps - 1 do
                local cKey = string.format("%s.comp(%d)", key, c)
                table.insert(comps, {
                    cap       = getXMLFloat(xmlFile, cKey .. "#cap")      or 0,
                    fillType  = getXMLInt(xmlFile,   cKey .. "#fillType") or 0,
                    fillLevel = getXMLFloat(xmlFile, cKey .. "#fillLevel")or 0,
                    isActive  = (getXMLInt(xmlFile,  cKey .. "#isActive") or 0) == 1,
                })
            end
            table.insert(RealSiloExtensionManager.pendingSaved, {
                siloUid  = siloUid,
                numComps = numComps,
                comps    = comps,
                isMulti  = true,
            })
        else
            table.insert(RealSiloExtensionManager.pendingSaved, {
                siloUid   = siloUid,
                cap       = getXMLFloat(xmlFile, key .. "#cap")      or 0,
                fillType  = getXMLInt(xmlFile,   key .. "#fillType") or 0,
                fillLevel = getXMLFloat(xmlFile, key .. "#fillLevel")or 0,
                isActive  = (getXMLInt(xmlFile,  key .. "#isActive") or 0) == 1,
                isMulti   = false,
            })
        end
        i = i + 1
    end
    if i > 0 then
        RealSiloDebug.print(string.format("[realSilo] %d extension(s) klaar voor herstel", i))
    end
end

-- ============================================================
-- Herkoppel een extension met een nieuw aantal/verdeling compartimenten.
-- Gebruikt door de speler via de Extensions-configuratiepagina wanneer
-- het aantal vakken van een (niet-XML-locked) extension wijzigt, en
-- door de join-sync wanneer de server een afwijkende koppeling stuurt.
--
-- compartments = array van { cap, fillType, fillLevel, isActive }
-- ============================================================
function RealSiloExtensionManager.relink(extPlaceable, uid, compartments)
    if not compartments or #compartments == 0 then return false end

    RealSiloExtensionManager.unlink(extPlaceable)

    if #compartments == 1 then
        local c = compartments[1]
        return RealSiloExtensionManager.link(extPlaceable, uid,
            c.cap, c.fillType, c.fillLevel, c.isActive)
    else
        return RealSiloExtensionManager.linkMulti(extPlaceable, uid, compartments)
    end
end

-- ============================================================
-- Claim de eerste beschikbare saved-entry (FIFO).
-- ============================================================
function RealSiloExtensionManager.claimSavedData()
    if #RealSiloExtensionManager.pendingSaved == 0 then return nil end
    return table.remove(RealSiloExtensionManager.pendingSaved, 1)
end

RealSiloDebug.print("[realSilo] RealSiloExtensionManager (boekhoud-versie) geladen")
