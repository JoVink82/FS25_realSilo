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
-- Menu-context: staat er een menuscherm open?
--
-- Tijdens het SPELEN moeten getFillLevel/getFillLevels alleen het
-- ACTIEVE vak rapporteren -- daar hangt het gericht laden/lossen per
-- compartiment van af (de LoadTrigger leidt hieruit af hoeveel er
-- beschikbaar is, en vraagt dus nooit meer dan er in het vak zit).
--
-- In een MENU (het financien-/prijzenoverzicht, statistieken) wil je
-- juist de totale voorraad van de silo zien, niet alleen het actieve
-- vak. Daarom rapporteren we daar het echte totaal.
--
-- Ons eigen RealSilo-menu leest rechtstreeks uit de boekhouding en
-- wordt hier dus niet door beinvloed.
-- ----------------------------------------------------------------
local function isMenuOpen()
    if g_gui == nil then return false end
    local ok, visible = pcall(function() return g_gui:getIsGuiVisible() end)
    return ok and visible == true
end
RealSiloStorageHook.isMenuOpen = isMenuOpen

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
        -- In een menu: echte totalen tonen (overzicht/prijzen).
        if isMenuOpen() then
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
-- getFillLevel: tijdens spelen alleen het actieve vak (nodig voor
-- gericht laden per compartiment); in een menu het echte totaal
-- (financien-/prijzenoverzicht toont zo de hele silo).
-- ----------------------------------------------------------------
Storage.getFillLevel = function(self, fillType)
    local uid  = realSiloStorageLink[self]
    local data = uid and RealSiloCompartmentStorage.siloSlots[uid]
    if not data or not realSiloManager.isConfigured(uid) then
        return originalGetFillLevel(self, fillType)
    end
    if isMenuOpen() then
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
    if not active then return 0 end
    if active.storage ~= self then return 0 end
    if active.fillType ~= 0 and fillType ~= nil and active.fillType ~= fillType then
        return 0
    end
    local free = math.max(active.capacity - active.fillLevel, 0)
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
