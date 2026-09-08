-- ============================================================
-- realSiloStorageHook.lua  v9 - geconfigureerde silo's beheren
--
-- Alle hooks geven ONGECONFIGUREERDE silo's volledig door aan de
-- originele Giants-functies. Hierdoor:
--   • werkt een silo die al graan bevat (van vóór de mod) gewoon
--     zoals voorheen — storten, lossen, verkopen, alles werkt —
--     totdat de admin de silo configureert via het mod-menu
--   • gaat er nooit graan verloren bij het eerste activeren
--     van de mod op een bestaande save
--   • hoeft de mod niets te weten van de laad-timing
--
-- Bij de EERSTE configuratie door de admin leest de mod de
-- werkelijke storage-inhoud uit (storage.fillLevels) en verdeelt
-- die over de nieuw aangemaakte vakken.
--
-- GECONFIGUREERDE silo's worden wel volledig beheerd:
--   • getFillLevel/getFillLevels: alleen actief vak
--   • getFreeCapacity: alleen actief vak
--   • getCapacity: actief vak
--   • setFillLevel: boekhouding + echte storage
-- ============================================================

realSiloStorageLink = realSiloStorageLink or {}

local originalGetFillLevel    = Storage.getFillLevel
local originalGetFillLevels   = Storage.getFillLevels
local originalGetFreeCapacity = Storage.getFreeCapacity
local originalGetCapacity     = Storage.getCapacity
local originalSetFillLevel    = Storage.setFillLevel

RealSiloStorageHook = RealSiloStorageHook or {}
RealSiloStorageHook.getRealFillLevel = function(storage, fillType)
    return originalGetFillLevel(storage, fillType)
end

-- ----------------------------------------------------------------
-- Server en client rekenen elk ONAFHANKELIJK van elkaar hun eigen
-- per-vak boekhouding uit, tick voor tick, terwijl alleen het ECHTE
-- storage-totaal door Giants zelf gesynchroniseerd wordt. Een silo met
-- meerdere vakken van hetzelfde product kan daardoor client-zijdig een
-- ANDERE verdeling over de vakken uitkomen dan server-zijdig (gemeld:
-- client bleef bij het laden op het niveau van het ANDERE vak steken
-- in plaats van door te tellen naar 0, terwijl de server wel correct
-- naar 0 liep). Hergebruik daarom, net als realSiloMoistureCompat.lua
-- al voor droog-updates doet, het bestaande gethrottlede slot-sync-
-- kanaal: plan na ELKE succesvolle storten/laden-wijziging een volledige
-- server->client herstel-broadcast, zodat een eventuele lokale
-- afwijking op de client vanzelf weer gelijkgetrokken wordt.
-- ----------------------------------------------------------------
local function scheduleSlotSyncCorrection(uid)
    if g_server == nil or RealSiloMoistureCompat == nil
            or RealSiloMoistureCompat.pendingSlotSync == nil then
        return
    end
    local now = g_currentMission and g_currentMission.time or 0
    RealSiloMoistureCompat.pendingSlotSync[uid] = now + 250
end

-- ----------------------------------------------------------------
-- getFillLevels (MEERVOUD): toont alleen het actieve vak aan
-- laad-triggers zodat de "selecteer silo"-dialoog slechts één
-- product tegelijk aanbiedt. Ongeconfigureerde silo's: pass-through.
-- ----------------------------------------------------------------
if originalGetFillLevels ~= nil then
    Storage.getFillLevels = function(self)
        local uid  = realSiloStorageLink[self]
        local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
        if not data or not realSiloManager.isConfigured(uid) then
            return originalGetFillLevels(self)
        end
        local active = data.slots[data.activeSlot]
        if not active or active.storage ~= self or active.fillType == 0 or active.fillLevel <= 0 then
            return {}
        end
        return { [active.fillType] = active.fillLevel }
    end
end

-- Virtuele fill level: wat we aan Giants rapporteren voor déze storage
local function virtualFillLevel(data, self, fillType)
    local active = data.slots[data.activeSlot]
    if active and active.storage == self then
        return (active.fillType == fillType) and active.fillLevel or 0
    end
    return 0
end

-- ----------------------------------------------------------------
-- getFillLevel: voor een geconfigureerde silo altijd alleen het actieve vak.
-- Een algemene GUI-controle is hier onveilig: laad- en lostriggers blijven
-- ook doorlopen terwijl een menu zichtbaar is. Het fysieke silototaal zou
-- dan iedere frame opnieuw als stort-delta op het actieve vak terechtkomen.
-- ----------------------------------------------------------------
Storage.getFillLevel = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFillLevel(self, fillType)
    end
    return virtualFillLevel(data, self, fillType)
end

-- ----------------------------------------------------------------
-- getFreeCapacity: het actieve vak bepaalt de vrije ruimte.
-- Cruciaal voor lossen: alleen de storage die het actieve vak
-- bevat mag vrije capaciteit rapporteren. Zit het actieve vak in
-- een extension, dan geeft de hoofdsilo-storage 0 (geen ruimte) en
-- de extension-storage de echte vrije ruimte. Zo lost een trailer
-- altijd in het actieve vak, of dat nu de hoofdsilo of een
-- extension is.
-- ----------------------------------------------------------------
Storage.getFreeCapacity = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFreeCapacity(self, fillType)
    end
    local active = data.slots[data.activeSlot]
    if not active then
        RealSiloDebug.print("[realSilo][DIAG] getFreeCapacity=0: geen actief vak (uid=%s slot=%s)",
            tostring(uid), tostring(data.activeSlot))
        return 0
    end
    if active.storage ~= self then
        RealSiloDebug.print("[realSilo][DIAG] getFreeCapacity=0: actief vak %d hoort bij andere storage (uid=%s)",
            data.activeSlot, tostring(uid))
        return 0
    end
    if active.fillType ~= 0 and fillType ~= nil and active.fillType ~= fillType then
        RealSiloDebug.print("[realSilo][DIAG] getFreeCapacity=0: vak %d heeft ft=%s, gevraagd ft=%s (uid=%s)",
            data.activeSlot, tostring(active.fillType), tostring(fillType), tostring(uid))
        return 0
    end
    local free = math.max(active.capacity - active.fillLevel, 0)
    if free <= 0 then
        RealSiloDebug.print("[realSilo][DIAG] getFreeCapacity=0: vak %d vol (%.0f/%.0f, uid=%s)",
            data.activeSlot, active.fillLevel, active.capacity, tostring(uid))
    end
    RealSiloDebug.print(
        "[realSilo] getFreeCapacity uid=%s actiefVak=%d isExt=%s fillType=%s free=%.0f",
        tostring(uid), data.activeSlot, tostring(active.isExtension),
        tostring(fillType), free)
    return free
end

-- ----------------------------------------------------------------
-- getCapacity: actief vak (geconfigureerd) of echt.
-- ----------------------------------------------------------------
Storage.getCapacity = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetCapacity(self, fillType)
    end
    local active = data.slots[data.activeSlot]
    if active and active.storage == self then return active.capacity end
    for _, slot in ipairs(data.slots) do
        if slot.storage == self then return slot.capacity end
    end
    return 0
end

-- ----------------------------------------------------------------
-- setFillLevel: kern-logica (alleen voor geconfigureerde silo's)
-- ----------------------------------------------------------------
Storage.setFillLevel = function(self, fillLevel, fillType, fillInfo)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or self._realSiloApplying then
        return originalSetFillLevel(self, fillLevel, fillType, fillInfo)
    end

    -- Ongeconfigureerde silo: volledig pass-through.
    -- Hierdoor werkt bestaand graan gewoon, ook van vóór de mod.
    if not realSiloManager.isConfigured(uid) then
        return originalSetFillLevel(self, fillLevel, fillType, fillInfo)
    end

    -- Boekhouding-totaal voor déze storage
    local bookTotal = 0
    for _, s in ipairs(data.slots) do
        if s.storage == self and s.fillType == fillType then
            bookTotal = bookTotal + s.fillLevel
        end
    end

    -- setFillLevel ontvangt van GIANTS een ABSOLUUT niveau van de echte
    -- Storage, niet van ons virtuele actieve vak. Trek daarom ook het echte
    -- niveau af. Met het virtuele vakniveau als basis werd de inhoud van
    -- andere vakken van hetzelfde product nogmaals als storting gezien.
    -- Voorbeeld: er staat fysiek al 700 l tarwe in een ander vak en er wordt
    -- 1.000 l in een leeg actief vak gestort; de oude berekening maakte daar
    -- ten onrechte 1.700 l van.
    local realCurrentBefore = originalGetFillLevel(self, fillType)
    local virtualCurrent    = virtualFillLevel(data, self, fillType)
    local activeDeposit = RealSiloMoistureCompat and RealSiloMoistureCompat.activeDeposit
    local isTriggerDeposit = activeDeposit ~= nil
        and activeDeposit.fillType == fillType
        and (activeDeposit.remainingAmount or 0) > 0
    local delta
    if isTriggerDeposit then
        -- Gebruik bij lossen de delta die UnloadTrigger zelf doorgaf. Dit
        -- werkt zowel na wisselen van een vol vak naar een leeg vak als bij
        -- bestaande inhoud van hetzelfde product in andere vakken.
        delta = activeDeposit.remainingAmount
    elseif fillLevel > realCurrentBefore then
        -- Storten: Giants' eigen berekening is gebaseerd op het ECHTE
        -- storage-totaal (zie toelichting hierboven), dus de referentie
        -- hier moet dat ook zijn.
        delta = fillLevel - realCurrentBefore
    elseif fillLevel < virtualCurrent then
        -- Laden/pickup: LoadingStation:removeFillLevel bepaalt zijn eigen
        -- "oldFillLevel" via ONZE gehookte getFillLevel, die (terecht)
        -- alleen het actieve vak teruggeeft. De delta hier moet daarom
        -- OOK tegen die referentie berekend worden -- niet tegen het
        -- storage-brede totaal. Anders telt de inhoud van ANDERE vakken
        -- met hetzelfde product mee als "te verwijderen", en trekt drain()
        -- het actieve vak in één klap volledig leeg terwijl de trailer
        -- maar een fractie daadwerkelijk ontvangt (gemeld: 1000 l gedroogd
        -- product verdween uit het vak, trailer kreeg maar 72 l). Dit is
        -- CLAUDE.md valkuil 1 in de andere richting: getFillLevel en de
        -- delta-berekening moeten dezelfde bron gebruiken.
        delta = fillLevel - virtualCurrent
    else
        -- fillLevel ligt tussen de twee referenties in -- komt via normale
        -- Giants-aanroepen niet voor. Geen wijziging toepassen.
        delta = 0
    end

    -- Geen epsilon gebruiken voor live storage-mutaties. GIANTS laat een
    -- FillUnit pas exact leeglopen wanneer ook de laatste fractie liter is
    -- toegepast; als wij die fractie negeren blijft de discharge-state aan
    -- en blijft een trailer in de kiepstand staan.
    if delta > 0 then
        RealSiloDebug.print(
            "[realSilo][DIAG] storten uid=%s ft=%s gevraagd=%.0f boekTotaal=%.0f delta=%.0f actiefVak=%d",
            tostring(uid), tostring(fillType), fillLevel, bookTotal, delta, data.activeSlot)
        -- Storten gebeurt UITSLUITEND in het actieve vak. Als de
        -- aangesproken storage niet de storage van het actieve vak is,
        -- doen we niets — getFreeCapacity gaf voor die storage ook al 0,
        -- dus Giants hoort hier niet te storten. Dit voorkomt dat een
        -- los-actie per ongeluk in een niet-actieve extension belandt.
        local active = data.slots[data.activeSlot]
        if not active or active.storage ~= self then
            return
        end
        if active.fillType ~= 0 and active.fillType ~= fillType then return end

        local room  = math.max(active.capacity - active.fillLevel, 0)
        local added = math.min(delta, room)
        if added <= 0 then return end

        local oldActiveLevel = active.fillLevel
        active.fillLevel = active.fillLevel + added
        if isTriggerDeposit then
            activeDeposit.remainingAmount = math.max(activeDeposit.remainingAmount - added, 0)
        end
        if active.fillType == 0 then active.fillType = fillType end

        if RealSiloMoistureCompat ~= nil
                and RealSiloMoistureCompat.recordStorageDeposit ~= nil then
            RealSiloMoistureCompat.recordStorageDeposit(
                uid, active, fillType, oldActiveLevel, added, data.activeSlot)
        end

        self._realSiloApplying = true
        originalSetFillLevel(self, realCurrentBefore + added, fillType, fillInfo)
        self._realSiloApplying = false
        scheduleSlotSyncCorrection(uid)

    elseif delta < 0 then
        local toRemove    = -delta
        local totalDrained = 0
        local active       = data.slots[data.activeSlot]

        local function drain(slot)
            if toRemove <= 0 then return end
            if slot.storage == self and slot.fillType == fillType and slot.fillLevel > 0 then
                local removed = math.min(toRemove, slot.fillLevel)
                slot.fillLevel = slot.fillLevel - removed
                if slot.fillLevel <= 0.00001 then slot.fillLevel = 0; slot.fillType = 0 end
                toRemove     = toRemove - removed
                totalDrained = totalDrained + removed
            end
        end

        if active then drain(active) end

        RealSiloDebug.print(
            "[realSilo][DIAG] laden uid=%s ft=%s gevraagd=%.0f virtueelVoor=%.0f delta=%.0f gedraineerd=%.0f actiefVak=%d",
            tostring(uid), tostring(fillType), fillLevel, virtualCurrent, delta, totalDrained, data.activeSlot)

        if totalDrained > 0 then
            -- Vlak VOOR de echte storage-update: vertel MoistureSystem welk
            -- vocht/kwaliteit dit specifieke vak heeft, zodat de trailer die
            -- nu laadt de juiste waarde krijgt in plaats van de gedeelde,
            -- mogelijk-van-een-ander-vak-afkomstige MoistureSystem-waarde.
            -- Direct na de echte update weer terugzetten, zodat ANDERE
            -- vakken zonder eigen vocht-record (die op deze gedeelde
            -- waarde vertrouwen) niet blijvend de waarde van dit vak
            -- overnemen.
            local moistureUid, moistureFtName, moisturePrev
            if RealSiloMoistureCompat ~= nil
                    and RealSiloMoistureCompat.recordStorageWithdrawal ~= nil then
                moistureUid, moistureFtName, moisturePrev =
                    RealSiloMoistureCompat.recordStorageWithdrawal(uid, active, fillType)
            end

            self._realSiloApplying = true
            originalSetFillLevel(self, math.max(realCurrentBefore - totalDrained, 0), fillType, fillInfo)
            self._realSiloApplying = false
            scheduleSlotSyncCorrection(uid)

            if moistureUid ~= nil and RealSiloMoistureCompat ~= nil
                    and RealSiloMoistureCompat.restoreSharedMoistureInfo ~= nil then
                RealSiloMoistureCompat.restoreSharedMoistureInfo(moistureUid, moistureFtName, moisturePrev)
            end
        end
    end
end

RealSiloDebug.print("[realSilo] Storage hooks geïnstalleerd (v9 - geconfigureerde silo's beheren)")
