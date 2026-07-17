-- ============================================================
-- realSiloManager.lua  v2 - multiplayer-veilig (boekhouding)
--
-- Centrale opslag voor de CONFIGURATIE van alle silo's (aantal
-- vakken, capaciteit per vak, naam, vergrendeld, transferrate).
-- De daadwerkelijke vak-inhoud (welk vak welk product/niveau
-- heeft) staat in RealSiloCompartmentStorage.siloSlots — dit
-- bestand bevat alleen de metadata en het herconfigureren ervan.
-- ============================================================

realSiloManager = {}
realSiloManager.silos  = {}
realSiloManager.nextId = 1

realSiloManager.DEFAULT_COMPARTMENTS = 4
realSiloManager.DEFAULT_CAPACITY     = 50000

function realSiloManager.generateUniqueId(placeable)
    local x, y, z = 0, 0, 0
    if placeable ~= nil and placeable.rootNode ~= nil and placeable.rootNode ~= 0 then
        x, y, z = getWorldTranslation(placeable.rootNode)
    end
    local id = string.format("rs_%d_%d_%d_%d",
        realSiloManager.nextId, math.floor(x+0.5), math.floor(y+0.5), math.floor(z+0.5))
    realSiloManager.nextId = realSiloManager.nextId + 1
    return id
end

function realSiloManager.register(placeable, savedId, savedConfig)
    local uniqueId
    if savedId and savedId ~= "" then
        uniqueId = savedId
        local num = tonumber(string.match(uniqueId, "^rs_(%d+)_"))
        if num and num >= realSiloManager.nextId then
            realSiloManager.nextId = num + 1
        end
    else
        uniqueId = realSiloManager.generateUniqueId(placeable)
    end

    local cfg = savedConfig or {
        numCompartments        = realSiloManager.DEFAULT_COMPARTMENTS,
        capacityPerCompartment = realSiloManager.DEFAULT_CAPACITY
    }

    realSiloManager.silos[uniqueId] = {
        uniqueId = uniqueId,
        placeable = placeable,
        config = cfg,
    }
    RealSiloDebug.print(string.format("[realSilo] Geregistreerd: %s | %d vak(ken) x %d L",
        uniqueId, cfg.numCompartments, cfg.capacityPerCompartment))
    return uniqueId
end

function realSiloManager.unregister(uniqueId)
    if uniqueId then
        realSiloManager.silos[uniqueId] = nil
        RealSiloDebug.print("[realSilo] Verwijderd: " .. uniqueId)
    end
end

function realSiloManager.getSilo(uniqueId)
    return uniqueId and realSiloManager.silos[uniqueId] or nil
end

-- ============================================================
-- applyConfig: wijzig aantal vakken / capaciteit per vak. Past
-- ALLEEN onze boekhouding aan (RealSiloCompartmentStorage), er
-- worden geen storage-objecten aangemaakt of verwijderd.
-- ============================================================
function realSiloManager.applyConfig(uniqueId, newNum, newCap)
    local silo = realSiloManager.silos[uniqueId]
    if not silo then return false, "Silo niet gevonden" end
    newNum = math.max(1, math.min(32, math.floor(newNum)))
    newCap = math.max(1000, math.floor(newCap))

    local data = RealSiloCompartmentStorage.siloSlots[uniqueId]
    if data then
        -- Bewaar bestaande extension-vakken (die horen niet bij de
        -- "gewone" vakken die hier herconfigureerd worden).
        local normalSlots = {}
        local extSlots     = {}
        for _, slot in ipairs(data.slots) do
            if slot.isExtension then
                table.insert(extSlots, slot)
            else
                table.insert(normalSlots, slot)
            end
        end

        -- Pas capaciteit van bestaande gewone vakken aan
        for _, slot in ipairs(normalSlots) do
            slot.capacity = newCap
        end

        -- Vakken toevoegen
        for i = #normalSlots + 1, newNum do
            table.insert(normalSlots, { fillType = 0, fillLevel = 0, capacity = newCap, isActive = false })
        end

        -- Vakken verwijderen (alleen lege, van achteraf)
        if newNum < #normalSlots then
            for i = #normalSlots, newNum + 1, -1 do
                if normalSlots[i].fillLevel > 0 then
                    newNum = i
                    if g_currentMission then
                        g_currentMission:showBlinkingWarning(
                            string.format(g_i18n:getText("realSilo_cantReduce"), i, normalSlots[i].fillLevel), 4000)
                    end
                    break
                end
                table.remove(normalSlots, i)
            end
        end

        -- Herstel de echte storage-link op elk vak (zelfde storage als
        -- voorheen — die is nooit veranderd)
        local realStorage = normalSlots[1] and normalSlots[1].storage
        if not realStorage and silo.placeable and silo.placeable.spec_silo then
            realStorage = silo.placeable.spec_silo.storages[1]
        end
        for _, slot in ipairs(normalSlots) do
            slot.storage = slot.storage or realStorage
        end

        -- Herbouw de volledige lijst: gewone vakken eerst, dan extensions
        local newSlots = {}
        local previousActiveSlotRef = data.slots[data.activeSlot]
        for _, slot in ipairs(normalSlots) do table.insert(newSlots, slot) end
        for _, slot in ipairs(extSlots)    do table.insert(newSlots, slot) end
        for i, slot in ipairs(newSlots) do slot.index = i end
        data.slots = newSlots

        -- Actief vak terugvinden op object-identiteit, anders eerste vak
        local newActiveIndex = 1
        for i, slot in ipairs(newSlots) do
            if slot == previousActiveSlotRef then newActiveIndex = i; break end
        end
        data.activeSlot = newActiveIndex
        for i, slot in ipairs(newSlots) do slot.isActive = (i == newActiveIndex) end

        newNum = #normalSlots
    end

    silo.config.numCompartments        = newNum
    silo.config.capacityPerCompartment = newCap
    RealSiloDebug.print(string.format("[realSilo] Config: %s → %d x %d L", uniqueId, newNum, newCap))
    return true
end

-- Console helpers
function realSilo_setConfig(num, cap, uid)
    local id = uid
    if not id then
        for k, _ in pairs(realSiloManager.silos) do id = k; break end
    end
    if not id then RealSiloDebug.print("[realSilo] Geen silo gevonden"); return end
    local ok, err = realSiloManager.applyConfig(id, num, cap)
    if ok then
        local s = realSiloManager.getSilo(id)
        RealSiloDebug.print(string.format("[realSilo] OK: %d x %d L  (%s)", s.config.numCompartments, s.config.capacityPerCompartment, id))
    else
        RealSiloDebug.print("[realSilo] Fout: " .. tostring(err))
    end
end

function realSilo_list()
    local n = 0
    for id, silo in pairs(realSiloManager.silos) do
        n = n + 1
        RealSiloDebug.print(string.format("[realSilo] %s  %dx%dL", id, silo.config.numCompartments, silo.config.capacityPerCompartment))
        local data = RealSiloCompartmentStorage.siloSlots[id]
        if data then
            for i, slot in ipairs(data.slots) do
                local prod = "leeg"
                if slot.fillType ~= 0 then
                    local d = g_fillTypeManager:getFillTypeByIndex(slot.fillType)
                    prod = d and (d.title or d.name) or tostring(slot.fillType)
                end
                RealSiloDebug.print(string.format("  [%d] %-18s %7.0f/%7.0f L%s", i, prod, slot.fillLevel, slot.capacity,
                    slot.isExtension and " [ext]" or ""))
            end
        end
    end
    if n == 0 then RealSiloDebug.print("[realSilo] Geen silo's") end
end

-- ============================================================
-- Silo naam beheer
-- ============================================================
realSiloManager.siloNames = {}  -- [uid] = naam

function realSiloManager.getSiloName(uid)
    return realSiloManager.siloNames[uid] or ""
end

function realSiloManager.setSiloName(uid, naam)
    naam = (naam or ""):gsub("^%s+", ""):gsub("%s+$", "")  -- trim
    if naam == "" then naam = nil end
    realSiloManager.siloNames[uid] = naam
end

-- ============================================================
-- Lees de totale capaciteit rechtstreeks uit de PlaceableSilo
-- storage (deze wordt nooit door ons aangepast, dus .capacity
-- is altijd de originele, door Giants beheerde waarde).
-- ============================================================
function realSiloManager.getStorageCapacity(placeable)
    local spec = placeable and placeable.spec_silo
    if not spec or not spec.storages then return nil end
    local total = 0
    for _, storage in ipairs(spec.storages) do
        total = total + (storage.capacity or 0)
    end
    return total > 0 and total or nil
end

-- Geconfigureerd-vlag: silo mag pas gebruikt worden na eerste config
function realSiloManager.isConfigured(uid)
    local silo = realSiloManager.silos[uid]
    return silo and silo.config.isConfigured == true
end

function realSiloManager.setConfigured(uid)
    local silo = realSiloManager.silos[uid]
    if silo then silo.config.isConfigured = true end
end

-- ============================================================
-- Transfer systeem
-- Van één vak naar een ander, met instelbare snelheid (L/min).
-- Gebruikt RealSiloCompartmentStorage.moveBetweenSlots, dat de
-- echte storage(s) via de normale setFillLevel-API aanpast (dus
-- correct gesynchroniseerd, geen rechtstreekse veld-mutatie meer).
-- ============================================================

realSiloManager.transfers = {}  -- [uid] = { fromSlot, toSlot, rate, active }

function realSiloManager.startTransfer(uid, fromSlot, toSlot, ratePerMin)
    if fromSlot == toSlot then return false, "zelfde silo" end
    realSiloManager.transfers[uid] = {
        fromSlot     = fromSlot,
        toSlot       = toSlot,
        rate         = ratePerMin or 1000,
        active       = true,
        syncTimer    = 1000, -- direct broadcasten op eerste frame
        syncInterval = 1000, -- broadcast elke seconde
    }
    RealSiloDebug.print(string.format("[realSilo] Transfer gestart: %s vak %d → vak %d @ %d L/min",
        uid, fromSlot, toSlot, ratePerMin or 1000))
    return true
end

function realSiloManager.stopTransfer(uid)
    if realSiloManager.transfers[uid] then
        realSiloManager.transfers[uid].active = false
        realSiloManager.transfers[uid] = nil
        RealSiloDebug.print(string.format("[realSilo] Transfer gestopt: %s", uid))
    end
end

function realSiloManager.getTransfer(uid)
    return realSiloManager.transfers[uid]
end

-- Update alle actieve transfers (aangeroepen elke frame, alleen op de server)
function realSiloManager.updateTransfers(dt)
    for uid, transfer in pairs(realSiloManager.transfers) do
        if not transfer.active then
            realSiloManager.transfers[uid] = nil
        else
            local literPerMs = transfer.rate / 60000
            local delta = literPerMs * dt

            local moved = RealSiloCompartmentStorage.moveBetweenSlots(
                uid, transfer.fromSlot, transfer.toSlot, delta)

            if moved <= 0 then
                realSiloManager.transfers[uid] = nil
                RealSiloEvents.broadcastSlotSync(uid)
                RealSiloDebug.print(string.format("[realSilo] Transfer gestopt/klaar: %s", uid))
            else
                -- Periodieke broadcast zodat clients de voortgang zien
                transfer.syncTimer = transfer.syncTimer + dt
                if transfer.syncTimer >= transfer.syncInterval then
                    transfer.syncTimer = 0
                    RealSiloEvents.broadcastSlotSync(uid)
                end
            end
        end
    end
end

RealSiloDebug.print("[realSilo] realSiloManager (boekhoud-versie) geladen")
