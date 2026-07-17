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
-- getFillLevel: alleen het actieve vak (geconfigureerd) of echt (niet).
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
-- getFreeCapacity: alleen het actieve vak (geconfigureerd) of echt.
-- ----------------------------------------------------------------
Storage.getFreeCapacity = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFreeCapacity(self, fillType)
    end
    local active = data.slots[data.activeSlot]
    if not active or active.storage ~= self then return 0 end
    if active.fillType ~= 0 and fillType ~= nil and active.fillType ~= fillType then return 0 end
    return math.max(active.capacity - active.fillLevel, 0)
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

    local virtualCurrent = virtualFillLevel(data, self, fillType)
    local delta = fillLevel - virtualCurrent

    if delta > 0.0001 then
        -- Bypass: boekhouding klopt al → Giants laadt vanuit onze savegame
        if math.abs(bookTotal - fillLevel) < 0.5 then
            self._realSiloApplying = true
            originalSetFillLevel(self, fillLevel, fillType, fillInfo)
            self._realSiloApplying = false
            return
        end

        -- Normaal storten in actief vak
        local active = data.slots[data.activeSlot]
        if not active or active.storage ~= self then
            active = nil
            for _, s in ipairs(data.slots) do
                if s.storage == self and (s.fillType == fillType or s.fillType == 0) then
                    active = s; break
                end
            end
        end
        if not active then return end
        if active.fillType ~= 0 and active.fillType ~= fillType then return end

        local room  = math.max(active.capacity - active.fillLevel, 0)
        local added = math.min(delta, room)
        if added <= 0 then return end

        active.fillLevel = active.fillLevel + added
        if active.fillType == 0 then active.fillType = fillType end

        local realCurrent = originalGetFillLevel(self, fillType)
        self._realSiloApplying = true
        originalSetFillLevel(self, realCurrent + added, fillType, fillInfo)
        self._realSiloApplying = false

    elseif delta < -0.0001 then
        local toRemove    = -delta
        local totalDrained = 0
        local active       = data.slots[data.activeSlot]

        local function drain(slot)
            if toRemove <= 0.0001 then return end
            if slot.storage == self and slot.fillType == fillType and slot.fillLevel > 0 then
                local removed = math.min(toRemove, slot.fillLevel)
                slot.fillLevel = slot.fillLevel - removed
                if slot.fillLevel <= 0.0001 then slot.fillLevel = 0; slot.fillType = 0 end
                toRemove     = toRemove - removed
                totalDrained = totalDrained + removed
            end
        end

        if active then drain(active) end

        if totalDrained > 0 then
            local realCurrent = originalGetFillLevel(self, fillType)
            self._realSiloApplying = true
            originalSetFillLevel(self, math.max(realCurrent - totalDrained, 0), fillType, fillInfo)
            self._realSiloApplying = false
        end
    end
end

RealSiloDebug.print("[realSilo] Storage hooks geïnstalleerd (v9 - geconfigureerde silo's beheren)")
