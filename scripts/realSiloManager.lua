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
realSiloManager.DEFAULT_EXTENSION_RANGE = 50   -- meter, per silo instelbaar

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
    -- Zoekbereik voor silo-extensions in meters (per silo instelbaar).
    -- Standaard 50 m; oude savegames zonder deze waarde krijgen hem hier.
    if cfg.extensionRange == nil then
        cfg.extensionRange = realSiloManager.DEFAULT_EXTENSION_RANGE or 50
    end
    -- Drogen toestaan (per silo instelbaar, standaard AAN). Oude
    -- savegames van vóór deze instelling hebben dit veld nog niet -- die
    -- krijgen hier standaard "toegestaan", zodat bestaand gedrag niet
    -- verandert totdat de admin het bewust uitzet voor een silo.
    if cfg.dryingAllowed == nil then
        cfg.dryingAllowed = true
    end

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
-- Droger-configuratie: LEGACY, niet meer functioneel gebruikt.
-- MoistureSystem beheert drogen nu zelf, native, op het actieve vak
-- van de silo (geen blokkade/override meer vanuit realSilo). Deze
-- vlag en de onderstaande dryingTransfers-boekhouding blijven staan
-- als onschadelijke, ongebruikte data zodat oude savegames/XML met
-- een dryer="true"-attribuut niet stuklopen.
-- ============================================================
function realSiloManager.hasDryer(uid)
    local silo = realSiloManager.silos[uid]
    return silo ~= nil and silo.config.hasDryer == true
end

function realSiloManager.setHasDryer(uid, value)
    local silo = realSiloManager.silos[uid]
    if silo then silo.config.hasDryer = (value == true) end
end

-- ============================================================
-- Drogen toestaan: per silo instelbaar via de instellingen-dialoog
-- (RealSiloDialog page 2). Gebruikt door realSiloDryerCompat.lua om
-- een silo wel/niet als geheel aan te bieden aan FS25_MoistureSystem's
-- Grain Drying-menu. Standaard TOEGESTAAN (true) -- een silo zonder
-- deze instelling (nog niet opgeslagen, of een oude savegame) mag dus
-- gewoon drogen, exact het gedrag van vóór deze instelling bestond.
-- ============================================================
function realSiloManager.isDryingAllowed(uid)
    local silo = realSiloManager.silos[uid]
    return not silo or silo.config.dryingAllowed ~= false
end

function realSiloManager.setDryingAllowed(uid, value)
    local silo = realSiloManager.silos[uid]
    if silo then silo.config.dryingAllowed = (value ~= false) end
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

-- ============================================================
-- Droogtransfers
-- Een droogtransfer is een gewone transfer (zelfde volume-
-- verplaatsing via moveBetweenSlots/updateTransfers hierboven),
-- extra gemarkeerd zodat RealSiloDryingTransfer.onHourChanged()
-- weet welke bron/doel-vakken elk uur moeten drogen (met dezelfde
-- snelheid/kosten als MoistureSystem's eigen droogsysteem). Wordt
-- NIET opgeslagen in de savegame (net als realSiloManager.transfers
-- hierboven, dat ook al niet persistent is) — een lopende
-- droogtransfer stopt dus bij het herladen van de save, maar de
-- reeds bereikte vocht/kwaliteit-waarden per vak blijven wel bewaard
-- (die staan in RealSiloCompartmentStorage en worden wel opgeslagen).
-- ============================================================

realSiloManager.dryingTransfers = {}  -- [uid] = { fromSlot, toSlot }

function realSiloManager.startDryingTransfer(uid, fromSlot, toSlot)
    realSiloManager.dryingTransfers[uid] = { fromSlot = fromSlot, toSlot = toSlot }
    RealSiloDebug.print(string.format("[realSilo] Droogtransfer gestart: %s vak %d -> vak %d", uid, fromSlot, toSlot))
end

function realSiloManager.stopDryingTransfer(uid)
    if realSiloManager.dryingTransfers[uid] then
        realSiloManager.dryingTransfers[uid] = nil
        RealSiloDebug.print(string.format("[realSilo] Droogtransfer gestopt: %s", uid))
    end
end

function realSiloManager.getDryingTransfer(uid)
    return realSiloManager.dryingTransfers[uid]
end

-- v12 -- BUGFIX: transfers/droogtransfers gingen niet sneller bij een
-- hogere spelsnelheid. Oorzaak: FSBaseMission:update(dt) krijgt de
-- ONGESCHAALDE, echte tijd -- de spelsnelheid-multiplier wordt in FS25
-- alleen ZELF toegepast door de Environment-klasse op zijn eigen
-- dayTime-teller (waar bijvoorbeeld MoistureSystem's uur-gebaseerde
-- droogfunctie via MessageType.HOUR_CHANGED wél automatisch van
-- profiteert). Wij rekenden tot nu toe met die ongeschaalde dt, dus
-- een transfer bewoog altijd evenveel liter per ECHTE minuut, ongeacht
-- spelsnelheid.
--
-- Oplossing: we meten zelf hoeveel IN-GAME tijd (environment.dayTime,
-- loopt over middernacht heen om) er sinds de vorige update verstreken
-- is, en gebruiken dát als basis in plaats van de ruwe dt. Bestaat
-- environment.dayTime onverhoopt niet, dan vallen we terug op de oude
-- (ongeschaalde) dt -- nooit slechter dan het huidige gedrag.
local _lastDayTimeForTransfers = nil

local function getGameMsElapsed(dt)
    local env = g_currentMission and g_currentMission.environment
    local dayTime = env and env.dayTime
    if dayTime == nil then
        return dt -- fallback: oud gedrag
    end
    if _lastDayTimeForTransfers == nil then
        _lastDayTimeForTransfers = dayTime
        return dt -- eerste keer: nog geen vorige meting, gebruik gewoon dt
    end
    local elapsed = dayTime - _lastDayTimeForTransfers
    _lastDayTimeForTransfers = dayTime
    if elapsed < 0 then
        -- middernacht gepasseerd (dayTime rolt over) -- pak de dagduur
        -- erbij op zodat we geen negatieve/rare delta krijgen
        local dayLength = (env.dayDuration) or (env.environmentDayDuration) or 86400000
        elapsed = elapsed + dayLength
    end
    -- Bescherming tegen extreme uitschieters (bv. een save-load, of
    -- een enkele zeer trage frame): clamp op maximaal 10x de ruwe dt,
    -- zodat een transfer nooit in één klap een onrealistisch grote
    -- hoeveelheid verplaatst.
    if elapsed > dt * 10 then elapsed = dt * 10 end
    if elapsed < 0 then elapsed = 0 end
    return elapsed
end

-- Update alle actieve transfers (aangeroepen elke frame, alleen op de server)
function realSiloManager.updateTransfers(dt)
    local gameDt = getGameMsElapsed(dt)
    for uid, transfer in pairs(realSiloManager.transfers) do
        if not transfer.active then
            realSiloManager.transfers[uid] = nil
        else
            local literPerMs = transfer.rate / 60000
            local delta = literPerMs * gameDt

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
